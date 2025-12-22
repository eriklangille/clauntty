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

    private let host: String
    private let port: Int
    private let username: String
    private let authMethod: AuthMethod
    private let connectionId: UUID

    // MARK: - NIO Components

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var sshChildChannel: Channel?
    private var channelHandler: SSHChannelHandler?

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
        guard let channel = self.channel else {
            throw SSHError.notConnected
        }

        // Capture callback for closure
        let onDataReceived = self.onDataReceived

        // Create channel handler
        let handler = SSHChannelHandler(onDataReceived: onDataReceived)
        self.channelHandler = handler

        // Create child channel for PTY session
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
            return
        }

        // Get bytes and send to terminal for display
        if let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
            let data = Data(bytes)
            DispatchQueue.main.async { [weak self] in
                self?.onDataReceived?(data)
            }
        }
    }

    /// Send data to the remote SSH server
    func sendToRemote(_ data: Data) {
        guard let context = context else { return }

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
