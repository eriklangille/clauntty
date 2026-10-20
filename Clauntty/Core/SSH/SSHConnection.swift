import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os.log

/// Remote platform info (OS and architecture)
struct RemotePlatform {
    let os: String      // "linux" or "darwin"
    let arch: String    // "x86_64" or "aarch64"
}

/// Manages an SSH connection lifecycle
@MainActor
class SSHConnection: ObservableObject {
    // MARK: - State

    enum State {
        case disconnected
        case connecting
        case authenticating
        case connected
        case error(Error)
    }

    @Published var state: State = .disconnected

    // MARK: - Configuration

    let host: String
    let port: Int
    let username: String
    /// Dial through the embedded Tailscale node instead of the device network
    let useTailscale: Bool
    /// An ssh_config ProxyCommand to carry the connection (macOS)
    let proxyCommand: String?
    private let authMethod: AuthMethod
    private let connectionId: UUID

    // MARK: - NIO Components

    private var channel: Channel?
    #if os(macOS)
    /// The running ProxyCommand, if the connection goes through one
    private var proxyProcess: ProxyCommandProcess?
    #endif

    /// Cached remote platform (detected once per connection)
    private var cachedPlatform: RemotePlatform?

    /// Server accepted our auth; a banner arriving after this is stale
    private var authSucceeded = false

    /// Panes the server allowed on this connection before it refused another channel
    /// (fewer sessions per connection than SessionManager assumes); nil until then
    var paneLimit: Int?

    /// Pane channels on this connection, open or about to open: a pane takes its place
    /// when the connection is chosen for it and gives it back when its channel closes
    private(set) var paneChannels = 0

    func reservePane() {
        paneChannels += 1
    }

    func releasePane() {
        paneChannels = max(paneChannels - 1, 0)
    }

    /// Expose event loop group for port forwarding
    /// Uses the global singleton - never creates/destroys threads on reconnect
    var nioEventLoopGroup: EventLoopGroup { MultiThreadedEventLoopGroup.singleton }

    /// Expose main SSH channel for port forwarding
    var nioChannel: Channel? { channel }

    // MARK: - Data Flow Callbacks

    /// Callback when connected
    var onConnected: (() -> Void)?
    var onDisconnected: ((Error?) -> Void)?

    // MARK: - Initialization

    init(
        host: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod,
        connectionId: UUID,
        useTailscale: Bool = false,
        proxyCommand: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.useTailscale = useTailscale
        self.proxyCommand = proxyCommand
        self.authMethod = authMethod
        self.connectionId = connectionId
    }

    // MARK: - Connection

