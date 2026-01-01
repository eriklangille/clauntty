import XCTest
@testable import RtachClient

final class PacketWriterTests: XCTestCase {

    // MARK: - Push Packet Tests

    func testPushSingleByte() {
        let data = Data([0x41]) // 'A'
        let packet = PacketWriter.push(data)

        XCTAssertEqual(packet.count, 3)
        XCTAssertEqual(packet[0], MessageType.push.rawValue) // type = 0
        XCTAssertEqual(packet[1], 1) // len = 1
        XCTAssertEqual(packet[2], 0x41) // payload = 'A'
    }

    func testPushMultipleBytes() {
        let data = Data([0x68, 0x65, 0x6C, 0x6C, 0x6F]) // "hello"
        let packet = PacketWriter.push(data)

        XCTAssertEqual(packet.count, 7)
        XCTAssertEqual(packet[0], 0) // type = push
        XCTAssertEqual(packet[1], 5) // len = 5
        XCTAssertEqual(Array(packet[2...]), [0x68, 0x65, 0x6C, 0x6C, 0x6F])
    }

    func testPushMaxSize() {
        let data = Data(repeating: 0x58, count: 255) // 255 'X's
        let packet = PacketWriter.push(data)

        XCTAssertEqual(packet.count, 257) // 2 header + 255 payload
        XCTAssertEqual(packet[0], 0)
        XCTAssertEqual(packet[1], 255)
    }

    func testPushTruncatesLargeData() {
        let data = Data(repeating: 0x58, count: 300)
        let packet = PacketWriter.push(data)

        // Should truncate to 255 bytes
        XCTAssertEqual(packet.count, 257)
        XCTAssertEqual(packet[1], 255)
    }

    func testPushEmpty() {
        let packet = PacketWriter.push(Data())

        XCTAssertEqual(packet.count, 2)
        XCTAssertEqual(packet[0], 0)
        XCTAssertEqual(packet[1], 0)
    }

    // MARK: - Push Chunked Tests

