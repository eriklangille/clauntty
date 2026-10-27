import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os.log

/// "This Mac": a host with no SSH. Commands run as processes here, and a pane is
/// `rtach --proxy` on a terminal device of its own, as sshd gives one, behind a NIO
/// channel that speaks what an SSH channel does (`SSHChannelData`, window changes, the
/// exit status). So sessions, deploys and workspaces take the same path as on any host,
/// and the panes are rtach sessions in this Mac's own ~/.clauntty, which a phone or a
/// terminal here can open too.
@MainActor
final class LocalHost: SSHConnection {
    /// The pane channels open now, closed with the host
    private var panes: [ObjectIdentifier: Channel] = [:]
    private var connected = false

    init(config: SavedConnection) {
        super.init(
            host: config.host,
            port: config.port,
            username: config.username,
            authMethod: config.authMethod,
            connectionId: config.id
        )
    }

    // MARK: - Environment

    /// What sshd gives a session: who the user is, their shell, and the short PATH their
    /// startup files build on. The app's own environment (Xcode's, launchd's, ours) stays
    /// out, as `rtach ws` keeps it out of a new pane (`pane_env`).
    nonisolated static var environment: [String: String] {
        let app = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "HOME": home,
            "USER": NSUserName(),
            "LOGNAME": NSUserName(),
            "SHELL": shell,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        for (name, value) in app where ["TMPDIR", "SSH_AUTH_SOCK", "LANG"].contains(name) || name.hasPrefix("LC_") {
            env[name] = value
        }
        return env
    }

    /// The user's home, where rtach keeps its sessions. CLAUNTTY_LOCAL_HOME gives another, so
    /// testing never touches this Mac's real sessions, in Release builds too (to measure the
    /// build that's shipped); only whoever launches the app can set it.
    nonisolated static var home: String {
        ProcessInfo.processInfo.environment["CLAUNTTY_LOCAL_HOME"] ?? NSHomeDirectory()
    }

    /// The user's login shell, as sshd runs commands with
    nonisolated static var shell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    // MARK: - Connection

    override func connect() async throws {
        try? FileManager.default.createDirectory(atPath: Self.home, withIntermediateDirectories: true)
        connected = true
        state = .connected
        onConnected?()
    }

    override var isConnected: Bool { connected }

    override func isResponsive(timeout: TimeAmount = .seconds(8)) async -> Bool { connected }

    override func disconnect() {
        connected = false
        panes.values.forEach { $0.close(promise: nil) }
        panes = [:]
        state = .disconnected
        onDisconnected?(nil)
    }

    // MARK: - Commands

    override func executeCommandData(_ command: String) async throws -> Data {
        try await run(command, stdin: nil)
    }

    override func executeWithStdin(_ command: String, stdinData: Data) async throws {
        _ = try await run(command, stdin: stdinData)
    }

    /// The command through the user's shell, as sshd runs one: its stdout, once it exits
    private func run(_ command: String, stdin: Data?) async throws -> Data {
        guard connected else { throw SSHError.notConnected }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.shell)
        process.arguments = ["-c", command]
        process.environment = Self.environment
        process.currentDirectoryURL = URL(fileURLWithPath: Self.home)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        try process.run()

        if let input, let stdin {
            // On its own thread, so a command that writes before it reads can't hold us
            // both up; one that exits without reading fails the write rather than
            // signaling the app (SIGPIPE)
            let writer = input.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global().async {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Panes

    override func createChannel(
        terminalSize: (rows: Int, columns: Int) = (30, 60),
        command: String? = nil,
        onDataReceived: @escaping (Data) -> Void,
        onChannelInactive: (() -> Void)? = nil
    ) async throws -> (Channel, SSHChannelHandler) {
        guard connected else { throw SSHError.notConnected }
        let terminal = try LocalTerminal(
            command: command ?? "exec \"$SHELL\" -l",
            size: terminalSize
        )
        let handler = SSHChannelHandler(onDataReceived: onDataReceived, onChannelInactive: onChannelInactive)
        let channel: Channel
        do {
            channel = try await NIOPipeBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(
                            LocalTerminalHandler(terminal: terminal),
                            handler
                        )
                    }
                }
                .takingOwnershipOfDescriptor(inputOutput: terminal.master)
                .get()
        } catch {
            Darwin.close(terminal.master)
            terminal.hangUp()
            terminal.watch(nil)
            throw error
        }
        terminal.watch(channel)

        let id = ObjectIdentifier(channel)
        panes[id] = channel
        channel.closeFuture.whenComplete { _ in
            terminal.hangUp()
            Task { @MainActor [weak self] in self?.panes[id] = nil }
        }
        Logger.clauntty.debugOnly("LocalHost: pane started, pid \(terminal.pid)")
        return (channel, handler)
    }
}

