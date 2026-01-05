import Foundation

/// Delegate for RtachSession events
public protocol RtachSessionDelegate: AnyObject {
    /// Called when terminal data should be displayed
    func rtachSession(_ session: RtachSession, didReceiveTerminalData data: Data)

    /// Called when scrollback data is received (legacy)
    func rtachSession(_ session: RtachSession, didReceiveScrollback data: Data)

    /// Called when paginated scrollback is received
    func rtachSession(_ session: RtachSession, didReceiveScrollbackPage meta: ScrollbackPageMeta, data: Data)

    /// Called when a command is received from server
    func rtachSession(_ session: RtachSession, didReceiveCommand data: Data)

    /// Called when shell is idle (waiting for input, no PTY output for 2s)
    /// Used for background notifications and pre-fetching
    func rtachSessionDidReceiveIdle(_ session: RtachSession)

    /// Called when data should be sent to the remote server
    func rtachSession(_ session: RtachSession, sendData data: Data)

    /// Called when framed mode is established (after handshake)
    func rtachSessionDidEnterFramedMode(_ session: RtachSession)
}

/// State machine managing rtach protocol communication
///
/// Handles the protocol upgrade flow:
/// 1. Start in raw mode (no framing)
/// 2. Receive handshake from rtach
/// 3. Send upgrade packet
/// 4. Switch to framed mode (frame all keyboard input)
public final class RtachSession {

    // MARK: - Properties

    /// Session state
    public enum State: Sendable, Equatable {
        /// Not connected or rtach not detected
        case disconnected
        /// Connected, waiting for handshake (raw mode)
        case rawMode
        /// Received handshake, switching to framed mode
        case framedMode(version: String)
    }

    /// Current session state
    public private(set) var state: State = .disconnected

    /// Received handshake (nil if rtach not running)
    public private(set) var handshake: Handshake?

    /// Delegate for events
    public weak var delegate: RtachSessionDelegate?

    /// Whether to expect rtach handshake. If false, all data passes through raw.
    public var expectsRtach: Bool = true

    /// Frame parser for incoming data
    private let reader = PacketReader()

    /// Buffer for raw mode data (looking for handshake)
    private var rawBuffer = Data()

    /// Whether we're in framed mode (shorthand)
    public var isFramedMode: Bool {
        if case .framedMode = state { return true }
        return false
    }

    /// Whether rtach is detected (received valid handshake)
    public var isRtachRunning: Bool {
        handshake?.isValid == true
    }

    /// Protocol version string (e.g., "2.0")
    public var protocolVersion: String? {
        guard let h = handshake, h.isValid else { return nil }
        return "\(h.versionMajor).\(h.versionMinor)"
    }

    // MARK: - Lifecycle

    public init() {}

    /// Reset session state (e.g., on disconnect)
    public func reset() {
        state = .disconnected
        handshake = nil
        reader.reset()
        rawBuffer.removeAll()
    }

    /// Mark session as connected (enters raw mode)
    public func connect() {
        state = .rawMode
        reader.reset()
        rawBuffer.removeAll()
    }

    // MARK: - Incoming Data

    /// Process data received from the server
    /// - Parameter data: Raw data from SSH channel
    public func processIncomingData(_ data: Data) {
        switch state {
        case .disconnected:
            // Ignore data when disconnected
            return

        case .rawMode:
            // In raw mode, try to parse frames (looking for handshake)
            // But also pass through terminal data directly if no valid frame
            processRawModeData(data)

        case .framedMode:
            // In framed mode, parse all data as frames
            let responses = reader.process(data)
            for response in responses {
                handleResponse(response)
            }
        }
    }

    /// Process data in raw mode - look for handshake but pass through terminal data
    private func processRawModeData(_ data: Data) {
        // If not expecting rtach, just pass through all data directly
        if !expectsRtach {
            delegate?.rtachSession(self, didReceiveTerminalData: data)
            return
        }

        rawBuffer.append(data)

        // Handshake frame format: [type=255][len=8 LE][payload=8 bytes]
        // Total: 5 (header) + 8 (payload) = 13 bytes
        let handshakeFrameSize = ProtocolConstants.responseHeaderSize + ProtocolConstants.handshakeSize

        // Scan buffer for handshake pattern (could be after raw shell output)
        var i = rawBuffer.startIndex
        while i <= rawBuffer.endIndex - handshakeFrameSize {
            let type = rawBuffer[i]
            let len = UInt32(rawBuffer[i + 1]) |
                     (UInt32(rawBuffer[i + 2]) << 8) |
                     (UInt32(rawBuffer[i + 3]) << 16) |
                     (UInt32(rawBuffer[i + 4]) << 24)

            if type == ResponseType.handshake.rawValue && len == UInt32(ProtocolConstants.handshakeSize) {
                // Looks like a handshake! Try to parse it
                let payloadStart = i + ProtocolConstants.responseHeaderSize
                let payloadData = Data(rawBuffer[payloadStart..<(payloadStart + ProtocolConstants.handshakeSize)])

                if let h = Handshake(from: payloadData), h.isValid {
                    // Forward any data before handshake as raw terminal data
                    if i > rawBuffer.startIndex {
                        let beforeHandshake = Data(rawBuffer[rawBuffer.startIndex..<i])
                        delegate?.rtachSession(self, didReceiveTerminalData: beforeHandshake)
                    }

                    // Valid handshake! Switch to framed mode
                    handleHandshake(h)

                    // Process remaining data (after handshake) as framed
                    let afterHandshake = i + handshakeFrameSize
                    let remaining = Data(rawBuffer[afterHandshake...])
                    rawBuffer.removeAll()

                    if !remaining.isEmpty {
                        let responses = reader.process(remaining)
                        for response in responses {
                            handleResponse(response)
                        }
                    }
                    return
                }
            }
            i += 1
        }

        // No handshake found yet
        // If buffer is getting large, forward the safe portion as raw terminal data
        // Keep last (handshakeFrameSize - 1) bytes in case handshake spans packets
        if rawBuffer.count > handshakeFrameSize * 2 {
            let safeToForward = rawBuffer.count - handshakeFrameSize + 1
            let toForward = Data(rawBuffer.prefix(safeToForward))
            rawBuffer = Data(rawBuffer.dropFirst(safeToForward))
            delegate?.rtachSession(self, didReceiveTerminalData: toForward)
        }
    }

