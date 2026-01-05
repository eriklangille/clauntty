import Foundation

/// Encodes data into rtach protocol packets
public enum PacketWriter {

    // MARK: - Push Packet (Keyboard Input)

    /// Create a push packet for keyboard/terminal input
    /// - Parameter data: The input data (max 255 bytes per packet)
    /// - Returns: Framed packet data
    public static func push(_ data: Data) -> Data {
        let len = UInt8(min(data.count, ProtocolConstants.maxPayloadSize))
        var packet = Data(capacity: Int(len) + ProtocolConstants.clientHeaderSize)
        packet.append(MessageType.push.rawValue)
        packet.append(len)
        packet.append(data.prefix(Int(len)))
        return packet
    }

    /// Split large input into multiple push packets
    /// - Parameter data: Input data of any size
    /// - Returns: Array of framed packets
    public static func pushChunked(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }

        var packets: [Data] = []
        var offset = 0

        while offset < data.count {
            let remaining = data.count - offset
            let chunkSize = min(remaining, ProtocolConstants.maxPayloadSize)
            let chunk = data.subdata(in: offset..<(offset + chunkSize))
            packets.append(push(chunk))
            offset += chunkSize
        }

        return packets
    }

    // MARK: - Control Packets

    /// Create an upgrade packet to switch rtach to framed mode with compression
    /// Payload: [compression_type: 1 byte] where 0x01 = zlib
    public static func upgrade() -> Data {
        var packet = Data(capacity: ProtocolConstants.clientHeaderSize + 1)
        packet.append(MessageType.upgrade.rawValue)
        packet.append(1) // Payload length: 1 byte
        packet.append(ProtocolConstants.compressionZlib) // Request zlib compression
        return packet
    }

    /// Create an attach packet
    /// - Parameter clientId: Optional 16-byte client ID for deduplication
    public static func attach(clientId: Data? = nil) -> Data {
        var packet = Data(capacity: ProtocolConstants.clientHeaderSize + ProtocolConstants.clientIdSize)
        packet.append(MessageType.attach.rawValue)

        if let clientId = clientId, clientId.count == ProtocolConstants.clientIdSize {
            packet.append(UInt8(ProtocolConstants.clientIdSize))
            packet.append(clientId)
        } else {
            packet.append(0)
        }

        return packet
    }

    /// Create a detach packet
    public static func detach() -> Data {
        var packet = Data(capacity: ProtocolConstants.clientHeaderSize)
        packet.append(MessageType.detach.rawValue)
        packet.append(0)
        return packet
    }

    /// Create a redraw request packet
    public static func redraw() -> Data {
        var packet = Data(capacity: ProtocolConstants.clientHeaderSize)
        packet.append(MessageType.redraw.rawValue)
        packet.append(0)
        return packet
    }

    /// Create a window size change packet
    public static func winch(_ size: WindowSize) -> Data {
        var packet = Data(capacity: ProtocolConstants.clientHeaderSize + ProtocolConstants.winsizeSize)
        packet.append(MessageType.winch.rawValue)
        packet.append(UInt8(ProtocolConstants.winsizeSize))

        withUnsafeBytes(of: size.rows.littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: size.cols.littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: size.xpixel.littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: size.ypixel.littleEndian) { packet.append(contentsOf: $0) }

        return packet
    }

    // MARK: - Scrollback Requests

    /// Create a scrollback page request packet
    /// - Parameters:
    ///   - offset: Byte offset from start of scrollback (0 = oldest)
    ///   - limit: Maximum bytes to return
    public static func scrollbackPageRequest(offset: UInt32, limit: UInt32) -> Data {
        var packet = Data(capacity: ProtocolConstants.clientHeaderSize + ProtocolConstants.scrollbackRequestSize)
        packet.append(MessageType.requestScrollbackPage.rawValue)
        packet.append(UInt8(ProtocolConstants.scrollbackRequestSize))

        withUnsafeBytes(of: offset.littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: limit.littleEndian) { packet.append(contentsOf: $0) }

        return packet
    }

    /// Create a legacy scrollback request (requests all at once)
    public static func scrollbackRequest() -> Data {
        var packet = Data(capacity: ProtocolConstants.clientHeaderSize)
        packet.append(MessageType.requestScrollback.rawValue)
        packet.append(0)
        return packet
    }

    // MARK: - Power Management

    /// Create a pause packet to stop terminal output streaming
    /// Used for battery optimization when tab is inactive
    public static func pause() -> Data {
        var packet = Data(capacity: ProtocolConstants.clientHeaderSize)
        packet.append(MessageType.pause.rawValue)
        packet.append(0)
        return packet
    }

    /// Create a resume packet to resume terminal output streaming
    /// rtach will flush any buffered output since pause
    public static func resume() -> Data {
        var packet = Data(capacity: ProtocolConstants.clientHeaderSize)
        packet.append(MessageType.resume.rawValue)
        packet.append(0)
        return packet
    }

    /// Create a claim-active packet to mark this client as active
    public static func claimActive() -> Data {
        var packet = Data(capacity: ProtocolConstants.clientHeaderSize)
        packet.append(MessageType.claimActive.rawValue)
        packet.append(0)
        return packet
    }
}