    func connect() async throws {
        state = .connecting
        authSucceeded = false
        Logger.clauntty.debugOnly("SSH connecting to \(self.host):\(self.port)\(self.useTailscale ? " via Tailscale" : "")")

        do {
            // Use global singleton event loop group - never creates new threads on reconnect
            // This is the recommended pattern for iOS apps per SwiftNIO best practices
            let group = MultiThreadedEventLoopGroup.singleton

            // Capture values for closure
            let username = self.username
            let authMethod = self.authMethod
            let connectionId = self.connectionId

            // Banner events arrive on the event loop; handle them on the main actor
            let onBanner: (String) -> Void = { [weak self] message in
                Task { @MainActor in self?.authBannerReceived(message) }
            }
            let onAuthSucceeded: () -> Void = { [weak self] in
                Task { @MainActor in self?.authSucceededReceived() }
            }

            // Add SSH handler, then the banner handler after it
            // (runs on the channel's event loop, so sync operations are fine)
            let initializeChannel: @Sendable (Channel) -> EventLoopFuture<Void> = { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers(
                            NIOSSHHandler(
                                role: .client(.init(
                                    userAuthDelegate: SSHAuthenticator(
                                        username: username,
                                        authMethod: authMethod,
                                        connectionId: connectionId
                                    ),
                                    serverAuthDelegate: AcceptAllHostKeysDelegate()
                                )),
                                allocator: channel.allocator,
                                inboundChildChannelInitializer: nil
                            ),
                            SSHAuthBannerHandler(onBanner: onBanner, onAuthSucceeded: onAuthSucceeded)
                        )
                    }
            }

            // Create client bootstrap
            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer(initializeChannel)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .connectTimeout(.seconds(30))

            // Connect
            let channel: Channel
            #if os(iOS)
            if useTailscale {
                let fd = try await TailscaleManager.shared.dial(host: host, port: port)
                channel = try await bootstrap.withConnectedSocket(fd).get()
            } else {
                channel = try await bootstrap.connect(host: host, port: port).get()
            }
            #else
            if let proxyCommand {
                // As ssh does: run the command, and SSH goes over its stdin and stdout
                let proxy = try ProxyCommandProcess(proxyCommand, host: host, port: port, user: username)
                proxyProcess = proxy
                channel = try await NIOPipeBootstrap(group: group)
                    .channelInitializer(initializeChannel)
                    .takingOwnershipOfDescriptors(input: proxy.readDescriptor, output: proxy.writeDescriptor)
                    .get()
            } else {
                channel = try await bootstrap.connect(host: host, port: port).get()
            }
            #endif
            self.channel = channel
            Logger.clauntty.debugOnly("SSH TCP connection established")

            state = .authenticating

            // Authentication finishes with the first channel: a round trip that opens one
            // and closes it again. The connection only carries channels (each pane's, and
            // commands); it used to open a login shell here that nothing read, a `login`
            // and a shell left on the host per connection.
            try await openAndCloseChannel()

            state = .connected
            Logger.clauntty.debugOnly("SSH connected")
            onConnected?()

        } catch {
            Logger.clauntty.error("SSH connection failed: \(error.localizedDescription)")
            #if os(macOS)
            proxyProcess?.terminate()
            proxyProcess = nil
            #endif
            SSHAuthPrompts.shared.resolve(self)
            state = .error(error)
            throw error
        }
    }

    /// A banner with a link means the server wants the user to sign in somewhere
    /// (Tailscale SSH check mode) and is holding authentication until they do
    private func authBannerReceived(_ message: String) {
        Logger.clauntty.debugOnly("SSH banner from \(self.host): \(message)")
        TailscaleDebugLog.note("ssh banner from \(host): \(message.replacingOccurrences(of: "\n", with: " "))")
        guard !authSucceeded, let url = SSHAuthPrompts.link(in: message) else { return }
        SSHAuthPrompts.shared.show(for: self, host: host, message: message, url: url) { [weak self] in
            self?.disconnect()
        }
    }

    private func authSucceededReceived() {
        authSucceeded = true
        TailscaleDebugLog.note("ssh auth succeeded for \(host)")
        SSHAuthPrompts.shared.resolve(self)
    }

    /// Open a session channel and close it, so connect() returns once the server has
    /// accepted us (a failed authentication fails here)
    private func openAndCloseChannel() async throws {
        guard let channel = self.channel else {
            throw SSHError.notConnected
        }
        let probe = try await channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
            let promise = channel.eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise) { childChannel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                return childChannel.eventLoop.makeSucceededVoidFuture()
            }
            return promise.futureResult
        }.get()
        probe.close(promise: nil)
    }

    /// Check if connection is still active
    var isConnected: Bool {
        channel?.isActive ?? false
    }

    /// Round trip to the server: open a channel and close it again. A connection whose
    /// network went away (Wi-Fi off, phone asleep) still reports active until TCP gives
    /// up minutes later; this finds out within `timeout`.
    func isResponsive(timeout: TimeAmount = .seconds(8)) async -> Bool {
        guard let channel, channel.isActive else { return false }

        let eventLoop = channel.eventLoop
        let answered = eventLoop.makePromise(of: Bool.self)
        let timeoutTask = eventLoop.scheduleTask(in: timeout) {
            answered.succeed(false)
        }

        channel.pipeline.handler(type: NIOSSHHandler.self).whenComplete { result in
            guard case .success(let sshHandler) = result else {
                timeoutTask.cancel()
                answered.succeed(false)
                return
            }
            let opened = eventLoop.makePromise(of: Channel.self)
            sshHandler.createChannel(opened) { childChannel, _ in
                childChannel.eventLoop.makeSucceededVoidFuture()
            }
            opened.futureResult.whenComplete { result in
                timeoutTask.cancel()
                switch result {
                case .success(let probeChannel):
                    probeChannel.close(promise: nil)
                    answered.succeed(true)
                case .failure:
                    // Refused (a connection at the server's MaxSessions) is an answer too;
                    // a connection that's gone is inactive by now
                    answered.succeed(channel.isActive)
                }
            }
        }

        // The first answer wins; a late one after the timeout is ignored
        return (try? await answered.futureResult.get()) ?? false
    }

    /// Create additional channel on existing connection (for multi-tab support)
    /// Returns the channel and handler for the caller to manage
    /// - Parameters:
    ///   - terminalSize: Initial terminal size (rows, columns). Defaults to reasonable mobile size.
    ///   - command: Optional command to execute (uses ExecRequest). If nil, uses ShellRequest.
    ///   - onDataReceived: Callback for received data
    ///   - onChannelInactive: Callback when channel becomes inactive (connection lost)
    func createChannel(
        terminalSize: (rows: Int, columns: Int) = (30, 60),
        command: String? = nil,
        onDataReceived: @escaping (Data) -> Void,
        onChannelInactive: (() -> Void)? = nil
    ) async throws -> (Channel, SSHChannelHandler) {
        guard let channel = self.channel, channel.isActive else {
            throw SSHError.notConnected
        }

        let handler = SSHChannelHandler(onDataReceived: onDataReceived, onChannelInactive: onChannelInactive)

        let childChannel = try await channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
            let promise = channel.eventLoop.makePromise(of: Channel.self)

            sshHandler.createChannel(promise) { childChannel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                return childChannel.pipeline.addHandler(handler)
            }

            return promise.futureResult
        }.get()

        // Request PTY with actual terminal size
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: terminalSize.columns,
            terminalRowHeight: terminalSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )

        Logger.clauntty.debugOnly("SSH PTY request: \(terminalSize.columns)x\(terminalSize.rows)")
        // Both requests go out together and are answered in order: waiting for the PTY's
        // reply before asking for the command cost a round trip on every attach
        let ptyReplied = childChannel.eventLoop.makePromise(of: Void.self)
        let started = childChannel.eventLoop.makePromise(of: Void.self)
        childChannel.triggerUserOutboundEvent(ptyRequest, promise: ptyReplied)
        if let command = command {
            // Execute specific command (e.g., rtach-wrapped shell)
            let execRequest = SSHChannelRequestEvent.ExecRequest(
                command: command,
                wantReply: true
            )
            childChannel.triggerUserOutboundEvent(execRequest, promise: started)
            Logger.clauntty.debugOnly("SSH exec: \(command)")
        } else {
            // Request interactive shell
            let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
            childChannel.triggerUserOutboundEvent(shellRequest, promise: started)
            Logger.clauntty.debugOnly("SSH shell started")
        }
        try await ptyReplied.futureResult.get()
        try await started.futureResult.get()

        Logger.clauntty.debugOnly("SSH channel created")
        return (childChannel, handler)
    }

    /// Execute a command and return output (for setup/deployment)
    func executeCommand(_ command: String) async throws -> String {
        let output = try await executeCommandData(command)
        return String(data: output, encoding: .utf8) ?? ""
    }

    /// Execute a command and return its raw stdout (e.g. a downloaded file)
    func executeCommandData(_ command: String) async throws -> Data {
        Logger.clauntty.debugOnly("executeCommand: starting '\(command.prefix(50))...'")
        guard let channel = self.channel, channel.isActive else {
            Logger.clauntty.error("executeCommand: channel not connected")
            throw SSHError.notConnected
        }

        var output = Data()
        let outputLock = NSLock()

        let handler = SSHChannelHandler(onDataReceived: { data in
            outputLock.lock()
            output.append(data)
            outputLock.unlock()
        })

        let childChannel = try await channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
            let promise = channel.eventLoop.makePromise(of: Channel.self)

            sshHandler.createChannel(promise) { childChannel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                return childChannel.pipeline.addHandler(handler)
            }

            return promise.futureResult
        }.get()

        // Request exec (not shell)
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )
        Logger.clauntty.debugOnly("executeCommand: sending exec request...")
        try await childChannel.triggerUserOutboundEvent(execRequest).get()
        Logger.clauntty.debugOnly("executeCommand: exec request sent, waiting for channel close...")

        // Wait for channel to close (command completed)
        try await childChannel.closeFuture.get()
        Logger.clauntty.debugOnly("executeCommand: channel closed, output=\(output.count) bytes")

        return outputLock.withLock { output }
    }

    /// Execute a command and write binary data to stdin
    func executeWithStdin(_ command: String, stdinData: Data) async throws {
        guard let channel = self.channel, channel.isActive else {
            Logger.clauntty.error("executeWithStdin: channel not connected or inactive")
            throw SSHError.notConnected
        }

        Logger.clauntty.debugOnly("executeWithStdin: creating child channel for: \(command)")

        let handler = SSHChannelHandler(onDataReceived: nil)

        let childChannel = try await channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
            let promise = channel.eventLoop.makePromise(of: Channel.self)

            sshHandler.createChannel(promise) { childChannel, channelType in
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                return childChannel.pipeline.addHandler(handler)
            }

            return promise.futureResult
        }.get()

        // Request exec
        Logger.clauntty.debugOnly("executeWithStdin: child channel created, requesting exec")
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )
        try await childChannel.triggerUserOutboundEvent(execRequest).get()
        Logger.clauntty.debugOnly("executeWithStdin: exec request sent, writing \(stdinData.count) bytes")

        // Write stdin data directly to channel (with proper await via promise)
        let writePromise = childChannel.eventLoop.makePromise(of: Void.self)
        childChannel.eventLoop.execute {
            var buffer = childChannel.allocator.buffer(capacity: stdinData.count)
            buffer.writeBytes(stdinData)
            let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            childChannel.writeAndFlush(channelData, promise: writePromise)
        }
        try await writePromise.futureResult.get()
        Logger.clauntty.debugOnly("executeWithStdin: data written, sending EOF")

        // Send EOF to indicate we're done writing (close output side of channel)
        // The channel might already be closed if the command completed very quickly,
        // so we handle ChannelError.alreadyClosed gracefully
        do {
            try await childChannel.close(mode: .output).get()
            Logger.clauntty.debugOnly("executeWithStdin: EOF sent, waiting for close")
        } catch let error as ChannelError where error == .alreadyClosed {
            Logger.clauntty.debugOnly("executeWithStdin: channel already closed (command completed quickly)")
            return
        }

        // Wait for command to complete
        try await childChannel.closeFuture.get()
        Logger.clauntty.debugOnly("executeWithStdin: command completed successfully")
    }

    /// Get remote platform info (OS and architecture)
    /// Result is cached for the lifetime of this connection
    func getRemotePlatform() async throws -> RemotePlatform {
        if let cached = cachedPlatform {
            return cached
        }

        let output = try await executeCommand("uname -sm")
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count >= 2 else {
            throw SSHError.internalError("Could not detect remote platform: \(output)")
        }

        let osName = String(parts[0]).lowercased()
        let archName = String(parts[1])

        // Normalize OS
        let os: String
        switch osName {
        case "linux":
            os = "linux"
        case "darwin":
            os = "darwin"
        default:
            throw SSHError.internalError("Unsupported OS: \(osName)")
        }

        // Normalize arch names
        let arch: String
        switch archName {
        case "x86_64", "amd64":
            arch = "x86_64"
        case "aarch64", "arm64":
            arch = "aarch64"
        default:
            throw SSHError.internalError("Unsupported architecture: \(archName)")
        }

        let platform = RemotePlatform(os: os, arch: arch)
        cachedPlatform = platform
        Logger.clauntty.debugOnly("Detected remote platform: \(os) \(arch)")
        return platform
    }

    func disconnect() {
        Logger.clauntty.debugOnly("SSH disconnecting")
        channel?.close(mode: .all, promise: nil)
        channel = nil
        #if os(macOS)
        proxyProcess?.terminate()
        proxyProcess = nil
        #endif
        SSHAuthPrompts.shared.resolve(self)

        // Note: We don't shut down the event loop group since we use the global singleton
        // The singleton is designed to run for the entire app lifetime

        state = .disconnected
        onDisconnected?(nil)
    }
}

