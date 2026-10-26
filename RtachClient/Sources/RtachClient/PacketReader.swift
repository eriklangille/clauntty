import Foundation
import Compression
import os.log

private let decompressionLog = OSLog(subsystem: "com.clauntty", category: "decompress")

/// Parsed response from rtach server
public enum RtachResponse: Sendable, Equatable {
    /// Terminal data (PTY output)
    case terminalData(Data)
    /// Legacy scrollback data (all at once)
    case scrollback(Data)
    /// Command from server-side scripts
    case command(Data)
    /// Paginated scrollback with metadata
    case scrollbackPage(meta: ScrollbackPageMeta, data: Data)
    /// Page of scrollback history
    case historyPage(meta: HistoryPageMeta, data: Data)
    /// Shell is idle (waiting for input, no PTY output for 2s)
    case idle
    /// Protocol handshake
    case handshake(Handshake)
    /// The PTY's size and whether it's this client's
    case ptySize(PtySize)
    /// The screen is ready to show after an attach. `notDrawing`: the program on the
    /// alternate screen didn't draw when asked (its name, possibly empty), so the screen
    /// stays blank until it does; nil when it drew.
    case ready(notDrawing: String?)
}

/// Frame parser state machine for rtach server responses
///
/// Server sends framed responses: [type: 1][len: 4 LE][payload: len bytes]
public final class PacketReader {

    /// Parser state
    public enum State: Sendable, Equatable {
        case waitingForHeader
        case waitingForPayload(type: ResponseType, remaining: Int, compressed: Bool)
    }

    private var _state: State = .waitingForHeader
    private var _buffer = Data()

    /// Longest payload rtach sends: a whole scrollback buffer (1MB by default, `-s` sets
    /// it). A longer one is a misread header.
    public static let maxPayloadLength = 64 * 1024 * 1024

    /// The stream lost its place: a header with an unknown type or an impossible length,
    /// so bytes went missing or arrived out of order. Nothing after it can be trusted
    /// (before this was noticed, a misread length waited forever for data that never came
    /// and the pane showed nothing more); the owner should attach again.
    public private(set) var lostSync = false

    public init() {}

    /// Current parser state (for debugging/testing)
    public var currentState: State {
        _state
    }

    /// Buffered data count (for debugging/testing)
    public var bufferedCount: Int {
        _buffer.count
    }

    /// Reset parser state (e.g., on reconnect)
    public func reset() {
        _state = .waitingForHeader
        _buffer.removeAll(keepingCapacity: true)
        lostSync = false
    }

    /// Process incoming data and return any complete responses
    /// - Parameter data: New data from server
    /// - Returns: Array of parsed responses (may be empty if waiting for more data)
    public func process(_ data: Data) -> [RtachResponse] {
        guard !lostSync else { return [] }
        _buffer.append(data)
        var responses: [RtachResponse] = []

        while true {
            switch _state {
            case .waitingForHeader:
                guard _buffer.count >= ProtocolConstants.responseHeaderSize else {
                    return responses
                }

                // Use startIndex for proper access after removeFirst operations
                let start = _buffer.startIndex

                // Parse header: [type: 1][len: 4 LE]
                // High bit (0x80) indicates zlib compression
                let typeRaw = _buffer[start]
                let isCompressed = (typeRaw & ProtocolConstants.compressionFlag) != 0
                let actualType = typeRaw & ~ProtocolConstants.compressionFlag

                guard let responseType = ResponseType(rawValue: actualType) else {
                    os_log(.error, log: decompressionLog, "lost sync: unknown response type %d", typeRaw)
                    lostSync = true
                    _buffer.removeAll()
                    return responses
                }

                // Use manual byte loading to avoid alignment issues
                let len = UInt32(_buffer[start + 1]) |
                         (UInt32(_buffer[start + 2]) << 8) |
                         (UInt32(_buffer[start + 3]) << 16) |
                         (UInt32(_buffer[start + 4]) << 24)

                guard len <= Self.maxPayloadLength else {
                    os_log(.error, log: decompressionLog, "lost sync: %u-byte payload", len)
                    lostSync = true
                    _buffer.removeAll()
                    return responses
                }

                // Remove header from buffer (use dropFirst to reset indices)
                _buffer = Data(_buffer.dropFirst(ProtocolConstants.responseHeaderSize))

                if len == 0 {
                    // Empty payload - handle immediately
                    if let response = buildResponse(type: responseType, payload: Data()) {
                        responses.append(response)
                    }
                    // Stay in waitingForHeader state
                } else {
                    _state = .waitingForPayload(type: responseType, remaining: Int(len), compressed: isCompressed)
                }

            case .waitingForPayload(let responseType, let remaining, let isCompressed):
                guard _buffer.count >= remaining else {
                    return responses
                }

                // Extract payload
                var payload = Data(_buffer.prefix(remaining))
                _buffer = Data(_buffer.dropFirst(remaining))

                // Decompress if needed
                if isCompressed {
                    if let decompressed = decompress(payload) {
                        payload = decompressed
                    } else {
                        // Decompression failed - skip this packet
                        _state = .waitingForHeader
                        continue
                    }
                }

                if let response = buildResponse(type: responseType, payload: payload) {
                    responses.append(response)
                }

                _state = .waitingForHeader
            }
        }
    }