/// A process on a terminal device, as sshd starts a session's command: its own session,
/// with only the terminal open in it. sshd also makes the terminal its controlling one
/// (TIOCSCTTY), which posix_spawn can't; what that gives (SIGWINCH on a resize, SIGHUP
/// on close) is sent here instead.
final class LocalTerminal: @unchecked Sendable {
    /// Ours: the channel reads and writes it
    let master: Int32
    /// Kept open until the process exits, so the end of its output isn't lost to an
    /// early hangup, and to set the size on
    private var slave: Int32
    let pid: pid_t
    /// Whether the process has exited: its pid may be someone else's once reaped
    private var exited = false
    private let lock = NSLock()

    init(command: String, size: (rows: Int, columns: Int)) throws {
        var master: Int32 = -1, slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        var winsize = winsize(ws_row: UInt16(size.rows), ws_col: UInt16(size.columns), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, &name, nil, &winsize) == 0 else {
            throw SSHError.internalError("Couldn't open a terminal: \(String(cString: strerror(errno)))")
        }
        // Not in what the app starts some other way (commands, ProxyCommands)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own session, and nothing of ours open in it but the terminal
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, LocalHost.home)

        let shell = LocalHost.shell
        let environment = LocalHost.environment.merging(["TERM": "xterm-256color"]) { $1 }
            .map { "\($0.key)=\($0.value)" }
        let argv = [shell, "-c", command].map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
        guard spawned == 0 else {
            close(master)
            close(slave)
            throw SSHError.internalError("Couldn't start \(shell): \(String(cString: strerror(spawned)))")
        }
        self.master = master
        self.slave = slave
        self.pid = pid
    }

    /// Wait for the process: its exit status goes to the channel as sshd's would, then
    /// the terminal hangs up and the channel closes once its output is read
    func watch(_ channel: Channel?) {
        let pid = pid
        Thread.detachNewThread { [self] in
            // Noted as exited before it's reaped, so hangUp never signals a reused pid
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            lock.withLock { exited = true }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            guard let channel else {
                closeSlave()
                return
            }
            // WIFEXITED / WEXITSTATUS: Swift doesn't import the macros
            let exitedNormally = status & 0x7f == 0
            channel.eventLoop.execute {
                if exitedNormally {
                    channel.pipeline.fireUserInboundEventTriggered(
                        SSHChannelRequestEvent.ExitStatus(exitStatus: Int((status >> 8) & 0xff)))
                }
                self.closeSlave()
            }
        }
    }

    /// The channel closed: end the process, as closing an SSH channel hangs up its
    /// session (rtach's master, in its own session, stays)
    func hangUp() {
        lock.withLock {
            if !exited { kill(pid, SIGHUP) }
        }
    }

    /// The terminal's new size, and SIGWINCH to tell rtach's proxy: it also comes as rtach's
    /// own packet, but only once the stream is framed
    func resize(rows: Int, columns: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard slave >= 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slave, TIOCSWINSZ, &size)
        if !exited { kill(pid, SIGWINCH) }
    }

    private func closeSlave() {
        lock.lock()
        defer { lock.unlock() }
        guard slave >= 0 else { return }
        close(slave)
        slave = -1
    }
}

/// Makes a terminal look like an SSH session channel to what's above it: bytes as
/// `SSHChannelData` both ways, and a window change sets the terminal's size
final class LocalTerminalHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = ByteBuffer

    private let terminal: LocalTerminal

    init(terminal: LocalTerminal) {
        self.terminal = terminal
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        context.fireChannelRead(wrapInboundOut(SSHChannelData(type: .channel, data: .byteBuffer(bytes))))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard case .byteBuffer(let bytes) = unwrapOutboundIn(data).data else {
            promise?.succeed(())
            return
        }
        context.write(wrapOutboundOut(bytes), promise: promise)
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if let change = event as? SSHChannelRequestEvent.WindowChangeRequest {
            terminal.resize(rows: change.terminalRowHeight, columns: change.terminalCharacterWidth)
            promise?.succeed(())
            return
        }
        context.triggerUserOutboundEvent(event, promise: promise)
    }

    /// A read after the process is gone fails (EIO): that's its end, not an error
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