// MARK: - SSH Channel Handler

/// Handles SSH channel data
final class SSHChannelHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    /// Callback when data is received from SSH
    private let onDataReceived: ((Data) -> Void)?

    /// Callback when channel becomes inactive (connection lost)
    private let onChannelInactive: (() -> Void)?

    /// The context owns this handler, so holding it is a cycle until handlerRemoved clears
    /// it. Before that was done, every closed channel (including each executeCommand) left
    /// its handler and context behind. Locked: sendToRemote reads it off the event loop.
    private var _context: ChannelHandlerContext?
    private let contextLock = NSLock()
    private var context: ChannelHandlerContext? {
        contextLock.lock()
        defer { contextLock.unlock() }
        return _context
    }

    private var _exitStatus: Int?
    /// The remote command's exit status, once it has exited (it arrives before the
    /// channel closes)
    var exitStatus: Int? {
        contextLock.lock()
        defer { contextLock.unlock() }
        return _exitStatus
    }

    init(onDataReceived: ((Data) -> Void)?, onChannelInactive: (() -> Void)? = nil) {
        self.onDataReceived = onDataReceived
        self.onChannelInactive = onChannelInactive
    }

    func handlerAdded(context: ChannelHandlerContext) {
        contextLock.lock()
        _context = context
        contextLock.unlock()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        contextLock.lock()
        _context = nil
        contextLock.unlock()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        // Only handle standard data (not extended/stderr)
        guard case .byteBuffer(let buffer) = channelData.data,
              channelData.type == .channel else {
            Logger.clauntty.verbose("channelRead: ignoring non-channel data, type=\(String(describing: channelData.type))")
            return
        }

        // Get bytes and send to terminal for display
        // Note: We don't dispatch to main here - the callback is responsible for its own threading.
        // SessionManager hops to the main queue (in order), and writeSSHOutput dispatches to
        // terminalIOQueue.
        if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
            let data = Data(bytes)
            Logger.clauntty.verbose("channelRead: received \(data.count) bytes from SSH")
            onDataReceived?(data)
        }
    }

    /// Send data to the remote SSH server
    func sendToRemote(_ data: Data) {
        guard let context = context else {
            Logger.clauntty.error("[PASTE] sendToRemote: no context!")
            return
        }

        let preview = data.prefix(10).map { String(format: "%02X", $0) }.joined(separator: " ")
        Logger.clauntty.verbose("[PASTE] sendToRemote: \(data.count) bytes, preview=\(preview)")
        Logger.clauntty.verbose("sendToRemote full: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")

        // IMPORTANT: NIO operations must be on the event loop thread
        context.eventLoop.execute {
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)

            let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            let promise = context.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { result in
                switch result {
                case .success:
                    Logger.clauntty.verbose("[PASTE] writeAndFlush SUCCESS: \(data.count) bytes")
                case .failure(let error):
                    Logger.clauntty.error("[PASTE] writeAndFlush FAILED: \(data.count) bytes, error: \(error)")
                }
            }
            context.writeAndFlush(self.wrapOutboundOut(channelData), promise: promise)
        }
    }

    /// Log how the remote side ends the channel (exit status, signal, EOF) to tell a
    /// remote exit apart from a local close
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            Logger.clauntty.debugOnly("SSH channel: remote exit status \(status.exitStatus)")
            contextLock.lock()
            _exitStatus = status.exitStatus
            contextLock.unlock()
        case let signal as SSHChannelRequestEvent.ExitSignal:
            Logger.clauntty.debugOnly("SSH channel: remote exit signal \(signal.signalName)")
        case ChannelEvent.inputClosed:
            Logger.clauntty.debugOnly("SSH channel: remote EOF")
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        Logger.clauntty.debugOnly("SSH channel became inactive (connection lost)")
        DispatchQueue.main.async { [weak self] in
            self?.onChannelInactive?()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.clauntty.error("SSH channel error: \(error)")
        context.close(promise: nil)
    }
}

// MARK: - Host Key Delegate

/// Accepts all host keys (for MVP - should implement known_hosts in production)
final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // WARNING: This accepts all host keys - insecure for production!
        // TODO: Implement proper host key verification
        validationCompletePromise.succeed(())
    }
}

// MARK: - Errors

enum SSHError: Error, LocalizedError {
    case notConnected
    case invalidChannelType
    case authenticationFailed
    case internalError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to SSH server"
        case .invalidChannelType:
            return "Invalid SSH channel type"
        case .authenticationFailed:
            return "SSH authentication failed"
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}