    /// Decompress zlib-compressed data. The output buffer grows until it holds it all: a
    /// fixed 8x cut short very compressible output (a repaint of mostly spaces).
    private func decompress(_ data: Data) -> Data? {
        // Use ZLIB algorithm (includes header)
        let algorithm = COMPRESSION_ZLIB
        var capacity = max(data.count * 8, 32768)

        while true {
            var outputBuffer = Data(count: capacity)
            let decompressedSize = outputBuffer.withUnsafeMutableBytes { outputPtr -> Int in
                data.withUnsafeBytes { inputPtr -> Int in
                    guard let input = inputPtr.baseAddress,
                          let output = outputPtr.baseAddress else {
                        os_log(.error, log: decompressionLog, "Failed to get buffer pointers")
                        return 0
                    }
                    return compression_decode_buffer(
                        output.assumingMemoryBound(to: UInt8.self),
                        capacity,
                        input.assumingMemoryBound(to: UInt8.self),
                        data.count,
                        nil,
                        algorithm
                    )
                }
            }

            guard decompressedSize > 0 else {
                os_log(.error, log: decompressionLog, "FAILED: decompressedSize=%d", decompressedSize)
                return nil
            }
            // A full buffer may have cut it short: again with more room
            if decompressedSize == capacity, capacity < Self.maxPayloadLength * 4 {
                capacity *= 4
                continue
            }
            outputBuffer.count = decompressedSize
            return outputBuffer
        }
    }

    /// Build response from type and payload
    private func buildResponse(type: ResponseType, payload: Data) -> RtachResponse? {
        switch type {
        case .terminalData:
            return .terminalData(payload)

        case .scrollback:
            return .scrollback(payload)

        case .command:
            return .command(payload)

        case .scrollbackPage:
            // Payload format: [meta: 8 bytes][data: rest]
            guard payload.count >= ProtocolConstants.scrollbackMetaSize else {
                return nil
            }
            guard let meta = ScrollbackPageMeta(from: payload) else {
                return nil
            }
            let data = payload.dropFirst(ProtocolConstants.scrollbackMetaSize)
            return .scrollbackPage(meta: meta, data: Data(data))

        case .historyPage:
            // Payload format: [meta: 24 bytes][data: rest]
            guard let meta = HistoryPageMeta(from: payload) else {
                return nil
            }
            let data = payload.dropFirst(ProtocolConstants.historyMetaSize)
            return .historyPage(meta: meta, data: Data(data))

        case .idle:
            // Idle notification (no payload)
            return .idle

        case .handshake:
            guard let handshake = Handshake(from: payload) else {
                return nil
            }
            return .handshake(handshake)

        case .ptySize:
            guard let size = PtySize(from: payload) else {
                return nil
            }
            return .ptySize(size)

        case .ready:
            guard let flags = payload.first, flags & ProtocolConstants.readyFlagNoRedraw != 0 else {
                return .ready(notDrawing: nil)
            }
            return .ready(notDrawing: String(decoding: payload.dropFirst(), as: UTF8.self))
        }
    }
}

// MARK: - Convenience Extensions

extension PacketReader {
    /// Process a single byte (useful for testing)
    public func process(_ byte: UInt8) -> [RtachResponse] {
        process(Data([byte]))
    }

    /// Check if we're waiting for more data
    public var isWaitingForMoreData: Bool {
        switch currentState {
        case .waitingForHeader:
            return bufferedCount < ProtocolConstants.responseHeaderSize
        case .waitingForPayload(_, let remaining, _):
            return bufferedCount < remaining
        }
    }
}
