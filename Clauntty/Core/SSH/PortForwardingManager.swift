import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import os.log

/// Manages SSH port forwarding - creates a local socket that tunnels to a remote port
class PortForwardingManager {
    let localPort: Int
    let remoteHost: String
    let remotePort: Int

    private let eventLoopGroup: EventLoopGroup
    private let sshChannel: Channel
    private var serverChannel: Channel?

    /// Whether the forwarder is currently running
    private(set) var isRunning = false

    init(
        localPort: Int,
        remoteHost: String = "127.0.0.1",
        remotePort: Int,
        eventLoopGroup: EventLoopGroup,
        sshChannel: Channel
    ) {
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.eventLoopGroup = eventLoopGroup
        self.sshChannel = sshChannel
    }

    /// Start the port forwarding server
    /// Returns the actual local port (may differ if localPort was 0)
    func start() async throws -> Int {
        guard !isRunning else {
            Logger.clauntty.warning("PortForwarding: already running on port \(self.localPort)")
            return self.localPort
        }

        Logger.clauntty.debugOnly("PortForwarding: starting on localhost:\(self.localPort) -> \(self.remoteHost):\(self.remotePort)")

        let remoteHost = self.remoteHost
        let remotePort = self.remotePort
        let sshChannel = self.sshChannel

        let bootstrap = ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] inboundChannel in
                guard let self = self else {
                    return inboundChannel.eventLoop.makeFailedFuture(PortForwardingError.managerDeallocated)
                }
                return self.setupForwarding(
                    inboundChannel: inboundChannel,
                    sshChannel: sshChannel,
                    remoteHost: remoteHost,
                    remotePort: remotePort
                )
            }

        let server = try await bootstrap.bind(host: "127.0.0.1", port: localPort).get()
        self.serverChannel = server
        self.isRunning = true

        let boundPort = server.localAddress?.port ?? localPort
        Logger.clauntty.debugOnly("PortForwarding: listening on localhost:\(boundPort)")

        return boundPort
    }

    /// Stop the port forwarding server
    func stop() async throws {
        guard isRunning, let server = serverChannel else {
            return
        }

        Logger.clauntty.debugOnly("PortForwarding: stopping on port \(self.localPort)")
        try await server.close().get()
        serverChannel = nil
        isRunning = false
    }

    /// Set up forwarding for an incoming connection
    private func setupForwarding(
        inboundChannel: Channel,
        sshChannel: Channel,
        remoteHost: String,
        remotePort: Int
    ) -> EventLoopFuture<Void> {
        Logger.clauntty.debug("PortForwarding: new connection from \(String(describing: inboundChannel.remoteAddress))")

        // Get the SSH handler from the main connection channel
        return sshChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler -> EventLoopFuture<Void> in
            let promise = inboundChannel.eventLoop.makePromise(of: Channel.self)

            // Create directTCPIP channel to remote
            let directTCPIP = SSHChannelType.DirectTCPIP(
                targetHost: remoteHost,
                targetPort: remotePort,
                originatorAddress: inboundChannel.remoteAddress!
            )

            sshHandler.createChannel(promise, channelType: .directTCPIP(directTCPIP)) { childChannel, channelType in
                guard case .directTCPIP = channelType else {
                    return childChannel.eventLoop.makeFailedFuture(PortForwardingError.invalidChannelType)
                }

                return childChannel.eventLoop.makeCompletedFuture {
                    // Create paired glue handlers to relay data between channels
                    let (sshSide, localSide) = GlueHandler.matchedPair()

                    // Add handlers to SSH child channel
                    let childSync = childChannel.pipeline.syncOperations
                    try childSync.addHandler(SSHWrapperHandler())
                    try childSync.addHandler(sshSide)

                    // Add handler to local inbound channel
                    let inboundSync = inboundChannel.pipeline.syncOperations
                    try inboundSync.addHandler(localSide)
                }
            }

            return promise.futureResult.map { _ in
                Logger.clauntty.debug("PortForwarding: tunnel established to \(remoteHost):\(remotePort)")
            }
        }
    }
}

// MARK: - Errors

enum PortForwardingError: Error, LocalizedError {
    case managerDeallocated
    case invalidChannelType
    case notRunning

    var errorDescription: String? {
        switch self {
        case .managerDeallocated:
            return "Port forwarding manager was deallocated"
        case .invalidChannelType:
            return "Invalid SSH channel type for port forwarding"
        case .notRunning:
            return "Port forwarding is not running"
        }
    }
}

// MARK: - GlueHandler (from swift-nio-ssh examples)

/// Relays data bidirectionally between two channels
final class GlueHandler {
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead: Bool = false

    private init() {}
}

extension GlueHandler {
    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }
}

extension GlueHandler {
    private func partnerWrite(_ data: NIOAny) {
        self.context?.write(data, promise: nil)
    }

    private func partnerFlush() {
        self.context?.flush()
    }

    private func partnerWriteEOF() {
        self.context?.close(mode: .output, promise: nil)
    }

    private func partnerCloseFull() {
        self.context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if self.pendingRead {
            self.pendingRead = false
            self.context?.read()
        }
    }

    private var partnerWritable: Bool {
        self.context?.channel.isWritable ?? false
    }
}

extension GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable {
            self.partner?.partnerBecameWritable()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        self.partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.partner?.partnerWrite(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        self.partner?.partnerFlush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.partner?.partnerCloseFull()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            self.partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        Logger.clauntty.error("PortForwarding GlueHandler error: \(error)")
        self.partner?.partnerCloseFull()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            self.partner?.partnerBecameWritable()
        }
    }

    func read(context: ChannelHandlerContext) {
        if let partner = self.partner, partner.partnerWritable {
            context.read()
        } else {
            self.pendingRead = true
        }
    }
}

// MARK: - SSHWrapperHandler (from swift-nio-ssh examples)

/// Wraps/unwraps data in SSH channel format for port forwarding
final class SSHWrapperHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)

        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else {
            context.fireErrorCaught(PortForwardingError.invalidChannelType)
            return
        }

        context.fireChannelRead(self.wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(data))
        context.write(self.wrapOutboundOut(wrapped), promise: promise)
    }
}