    /// Handle handshake from server
    private func handleHandshake(_ h: Handshake) {
        self.handshake = h

        guard h.isValid else {
            // Invalid handshake - stay in raw mode
            return
        }

        let version = "\(h.versionMajor).\(h.versionMinor)"

        // Send upgrade packet to switch rtach to framed mode
        let upgradePacket = PacketWriter.upgrade()
        delegate?.rtachSession(self, sendData: upgradePacket)

        // Switch to framed mode
        state = .framedMode(version: version)

        // Notify delegate that framed mode is now active
        delegate?.rtachSessionDidEnterFramedMode(self)
    }

    /// Handle parsed response
    private func handleResponse(_ response: RtachResponse) {
        switch response {
        case .terminalData(let data):
            delegate?.rtachSession(self, didReceiveTerminalData: data)

        case .scrollback(let data):
            delegate?.rtachSession(self, didReceiveScrollback: data)

        case .scrollbackPage(let meta, let data):
            delegate?.rtachSession(self, didReceiveScrollbackPage: meta, data: data)

        case .command(let data):
            delegate?.rtachSession(self, didReceiveCommand: data)

        case .idle:
            delegate?.rtachSessionDidReceiveIdle(self)

        case .handshake(let h):
            // Handshake in framed mode - shouldn't happen but handle gracefully
            handleHandshake(h)
        }
    }

    // MARK: - Outgoing Data

    /// Send keyboard input to the server
    /// - Parameter data: Keyboard input data
    /// - Note: Automatically frames as push packet(s) when in framed mode
    public func sendKeyboardInput(_ data: Data) {
        guard !data.isEmpty else { return }

        switch state {
        case .disconnected:
            return

        case .rawMode:
            // Raw mode - send directly without framing
            delegate?.rtachSession(self, sendData: data)

        case .framedMode:
            // Framed mode - wrap in push packet(s)
            // IMPORTANT: Coalesce all packets into a single write to prevent
            // packets from being lost in the SSH channel buffering
            let packets = PacketWriter.pushChunked(data)
            if packets.count == 1 {
                delegate?.rtachSession(self, sendData: packets[0])
            } else {
                // Combine all packets into one Data for atomic write
                var combined = Data()
                for packet in packets {
                    combined.append(packet)
                }
                delegate?.rtachSession(self, sendData: combined)
            }
        }
    }

    /// Send window size change
    /// - Parameter size: New window size
    public func sendWindowSize(_ size: WindowSize) {
        guard isFramedMode else { return }
        let packet = PacketWriter.winch(size)
        delegate?.rtachSession(self, sendData: packet)
    }

    /// Request redraw
    public func requestRedraw() {
        guard isFramedMode else { return }
        let packet = PacketWriter.redraw()
        delegate?.rtachSession(self, sendData: packet)
    }

    /// Request scrollback page
    /// - Parameters:
    ///   - offset: Byte offset from start of scrollback (0 = oldest)
    ///   - limit: Maximum bytes to return
    public func requestScrollbackPage(offset: UInt32, limit: UInt32) {
        guard isFramedMode else { return }
        let packet = PacketWriter.scrollbackPageRequest(offset: offset, limit: limit)
        delegate?.rtachSession(self, sendData: packet)
    }

    /// Request all scrollback (legacy)
    public func requestScrollback() {
        guard isFramedMode else { return }
        let packet = PacketWriter.scrollbackRequest()
        delegate?.rtachSession(self, sendData: packet)
    }

    /// Send attach packet
    /// - Parameter clientId: Optional 16-byte client ID for deduplication
    public func sendAttach(clientId: Data? = nil) {
        guard isFramedMode else { return }
        let packet = PacketWriter.attach(clientId: clientId)
        delegate?.rtachSession(self, sendData: packet)
    }

    /// Send detach packet
    public func sendDetach() {
        guard isFramedMode else { return }
        let packet = PacketWriter.detach()
        delegate?.rtachSession(self, sendData: packet)
    }

    // MARK: - Power Management

    /// Pause terminal output streaming (battery optimization)
    /// rtach will buffer output locally and send idle notifications
    public func sendPause() {
        guard isFramedMode else { return }
        let packet = PacketWriter.pause()
        delegate?.rtachSession(self, sendData: packet)
    }

    /// Resume terminal output streaming
    /// rtach will flush any buffered output since pause
    public func sendResume() {
        guard isFramedMode else { return }
        let packet = PacketWriter.resume()
        delegate?.rtachSession(self, sendData: packet)
    }

    /// Claim active client for window size and command routing
    public func sendClaimActive() {
        guard isFramedMode else { return }
        let packet = PacketWriter.claimActive()
        delegate?.rtachSession(self, sendData: packet)
    }
}
