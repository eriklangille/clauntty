import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os.log

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
    private let authMethod: AuthMethod
    private let connectionId: UUID

    // MARK: - NIO Components

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var sshChildChannel: Channel?
    private var channelHandler: SSHChannelHandler?

    /// Expose event loop group for port forwarding
    var nioEventLoopGroup: EventLoopGroup? { eventLoopGroup }

    /// Expose main SSH channel for port forwarding
    var nioChannel: Channel? { channel }

    // MARK: - Data Flow Callbacks

    /// Called when data is received from SSH (to display in terminal)
    var onDataReceived: ((Data) -> Void)?

    /// Callback when connected
    var onConnected: (() -> Void)?
    var onDisconnected: ((Error?) -> Void)?

    // MARK: - Initialization

    init(
        host: String,
        port: Int = 22,
        username: String,
        authMethod: AuthMethod,
        connectionId: UUID
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.connectionId = connectionId
    }

    // MARK: - Connection

    func connect() async throws {
        state = .connecting
        Logger.clauntty.info("SSH connecting to \(self.host):\(self.port)")

        do {
            // Create event loop group
            eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            guard let group = eventLoopGroup else {
                throw SSHError.internalError("Failed to create event loop group")
            }

            // Capture values for closure
            let username = self.username
            let authMethod = self.authMethod
            let connectionId = self.connectionId

            // Create client bootstrap
            let bootstrap = ClientBootstrap(group: group)
                .channelInitializer { channel in
                    // Add SSH handler
                    channel.pipeline.addHandlers([
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
                        )
                    ])
                }
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .connectTimeout(.seconds(30))

            // Connect
            let channel = try await bootstrap.connect(host: host, port: port).get()
            self.channel = channel
            Logger.clauntty.info("SSH TCP connection established")

            state = .authenticating

            // Create SSH channel for PTY
            try await createPTYChannel()

            state = .connected
            Logger.clauntty.info("SSH connected and shell ready")
            onConnected?()

        } catch {
            Logger.clauntty.error("SSH connection failed: \(error.localizedDescription)")
            state = .error(error)
            throw error
        }
    }

    private func createPTYChannel() async throws {
        Logger.clauntty.info("SSH: createPTYChannel starting...")
        guard let channel = self.channel else {
            throw SSHError.notConnected
        }

        // Capture callback for closure
        let onDataReceived = self.onDataReceived

        // Create channel handler
        let handler = SSHChannelHandler(onDataReceived: onDataReceived)
        self.channelHandler = handler

        // Create child channel for PTY session
        Logger.clauntty.info("SSH: getting NIOSSHHandler from pipeline...")
        let childChannel = try await channel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Channel> in
            Logger.clauntty.info("SSH: got handler, creating channel...")
            let promise = channel.eventLoop.makePromise(of: Channel.self)

            sshHandler.createChannel(promise) { childChannel, channelType in
                Logger.clauntty.info("SSH: channel callback, type=\(String(describing: channelType))")
                guard channelType == .session else {
                    return channel.eventLoop.makeFailedFuture(SSHError.invalidChannelType)
                }
                return childChannel.pipeline.addHandler(handler)
            }

            return promise.futureResult
        }.get()
        Logger.clauntty.info("SSH: child channel created")

        self.sshChildChannel = childChannel

        // Request PTY
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )

        try await childChannel.triggerUserOutboundEvent(ptyRequest).get()
        Logger.clauntty.info("SSH PTY requested")

        // Request shell
        let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await childChannel.triggerUserOutboundEvent(shellRequest).get()
        Logger.clauntty.info("SSH shell started")
    }

    /// Send data to the remote SSH server (e.g., keyboard input)
    func sendData(_ data: Data) {
        channelHandler?.sendToRemote(data)
    }

    /// Check if connection is still active
    var isConnected: Bool {
        channel?.isActive ?? false
    }

    /// Create additional channel on existing connection (for multi-tab support)
    /// Returns the channel and handler for the caller to manage
    /// - Parameters:
    ///   - terminalSize: Initial terminal size (rows, columns). Defaults to reasonable mobile size.
    ///   - command: Optional command to execute (uses ExecRequest). If nil, uses ShellRequest.
    ///   - onDataReceived: Callback for received data
    func createChannel(
        terminalSize: (rows: Int, columns: Int) = (30, 60),
        command: String? = nil,
        onDataReceived: @escaping (Data) -> Void
    ) async throws -> (Channel, SSHChannelHandler) {
        guard let channel = self.channel, channel.isActive else {
            throw SSHError.notConnected
        }

        let handler = SSHChannelHandler(onDataReceived: onDataReceived)

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

        Logger.clauntty.info("SSH PTY request: \(terminalSize.columns)x\(terminalSize.rows)")
        try await childChannel.triggerUserOutboundEvent(ptyRequest).get()

        if let command = command {
            // Execute specific command (e.g., rtach-wrapped shell)
            let execRequest = SSHChannelRequestEvent.ExecRequest(
                command: command,
                wantReply: true
            )
            try await childChannel.triggerUserOutboundEvent(execRequest).get()
            Logger.clauntty.info("SSH exec: \(command)")
        } else {
            // Request interactive shell
            let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: true)
            try await childChannel.triggerUserOutboundEvent(shellRequest).get()
            Logger.clauntty.info("SSH shell started")
        }

        Logger.clauntty.info("SSH channel created")
        return (childChannel, handler)
    }

    /// Execute a command and return output (for setup/deployment)
    func executeCommand(_ command: String) async throws -> String {
        Logger.clauntty.info("executeCommand: starting '\(command.prefix(50))...'")
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
        Logger.clauntty.info("executeCommand: sending exec request...")
        try await childChannel.triggerUserOutboundEvent(execRequest).get()
        Logger.clauntty.info("executeCommand: exec request sent, waiting for channel close...")

        // Wait for channel to close (command completed)
        try await childChannel.closeFuture.get()
        Logger.clauntty.info("executeCommand: channel closed, output=\(output.count) bytes")

        return String(data: output, encoding: .utf8) ?? ""
    }

    /// Execute a command and write binary data to stdin
    func executeWithStdin(_ command: String, stdinData: Data) async throws {
        guard let channel = self.channel, channel.isActive else {
            Logger.clauntty.error("executeWithStdin: channel not connected or inactive")
            throw SSHError.notConnected
        }

        Logger.clauntty.info("executeWithStdin: creating child channel for: \(command)")

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
        Logger.clauntty.info("executeWithStdin: child channel created, requesting exec")
        let execRequest = SSHChannelRequestEvent.ExecRequest(
            command: command,
            wantReply: true
        )
        try await childChannel.triggerUserOutboundEvent(execRequest).get()
        Logger.clauntty.info("executeWithStdin: exec request sent, writing \(stdinData.count) bytes")

        // Write stdin data directly to channel (with proper await via promise)
        let writePromise = childChannel.eventLoop.makePromise(of: Void.self)
        childChannel.eventLoop.execute {
            var buffer = childChannel.allocator.buffer(capacity: stdinData.count)
            buffer.writeBytes(stdinData)
            let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            childChannel.writeAndFlush(channelData, promise: writePromise)
        }
        try await writePromise.futureResult.get()
        Logger.clauntty.info("executeWithStdin: data written, sending EOF")

        // Send EOF to indicate we're done writing (close output side of channel)
        try await childChannel.close(mode: .output).get()
        Logger.clauntty.info("executeWithStdin: EOF sent, waiting for close")

        // Wait for command to complete
        try await childChannel.closeFuture.get()
        Logger.clauntty.info("executeWithStdin: command completed successfully")
    }

    /// Send terminal window size change to SSH server
    func sendWindowChange(rows: UInt16, columns: UInt16) {
        guard let childChannel = sshChildChannel else {
            Logger.clauntty.warning("Cannot send window change: no SSH channel")
            return
        }

        let windowChange = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: Int(columns),
            terminalRowHeight: Int(rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )

        // Must execute on event loop
        childChannel.eventLoop.execute {
            childChannel.triggerUserOutboundEvent(windowChange, promise: nil)
            Logger.clauntty.info("SSH window change sent: \(columns)x\(rows)")
        }
    }

    func disconnect() {
        Logger.clauntty.info("SSH disconnecting")
        channel?.close(mode: .all, promise: nil)
        channel = nil
        sshChildChannel = nil
        channelHandler = nil

        eventLoopGroup?.shutdownGracefully { _ in }
        eventLoopGroup = nil

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

    private var context: ChannelHandlerContext?

    init(onDataReceived: ((Data) -> Void)?) {
        self.onDataReceived = onDataReceived
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)

        // Only handle standard data (not extended/stderr)
        guard case .byteBuffer(let buffer) = channelData.data,
              channelData.type == .channel else {
            Logger.clauntty.debug("channelRead: ignoring non-channel data, type=\(String(describing: channelData.type))")
            return
        }

        // Get bytes and send to terminal for display
        if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
            let data = Data(bytes)
            Logger.clauntty.info("channelRead: received \(data.count) bytes from SSH")
            DispatchQueue.main.async { [weak self] in
                self?.onDataReceived?(data)
            }
        }
    }

    /// Send data to the remote SSH server
    func sendToRemote(_ data: Data) {
        guard let context = context else {
            Logger.clauntty.error("sendToRemote: no context!")
            return
        }

        let hexString = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        Logger.clauntty.info("sendToRemote: sending \(data.count) bytes to SSH: \(hexString)")

        // IMPORTANT: NIO operations must be on the event loop thread
        context.eventLoop.execute {
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)

            let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            context.writeAndFlush(self.wrapOutboundOut(channelData), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("SSH channel error: \(error)")
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
