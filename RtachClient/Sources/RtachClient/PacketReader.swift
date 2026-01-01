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
    /// Shell is idle (waiting for input, no PTY output for 2s)
    case idle
    /// Protocol handshake
    case handshake(Handshake)
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
    }

    /// Process incoming data and return any complete responses
    /// - Parameter data: New data from server
    /// - Returns: Array of parsed responses (may be empty if waiting for more data)
    public func process(_ data: Data) -> [RtachResponse] {
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
                    // Unknown type - skip this byte and try again
                    _buffer = Data(_buffer.dropFirst())
                    continue
                }

                // Use manual byte loading to avoid alignment issues
                let len = UInt32(_buffer[start + 1]) |
                         (UInt32(_buffer[start + 2]) << 8) |
                         (UInt32(_buffer[start + 3]) << 16) |
                         (UInt32(_buffer[start + 4]) << 24)

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

    /// Decompress zlib-compressed data
    private func decompress(_ data: Data) -> Data? {
        // Use ZLIB algorithm (includes header)
        let algorithm = COMPRESSION_ZLIB

        // Allocate output buffer - start with 4x input size, expand if needed
        let maxOutputSize = max(data.count * 8, 32768)
        var outputBuffer = Data(count: maxOutputSize)

        let decompressedSize = outputBuffer.withUnsafeMutableBytes { outputPtr -> Int in
            data.withUnsafeBytes { inputPtr -> Int in
                guard let input = inputPtr.baseAddress,
                      let output = outputPtr.baseAddress else {
                    os_log(.error, log: decompressionLog, "Failed to get buffer pointers")
                    return 0
                }
                let result = compression_decode_buffer(
                    output.assumingMemoryBound(to: UInt8.self),
                    maxOutputSize,
                    input.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    algorithm
                )
                os_log(.info, log: decompressionLog, "input=%d bytes, output=%d bytes", data.count, result)
                return result
            }
        }

        guard decompressedSize > 0 else {
            os_log(.error, log: decompressionLog, "FAILED: decompressedSize=%d", decompressedSize)
            return nil
        }

        outputBuffer.count = decompressedSize
        return outputBuffer
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

        case .idle:
            // Idle notification (no payload)
            return .idle

        case .handshake:
            guard let handshake = Handshake(from: payload) else {
                return nil
            }
            return .handshake(handshake)
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
