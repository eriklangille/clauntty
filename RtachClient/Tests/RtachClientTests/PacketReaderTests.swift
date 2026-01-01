import XCTest
import Compression
@testable import RtachClient

final class PacketReaderTests: XCTestCase {

    var reader: PacketReader!

    override func setUp() {
        super.setUp()
        reader = PacketReader()
    }

    override func tearDown() {
        reader = nil
        super.tearDown()
    }

    // MARK: - Helper

    func makeFrame(type: ResponseType, payload: Data) -> Data {
        var frame = Data(capacity: 5 + payload.count)
        frame.append(type.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    func makeHandshake(versionMajor: UInt8 = 2, versionMinor: UInt8 = 0) -> Data {
        var payload = Data()
        // Magic "RTCH" = 0x48435452
        withUnsafeBytes(of: ProtocolConstants.handshakeMagic.littleEndian) { payload.append(contentsOf: $0) }
        payload.append(versionMajor)
        payload.append(versionMinor)
        payload.append(contentsOf: [0, 0]) // flags
        return makeFrame(type: .handshake, payload: payload)
    }

    // MARK: - Basic Parsing

    func testEmptyData() {
        let responses = reader.process(Data())
        XCTAssertTrue(responses.isEmpty)
    }

    func testPartialHeader() {
        // Less than 5 bytes - should wait for more
        let responses = reader.process(Data([0, 5, 0]))
        XCTAssertTrue(responses.isEmpty)
        XCTAssertEqual(reader.bufferedCount, 3)
    }

    func testCompleteTerminalDataFrame() {
        let payload = Data([0x68, 0x65, 0x6C, 0x6C, 0x6F]) // "hello"
        let frame = makeFrame(type: .terminalData, payload: payload)

        let responses = reader.process(frame)

        XCTAssertEqual(responses.count, 1)
        if case .terminalData(let data) = responses[0] {
            XCTAssertEqual(data, payload)
        } else {
            XCTFail("Expected terminalData response")
        }
    }

    func testEmptyPayload() {
        let frame = makeFrame(type: .terminalData, payload: Data())
        let responses = reader.process(frame)

        XCTAssertEqual(responses.count, 1)
        if case .terminalData(let data) = responses[0] {
            XCTAssertTrue(data.isEmpty)
        } else {
            XCTFail("Expected terminalData response")
        }
    }

    // MARK: - Partial Frame Handling

    func testHeaderThenPayload() {
        let payload = Data([0x41, 0x42, 0x43])

        // Send header first
        var header = Data()
        header.append(ResponseType.terminalData.rawValue)
        withUnsafeBytes(of: UInt32(3).littleEndian) { header.append(contentsOf: $0) }

        var responses = reader.process(header)
        XCTAssertTrue(responses.isEmpty) // Waiting for payload

        // Send payload
        responses = reader.process(payload)
        XCTAssertEqual(responses.count, 1)

        if case .terminalData(let data) = responses[0] {
            XCTAssertEqual(data, payload)
        } else {
            XCTFail("Expected terminalData response")
        }
    }

    func testByteByByte() {
        let payload = Data([0x58, 0x59])
        let frame = makeFrame(type: .terminalData, payload: payload)

        var responses: [RtachResponse] = []
        for byte in frame {
            responses.append(contentsOf: reader.process(byte))
        }

        XCTAssertEqual(responses.count, 1)
        if case .terminalData(let data) = responses[0] {
            XCTAssertEqual(data, payload)
        } else {
            XCTFail("Expected terminalData response")
        }
    }

    // MARK: - Multiple Frames

    func testMultipleFramesAtOnce() {
        let frame1 = makeFrame(type: .terminalData, payload: Data([0x41]))
        let frame2 = makeFrame(type: .terminalData, payload: Data([0x42]))

        var combined = Data()
        combined.append(frame1)
        combined.append(frame2)

        let responses = reader.process(combined)

        XCTAssertEqual(responses.count, 2)

        if case .terminalData(let data) = responses[0] {
            XCTAssertEqual(data, Data([0x41]))
        } else {
            XCTFail("Expected terminalData for first response")
        }

        if case .terminalData(let data) = responses[1] {
            XCTAssertEqual(data, Data([0x42]))
        } else {
            XCTFail("Expected terminalData for second response")
        }
    }

    func testFrameSpansMultipleChunks() {
        let payload = Data(repeating: 0x58, count: 100)
        let frame = makeFrame(type: .terminalData, payload: payload)

        // Split in the middle of payload
        let chunk1 = frame.prefix(50)
        let chunk2 = frame.dropFirst(50)

        var responses = reader.process(Data(chunk1))
        XCTAssertTrue(responses.isEmpty)

        responses = reader.process(Data(chunk2))
        XCTAssertEqual(responses.count, 1)

        if case .terminalData(let data) = responses[0] {
            XCTAssertEqual(data, payload)
        } else {
            XCTFail("Expected terminalData response")
        }
    }

    // MARK: - Response Types

    func testHandshakeResponse() {
        let frame = makeHandshake(versionMajor: 2, versionMinor: 1)
        let responses = reader.process(frame)

        XCTAssertEqual(responses.count, 1)
        if case .handshake(let h) = responses[0] {
            XCTAssertTrue(h.isValid)
            XCTAssertEqual(h.versionMajor, 2)
            XCTAssertEqual(h.versionMinor, 1)
        } else {
            XCTFail("Expected handshake response")
        }
    }

    func testScrollbackResponse() {
        let payload = Data([0x1B, 0x5B, 0x48]) // ESC[H
        let frame = makeFrame(type: .scrollback, payload: payload)

        let responses = reader.process(frame)

        XCTAssertEqual(responses.count, 1)
        if case .scrollback(let data) = responses[0] {
            XCTAssertEqual(data, payload)
        } else {
            XCTFail("Expected scrollback response")
        }
    }

    func testCommandResponse() {
        let payload = Data("reload".utf8)
        let frame = makeFrame(type: .command, payload: payload)

        let responses = reader.process(frame)

        XCTAssertEqual(responses.count, 1)
        if case .command(let data) = responses[0] {
            XCTAssertEqual(String(data: data, encoding: .utf8), "reload")
        } else {
            XCTFail("Expected command response")
        }
    }

    func testScrollbackPageResponse() {
        // Meta: totalLength=1000, offset=500
        var meta = Data()
        withUnsafeBytes(of: UInt32(1000).littleEndian) { meta.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(500).littleEndian) { meta.append(contentsOf: $0) }

        // Data
        let scrollData = Data([0x41, 0x42, 0x43])

        var payload = meta
        payload.append(scrollData)

        let frame = makeFrame(type: .scrollbackPage, payload: payload)
        let responses = reader.process(frame)

        XCTAssertEqual(responses.count, 1)
        if case .scrollbackPage(let m, let data) = responses[0] {
            XCTAssertEqual(m.totalLength, 1000)
            XCTAssertEqual(m.offset, 500)
            XCTAssertEqual(data, scrollData)
        } else {
            XCTFail("Expected scrollbackPage response")
        }
    }

    func testIdleResponse() {
        // Idle notification has no payload
        let frame = makeFrame(type: .idle, payload: Data())
        let responses = reader.process(frame)

        XCTAssertEqual(responses.count, 1)
        if case .idle = responses[0] {
            // Success - idle response parsed correctly
        } else {
            XCTFail("Expected idle response")
        }
    }

    // MARK: - Reset

    func testReset() {
        // Send partial header (only 3 bytes, need 5)
        _ = reader.process(Data([0, 5, 0]))
        XCTAssertEqual(reader.bufferedCount, 3)

        reader.reset()

        XCTAssertEqual(reader.bufferedCount, 0)
        XCTAssertEqual(reader.currentState, .waitingForHeader)
    }

    // MARK: - Unknown Type Handling

    func testUnknownTypeSkipsBytes() {
        // Unknown type 99, then valid frame
        var data = Data([99]) // Unknown type
        let validFrame = makeFrame(type: .terminalData, payload: Data([0x58]))
        data.append(validFrame)

        let responses = reader.process(data)

        // Should skip unknown byte and find valid frame
        XCTAssertEqual(responses.count, 1)
        if case .terminalData(let payload) = responses[0] {
            XCTAssertEqual(payload, Data([0x58]))
        } else {
            XCTFail("Expected terminalData response")
        }
    }

    // MARK: - Large Frame

    func testLargeFrame() {
        let payload = Data(repeating: 0x58, count: 65536)
        let frame = makeFrame(type: .terminalData, payload: payload)

        let responses = reader.process(frame)

        XCTAssertEqual(responses.count, 1)
        if case .terminalData(let data) = responses[0] {
            XCTAssertEqual(data.count, 65536)
        } else {
            XCTFail("Expected terminalData response")
        }
    }

    // MARK: - Compression Tests

    /// Compress data using raw deflate (RFC 1951) - same format rtach uses
    func compressRawDeflate(_ input: Data) -> Data? {
        let maxOutputSize = input.count + 64
        var output = Data(count: maxOutputSize)

        let compressedSize = output.withUnsafeMutableBytes { outputPtr -> Int in
            input.withUnsafeBytes { inputPtr -> Int in
                guard let src = inputPtr.baseAddress,
                      let dst = outputPtr.baseAddress else { return 0 }
                return compression_encode_buffer(
                    dst.assumingMemoryBound(to: UInt8.self),
                    maxOutputSize,
                    src.assumingMemoryBound(to: UInt8.self),
                    input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard compressedSize > 0 else { return nil }
        output.count = compressedSize
        return output
    }

    /// Make a compressed frame (type byte has 0x80 flag set)
    func makeCompressedFrame(type: ResponseType, uncompressedPayload: Data) -> Data? {
        guard let compressed = compressRawDeflate(uncompressedPayload) else { return nil }

        var frame = Data(capacity: 5 + compressed.count)
        // Type byte with compression flag (0x80)
        frame.append(type.rawValue | ProtocolConstants.compressionFlag)
        withUnsafeBytes(of: UInt32(compressed.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(compressed)
        return frame
    }

    func testCompressedTerminalData() {
        // Create repetitive data that compresses well
        let originalPayload = Data(repeating: 0x41, count: 200) // "AAAA..."

        guard let frame = makeCompressedFrame(type: .terminalData, uncompressedPayload: originalPayload) else {
            XCTFail("Failed to create compressed frame")
            return
        }

        let responses = reader.process(frame)

        XCTAssertEqual(responses.count, 1)
        if case .terminalData(let data) = responses[0] {
            XCTAssertEqual(data, originalPayload)
        } else {
            XCTFail("Expected terminalData response")
        }
    }

    func testCompressedTerminalDataWithAnsiEscapes() {
        // Realistic terminal output with ANSI escapes
        let terminalOutput = Data("""
            \u{1B}[0m\u{1B}[32muser@host\u{1B}[0m:\u{1B}[34m~/projects\u{1B}[0m$ ls -la\r
            total 48\r
            drwxr-xr-x  12 user user 4096 Jan  1 12:00 .\r
            drwxr-xr-x   5 user user 4096 Jan  1 12:00 ..\r
            -rw-r--r--   1 user user  220 Jan  1 12:00 .bashrc\r
            -rw-r--r--   1 user user  807 Jan  1 12:00 .profile\r
            """.utf8)

        guard let frame = makeCompressedFrame(type: .terminalData, uncompressedPayload: terminalOutput) else {
            XCTFail("Failed to create compressed frame")
            return
        }

        let responses = reader.process(frame)

        XCTAssertEqual(responses.count, 1)
        if case .terminalData(let data) = responses[0] {
            XCTAssertEqual(data, terminalOutput)
        } else {
            XCTFail("Expected terminalData response")
        }
    }

    func testCompressionFlagDetection() {
        // Uncompressed frame (type = 0x00)
        let uncompressedFrame = makeFrame(type: .terminalData, payload: Data([0x41, 0x42]))
        XCTAssertEqual(uncompressedFrame[0], 0x00) // No compression flag

        // Compressed frame (type = 0x80)
        let compressedPayload = Data(repeating: 0x58, count: 100)
        guard let compressedFrame = makeCompressedFrame(type: .terminalData, uncompressedPayload: compressedPayload) else {
            XCTFail("Failed to create compressed frame")
            return
        }
        XCTAssertEqual(compressedFrame[0], 0x80) // Has compression flag
    }

    func testCompressedScrollback() {
        let scrollbackData = Data(repeating: 0x20, count: 500) // Spaces

        guard let frame = makeCompressedFrame(type: .scrollback, uncompressedPayload: scrollbackData) else {
            XCTFail("Failed to create compressed frame")
            return
        }

        // Type should be scrollback (0x01) | compression (0x80) = 0x81
        XCTAssertEqual(frame[0], 0x81)

        let responses = reader.process(frame)

        XCTAssertEqual(responses.count, 1)
        if case .scrollback(let data) = responses[0] {
            XCTAssertEqual(data, scrollbackData)
        } else {
            XCTFail("Expected scrollback response")
        }
    }

    func testMixedCompressedAndUncompressed() {
        // First frame: uncompressed
        let frame1 = makeFrame(type: .terminalData, payload: Data([0x41]))

        // Second frame: compressed
        let largePayload = Data(repeating: 0x42, count: 200)
        guard let frame2 = makeCompressedFrame(type: .terminalData, uncompressedPayload: largePayload) else {
            XCTFail("Failed to create compressed frame")
            return
        }

        // Third frame: uncompressed
        let frame3 = makeFrame(type: .terminalData, payload: Data([0x43]))

        var combined = Data()
        combined.append(frame1)
        combined.append(frame2)
        combined.append(frame3)

        let responses = reader.process(combined)

        XCTAssertEqual(responses.count, 3)

        if case .terminalData(let data) = responses[0] {
            XCTAssertEqual(data, Data([0x41]))
        } else {
            XCTFail("Expected first frame")
        }

        if case .terminalData(let data) = responses[1] {
            XCTAssertEqual(data, largePayload)
        } else {
            XCTFail("Expected second (compressed) frame")
        }

        if case .terminalData(let data) = responses[2] {
            XCTAssertEqual(data, Data([0x43]))
        } else {
            XCTFail("Expected third frame")
        }
    }
}
