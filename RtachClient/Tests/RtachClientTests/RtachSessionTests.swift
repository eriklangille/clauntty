import XCTest
@testable import RtachClient

final class RtachSessionTests: XCTestCase {

    var session: RtachSession!
    var delegate: MockDelegate!

    override func setUp() {
        super.setUp()
        session = RtachSession()
        delegate = MockDelegate()
        session.delegate = delegate
    }

    override func tearDown() {
        session = nil
        delegate = nil
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
        withUnsafeBytes(of: ProtocolConstants.handshakeMagic.littleEndian) { payload.append(contentsOf: $0) }
        payload.append(versionMajor)
        payload.append(versionMinor)
        payload.append(contentsOf: [0, 0]) // flags
        return makeFrame(type: .handshake, payload: payload)
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertEqual(session.state, .disconnected)
        XCTAssertFalse(session.isFramedMode)
        XCTAssertFalse(session.isRtachRunning)
        XCTAssertNil(session.protocolVersion)
    }

    func testConnect() {
        session.connect()

        XCTAssertEqual(session.state, .rawMode)
        XCTAssertFalse(session.isFramedMode)
    }

    func testReset() {
        session.connect()
        session.processIncomingData(makeHandshake())

        XCTAssertTrue(session.isFramedMode)

        session.reset()

        XCTAssertEqual(session.state, .disconnected)
        XCTAssertFalse(session.isFramedMode)
        XCTAssertNil(session.handshake)
    }

    // MARK: - Handshake Handling