    func testPushChunkedSmallData() {
        let data = Data([0x41, 0x42, 0x43])
        let packets = PacketWriter.pushChunked(data)

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0], PacketWriter.push(data))
    }

    func testPushChunkedLargeData() {
        let data = Data(repeating: 0x58, count: 300)
        let packets = PacketWriter.pushChunked(data)

        XCTAssertEqual(packets.count, 2)

        // First packet: 255 bytes
        XCTAssertEqual(packets[0][1], 255)

        // Second packet: 45 bytes (300 - 255)
        XCTAssertEqual(packets[1][1], 45)
    }

    func testPushChunkedEmpty() {
        let packets = PacketWriter.pushChunked(Data())
        XCTAssertTrue(packets.isEmpty)
    }

    func testPushChunkedExactBoundary() {
        let data = Data(repeating: 0x58, count: 510)
        let packets = PacketWriter.pushChunked(data)

        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0][1], 255)
        XCTAssertEqual(packets[1][1], 255)
    }

    // MARK: - Upgrade Packet Tests

    func testUpgrade() {
        let packet = PacketWriter.upgrade()

        // Upgrade packet requests compression: [type=7][len=1][compression_type=1]
        XCTAssertEqual(packet.count, 3)
        XCTAssertEqual(packet[0], MessageType.upgrade.rawValue) // type = 7
        XCTAssertEqual(packet[1], 1) // len = 1 (payload has compression type)
        XCTAssertEqual(packet[2], ProtocolConstants.compressionZlib) // compression = zlib (0x01)
    }

    // MARK: - Attach/Detach Tests

    func testAttachWithoutClientId() {
        let packet = PacketWriter.attach()

        XCTAssertEqual(packet.count, 2)
        XCTAssertEqual(packet[0], MessageType.attach.rawValue) // type = 1
        XCTAssertEqual(packet[1], 0) // len = 0
    }

    func testAttachWithClientId() {
        let clientId = Data(repeating: 0xAB, count: 16)
        let packet = PacketWriter.attach(clientId: clientId)

        XCTAssertEqual(packet.count, 18) // 2 header + 16 client ID
        XCTAssertEqual(packet[0], 1) // type = attach
        XCTAssertEqual(packet[1], 16) // len = 16
        XCTAssertEqual(Array(packet[2...]), Array(clientId))
    }

    func testAttachWithInvalidClientId() {
        let shortId = Data(repeating: 0xAB, count: 8)
        let packet = PacketWriter.attach(clientId: shortId)

        // Should ignore invalid-length client ID
        XCTAssertEqual(packet.count, 2)
        XCTAssertEqual(packet[1], 0)
    }

    func testDetach() {
        let packet = PacketWriter.detach()

        XCTAssertEqual(packet.count, 2)
        XCTAssertEqual(packet[0], MessageType.detach.rawValue) // type = 2
        XCTAssertEqual(packet[1], 0)
    }

    // MARK: - Redraw Tests

    func testRedraw() {
        let packet = PacketWriter.redraw()

        XCTAssertEqual(packet.count, 2)
        XCTAssertEqual(packet[0], MessageType.redraw.rawValue) // type = 4
        XCTAssertEqual(packet[1], 0)
    }

    // MARK: - Winch Tests

    func testWinch() {
        let size = WindowSize(rows: 24, cols: 80, xpixel: 800, ypixel: 600)
        let packet = PacketWriter.winch(size)

        XCTAssertEqual(packet.count, 10) // 2 header + 8 payload
        XCTAssertEqual(packet[0], MessageType.winch.rawValue) // type = 3
        XCTAssertEqual(packet[1], 8) // len = 8

        // Verify little-endian encoding
        let rows = UInt16(packet[2]) | (UInt16(packet[3]) << 8)
        let cols = UInt16(packet[4]) | (UInt16(packet[5]) << 8)
        let xpixel = UInt16(packet[6]) | (UInt16(packet[7]) << 8)
        let ypixel = UInt16(packet[8]) | (UInt16(packet[9]) << 8)

        XCTAssertEqual(rows, 24)
        XCTAssertEqual(cols, 80)
        XCTAssertEqual(xpixel, 800)
        XCTAssertEqual(ypixel, 600)
    }

    // MARK: - Scrollback Request Tests

    func testScrollbackPageRequest() {
        let packet = PacketWriter.scrollbackPageRequest(offset: 0, limit: 16384)

        XCTAssertEqual(packet.count, 10) // 2 header + 8 payload
        XCTAssertEqual(packet[0], MessageType.requestScrollbackPage.rawValue) // type = 6
        XCTAssertEqual(packet[1], 8) // len = 8

        // Verify offset = 0 (little-endian)
        XCTAssertEqual(packet[2], 0)
        XCTAssertEqual(packet[3], 0)
        XCTAssertEqual(packet[4], 0)
        XCTAssertEqual(packet[5], 0)

        // Verify limit = 16384 = 0x4000 (little-endian)
        XCTAssertEqual(packet[6], 0x00)
        XCTAssertEqual(packet[7], 0x40)
        XCTAssertEqual(packet[8], 0x00)
        XCTAssertEqual(packet[9], 0x00)
    }

    func testScrollbackRequest() {
        let packet = PacketWriter.scrollbackRequest()

        XCTAssertEqual(packet.count, 2)
        XCTAssertEqual(packet[0], MessageType.requestScrollback.rawValue) // type = 5
        XCTAssertEqual(packet[1], 0)
    }

    // MARK: - Pause/Resume Tests

    func testPause() {
        let packet = PacketWriter.pause()

        XCTAssertEqual(packet.count, 2)
        XCTAssertEqual(packet[0], MessageType.pause.rawValue) // type = 8
        XCTAssertEqual(packet[1], 0) // len = 0
    }

    func testResume() {
        let packet = PacketWriter.resume()

        XCTAssertEqual(packet.count, 2)
        XCTAssertEqual(packet[0], MessageType.resume.rawValue) // type = 9
        XCTAssertEqual(packet[1], 0) // len = 0
    }
}