    func testHandshakeTriggersUpgrade() {
        session.connect()
        session.processIncomingData(makeHandshake(versionMajor: 2, versionMinor: 1))

        // Should be in framed mode
        XCTAssertEqual(session.state, .framedMode(version: "2.1"))
        XCTAssertTrue(session.isFramedMode)
        XCTAssertTrue(session.isRtachRunning)
        XCTAssertEqual(session.protocolVersion, "2.1")

        // Should have sent upgrade packet
        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData[0], PacketWriter.upgrade())
    }

    func testInvalidHandshakeStaysRaw() {
        session.connect()

        // Invalid magic
        var payload = Data()
        withUnsafeBytes(of: UInt32(0x12345678).littleEndian) { payload.append(contentsOf: $0) }
        payload.append(contentsOf: [2, 0, 0, 0])
        let frame = makeFrame(type: .handshake, payload: payload)

        session.processIncomingData(frame)

        XCTAssertEqual(session.state, .rawMode)
        XCTAssertFalse(session.isFramedMode)
        XCTAssertFalse(session.isRtachRunning)
        XCTAssertTrue(delegate.sentData.isEmpty) // No upgrade sent
    }

    // MARK: - Keyboard Input

    func testSendKeyboardInRawMode() {
        session.connect()
        session.sendKeyboardInput(Data("hello".utf8))

        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData[0], Data("hello".utf8))
    }

    func testSendKeyboardInFramedMode() {
        session.connect()
        session.processIncomingData(makeHandshake())
        delegate.sentData.removeAll() // Clear upgrade packet

        session.sendKeyboardInput(Data("hello".utf8))

        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData[0], PacketWriter.push(Data("hello".utf8)))
    }

    func testSendKeyboardChunkedInFramedMode() {
        session.connect()
        session.processIncomingData(makeHandshake())
        delegate.sentData.removeAll()

        // Large input that needs chunking
        let largeInput = Data(repeating: 0x58, count: 300)
        session.sendKeyboardInput(largeInput)

        // Session combines multiple packets into one atomic write
        XCTAssertEqual(delegate.sentData.count, 1)
        let combined = delegate.sentData[0]
        // First packet: [type=0][len=255][255 bytes] = 257 bytes
        // Second packet: [type=0][len=45][45 bytes] = 47 bytes
        XCTAssertEqual(combined.count, 257 + 47) // Total 304 bytes
        XCTAssertEqual(combined[1], 255) // First chunk len
        XCTAssertEqual(combined[257 + 1], 45) // Second chunk len (after first packet)
    }

    func testSendKeyboardWhenDisconnected() {
        session.sendKeyboardInput(Data("hello".utf8))

        XCTAssertTrue(delegate.sentData.isEmpty)
    }

    func testSendEmptyKeyboardInput() {
        session.connect()
        session.sendKeyboardInput(Data())

        XCTAssertTrue(delegate.sentData.isEmpty)
    }

    // MARK: - Control Packets (Framed Mode Only)

    func testSendWindowSize() {
        session.connect()
        session.processIncomingData(makeHandshake())
        delegate.sentData.removeAll()

        let size = WindowSize(rows: 24, cols: 80)
        session.sendWindowSize(size)

        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData[0], PacketWriter.winch(size))
    }

    func testSendWindowSizeInRawModeIgnored() {
        session.connect()
        session.sendWindowSize(WindowSize(rows: 24, cols: 80))

        XCTAssertTrue(delegate.sentData.isEmpty)
    }

    func testRequestScrollbackPage() {
        session.connect()
        session.processIncomingData(makeHandshake())
        delegate.sentData.removeAll()

        session.requestScrollbackPage(offset: 100, limit: 1000)

        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData[0], PacketWriter.scrollbackPageRequest(offset: 100, limit: 1000))
    }

    func testRequestScrollbackPageInRawModeIgnored() {
        session.connect()
        session.requestScrollbackPage(offset: 0, limit: 16384)

        XCTAssertTrue(delegate.sentData.isEmpty)
    }

    func testRequestRedraw() {
        session.connect()
        session.processIncomingData(makeHandshake())
        delegate.sentData.removeAll()

        session.requestRedraw()

        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData[0], PacketWriter.redraw())
    }

    func testSendAttach() {
        session.connect()
        session.processIncomingData(makeHandshake())
        delegate.sentData.removeAll()

        let clientId = Data(repeating: 0xAB, count: 16)
        session.sendAttach(clientId: clientId)

        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData[0], PacketWriter.attach(clientId: clientId))
    }

    func testSendDetach() {
        session.connect()
        session.processIncomingData(makeHandshake())
        delegate.sentData.removeAll()

        session.sendDetach()

        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData[0], PacketWriter.detach())
    }

    // MARK: - Pause/Resume Tests

    func testSendPause() {
        session.connect()
        session.processIncomingData(makeHandshake())
        delegate.sentData.removeAll()

        session.sendPause()

        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData[0], PacketWriter.pause())
    }

    func testSendResume() {
        session.connect()
        session.processIncomingData(makeHandshake())
        delegate.sentData.removeAll()

        session.sendResume()

        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData[0], PacketWriter.resume())
    }

    func testPauseIgnoredInRawMode() {
        session.connect()
        // Don't send handshake - stay in raw mode
        delegate.sentData.removeAll()

        session.sendPause()

        // Should not send pause packet in raw mode
        XCTAssertTrue(delegate.sentData.isEmpty)
    }

    func testResumeIgnoredInRawMode() {
        session.connect()
        // Don't send handshake - stay in raw mode
        delegate.sentData.removeAll()

        session.sendResume()

        // Should not send resume packet in raw mode
        XCTAssertTrue(delegate.sentData.isEmpty)
    }

    // MARK: - Incoming Data Handling

    func testTerminalDataForwardedToDelegate() {
        session.connect()
        session.processIncomingData(makeHandshake())

        let termData = Data([0x1B, 0x5B, 0x48]) // ESC[H
        session.processIncomingData(makeFrame(type: .terminalData, payload: termData))

        XCTAssertEqual(delegate.terminalData.count, 1)
        XCTAssertEqual(delegate.terminalData[0], termData)
    }

    func testScrollbackForwardedToDelegate() {
        session.connect()
        session.processIncomingData(makeHandshake())

        let scrollData = Data("scrollback content".utf8)
        session.processIncomingData(makeFrame(type: .scrollback, payload: scrollData))

        XCTAssertEqual(delegate.scrollbackData.count, 1)
        XCTAssertEqual(delegate.scrollbackData[0], scrollData)
    }

    func testScrollbackPageForwardedToDelegate() {
        session.connect()
        session.processIncomingData(makeHandshake())

        // Meta + data
        var payload = Data()
        withUnsafeBytes(of: UInt32(1000).littleEndian) { payload.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(500).littleEndian) { payload.append(contentsOf: $0) }
        payload.append(Data("page content".utf8))

        session.processIncomingData(makeFrame(type: .scrollbackPage, payload: payload))

        XCTAssertEqual(delegate.scrollbackPages.count, 1)
        XCTAssertEqual(delegate.scrollbackPages[0].meta.totalLength, 1000)
        XCTAssertEqual(delegate.scrollbackPages[0].meta.offset, 500)
    }

    func testCommandForwardedToDelegate() {
        session.connect()
        session.processIncomingData(makeHandshake())

        let cmdData = Data("reload".utf8)
        session.processIncomingData(makeFrame(type: .command, payload: cmdData))

        XCTAssertEqual(delegate.commands.count, 1)
        XCTAssertEqual(String(data: delegate.commands[0], encoding: .utf8), "reload")
    }

    func testIdleForwardedToDelegate() {
        session.connect()
        session.processIncomingData(makeHandshake())

        // Idle notification has no payload
        session.processIncomingData(makeFrame(type: .idle, payload: Data()))

        XCTAssertEqual(delegate.idleCount, 1)
    }

    func testDataIgnoredWhenDisconnected() {
        session.processIncomingData(makeFrame(type: .terminalData, payload: Data("test".utf8)))

        XCTAssertTrue(delegate.terminalData.isEmpty)
    }

    // MARK: - Raw Mode Handshake Detection

    func testRawModeDetectsHandshake() {
        session.connect()

        // Send handshake frame directly (simulating rtach sending on connect)
        session.processIncomingData(makeHandshake())

        // Should have detected handshake and switched to framed mode
        XCTAssertTrue(session.isFramedMode)
        XCTAssertTrue(session.isRtachRunning)

        // Should have sent upgrade packet
        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData[0], PacketWriter.upgrade())
    }

    func testRawModeForwardsNonHandshakeAsTerminalData() {
        session.connect()

        // Send lots of raw data (more than 2x handshake frame size to trigger forwarding)
        // The implementation keeps a buffer for handshake detection, so we need enough data
        let rawData = Data(repeating: 0x41, count: 100) // 100 'A' characters
        session.processIncomingData(rawData)

        // Should forward most as terminal data, keeping some buffered for handshake detection
        XCTAssertFalse(session.isFramedMode)
        XCTAssertEqual(delegate.terminalData.count, 1)

        // Should have forwarded most of the data (keeps last 12 bytes for handshake detection)
        let handshakeFrameSize = ProtocolConstants.responseHeaderSize + ProtocolConstants.handshakeSize
        let expectedForwarded = rawData.count - handshakeFrameSize + 1
        XCTAssertEqual(delegate.terminalData[0].count, expectedForwarded)
    }

    func testRawModeWaitsForEnoughBytesToDetectHandshake() {
        session.connect()

        // Send partial handshake (not enough bytes)
        let partialData = Data([255, 8, 0]) // Only 3 bytes of the 13-byte handshake frame
        session.processIncomingData(partialData)

        // Should not forward yet - waiting for more data
        XCTAssertFalse(session.isFramedMode)
        XCTAssertTrue(delegate.terminalData.isEmpty)
    }

    func testRawModeHandlesDataAfterHandshake() {
        session.connect()

        // Send handshake followed by terminal data frame
        var data = makeHandshake()
        let terminalFrame = makeFrame(type: .terminalData, payload: Data("Hello".utf8))
        data.append(terminalFrame)

        session.processIncomingData(data)

        // Should be in framed mode
        XCTAssertTrue(session.isFramedMode)

        // Should have received terminal data
        XCTAssertEqual(delegate.terminalData.count, 1)
        XCTAssertEqual(delegate.terminalData[0], Data("Hello".utf8))
    }

    func testRawModeHandlesDataBeforeHandshake() {
        session.connect()

        // Send raw output BEFORE handshake (e.g., shell banner or rtach error)
        let rawOutput = Data("Welcome to server!\n".utf8)
        var data = rawOutput
        data.append(makeHandshake())

        session.processIncomingData(data)

        // Should be in framed mode
        XCTAssertTrue(session.isFramedMode)

        // Should have received the raw output as terminal data
        XCTAssertEqual(delegate.terminalData.count, 1)
        XCTAssertEqual(delegate.terminalData[0], rawOutput)

        // Should have sent upgrade
        XCTAssertEqual(delegate.sentData.count, 1)
        XCTAssertEqual(delegate.sentData[0], PacketWriter.upgrade())
    }

    func testRawModeHandlesDataBeforeAndAfterHandshake() {
        session.connect()

        // Send: [raw] [handshake] [framed terminal data]
        let rawOutput = Data("MOTD: Server ready\n".utf8)
        var data = rawOutput
        data.append(makeHandshake())
        data.append(makeFrame(type: .terminalData, payload: Data("$ ".utf8)))

        session.processIncomingData(data)

        // Should be in framed mode
        XCTAssertTrue(session.isFramedMode)

        // Should have received both: raw MOTD and framed prompt
        XCTAssertEqual(delegate.terminalData.count, 2)
        XCTAssertEqual(delegate.terminalData[0], rawOutput)
        XCTAssertEqual(delegate.terminalData[1], Data("$ ".utf8))
    }
}

// MARK: - Mock Delegate

final class MockDelegate: RtachSessionDelegate {
    var terminalData: [Data] = []
    var scrollbackData: [Data] = []
    var scrollbackPages: [(meta: ScrollbackPageMeta, data: Data)] = []
    var commands: [Data] = []
    var sentData: [Data] = []
    var idleCount: Int = 0

    func rtachSession(_ session: RtachSession, didReceiveTerminalData data: Data) {
        terminalData.append(data)
    }

    func rtachSession(_ session: RtachSession, didReceiveScrollback data: Data) {
        scrollbackData.append(data)
    }

    func rtachSession(_ session: RtachSession, didReceiveScrollbackPage meta: ScrollbackPageMeta, data: Data) {
        scrollbackPages.append((meta, data))
    }

    func rtachSession(_ session: RtachSession, didReceiveCommand data: Data) {
        commands.append(data)
    }

    func rtachSessionDidReceiveIdle(_ session: RtachSession) {
        idleCount += 1
    }

    func rtachSession(_ session: RtachSession, sendData data: Data) {
        sentData.append(data)
    }

    func rtachSessionDidEnterFramedMode(_ session: RtachSession) {
        // No-op for tests
    }
}
