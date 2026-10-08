import XCTest
@testable import Clauntty

@MainActor
final class SessionTests: XCTestCase {

    // MARK: - Initialization

    func testSessionInitialization() {
        let config = SavedConnection(
            name: "Test Server",
            host: "localhost",
            port: 22,
            username: "testuser",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)

        XCTAssertEqual(session.state, .disconnected)
        XCTAssertEqual(session.connectionConfig.host, "localhost")
        XCTAssertEqual(session.connectionConfig.username, "testuser")
        XCTAssertTrue(session.scrollbackBuffer.isEmpty)
    }

    func testSessionTitleWithName() {
        let config = SavedConnection(
            name: "My Server",
            host: "example.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        XCTAssertEqual(session.title, "My Server")
    }

    func testSessionTitleWithoutName() {
        let config = SavedConnection(
            name: "",
            host: "example.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        XCTAssertEqual(session.title, "user@example.com")
    }

    // MARK: - Data Handling

    func testHandleDataReceived() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        var receivedData: Data?

        session.onDataReceived = { data in
            receivedData = data
        }

        let testData = "Hello, World!".data(using: .utf8)!
        session.handleDataReceived(testData)

        XCTAssertEqual(receivedData, testData)
        XCTAssertEqual(session.scrollbackBuffer, testData)
    }

    func testScrollbackBufferAccumulates() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)

        session.handleDataReceived("First ".data(using: .utf8)!)
        session.handleDataReceived("Second ".data(using: .utf8)!)
        session.handleDataReceived("Third".data(using: .utf8)!)

        let expected = "First Second Third"
        XCTAssertEqual(String(data: session.scrollbackBuffer, encoding: .utf8), expected)
    }

    func testScrollbackBufferTruncation() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)

        // Create data larger than 50KB limit
        let largeData = Data(repeating: 65, count: 60 * 1024) // 60KB of 'A'

        session.handleDataReceived(largeData)

        // Should be truncated to 50KB
        XCTAssertEqual(session.scrollbackBuffer.count, 50 * 1024)
    }

    // MARK: - State Management

    func testStateEquality() {
        XCTAssertEqual(Session.State.disconnected, Session.State.disconnected)
        XCTAssertEqual(Session.State.connecting, Session.State.connecting)
        XCTAssertEqual(Session.State.connected, Session.State.connected)
        XCTAssertEqual(Session.State.error("test"), Session.State.error("test"))

        XCTAssertNotEqual(Session.State.disconnected, Session.State.connected)
        XCTAssertNotEqual(Session.State.error("a"), Session.State.error("b"))
    }

    func testDetach() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        var stateChanged: Session.State?

        session.onStateChanged = { state in
            stateChanged = state
        }

        // Simulate attached state
        session.detach()

        XCTAssertEqual(session.state, .disconnected)
        XCTAssertEqual(stateChanged, .disconnected)
        XCTAssertNil(session.sshChannel)
        XCTAssertNil(session.channelHandler)
    }

    // MARK: - Scrollback Persistence

    func testGetScrollbackData() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        let testData = "Test scrollback data".data(using: .utf8)!

        session.handleDataReceived(testData)

        XCTAssertEqual(session.getScrollbackData(), testData)
    }

    func testRestoreScrollback() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        let savedData = "Restored data".data(using: .utf8)!

        session.restoreScrollback(savedData)

        XCTAssertEqual(session.scrollbackBuffer, savedData)
    }

    func testClearScrollback() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)

        session.handleDataReceived("Some data".data(using: .utf8)!)
        XCTAssertFalse(session.scrollbackBuffer.isEmpty)

        session.clearScrollback()
        XCTAssertTrue(session.scrollbackBuffer.isEmpty)
    }

    // MARK: - Identity

    func testSessionHashable() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session1 = Session(connectionConfig: config)
        let session2 = Session(connectionConfig: config)

        // Different sessions should have different IDs
        XCTAssertNotEqual(session1.id, session2.id)
        XCTAssertNotEqual(session1, session2)

        // Same session should be equal to itself
        XCTAssertEqual(session1, session1)
    }

    // MARK: - Command Message Parsing

    /// Helper to create a command message with rtach protocol format
    /// Format: [type: 1 byte = 2][length: 4 bytes little-endian][command string]
    private func makeCommandMessage(_ command: String) -> Data {
        let commandData = command.data(using: .utf8)!
        var data = Data()
        data.append(2) // type = command
        // Length as little-endian UInt32
        var length = UInt32(commandData.count).littleEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(commandData)
        return data
    }

    func testCommandMessageDetection() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        var receivedPort: Int?

        session.onOpenTabRequested = { port in
            receivedPort = port
        }

        // Send a complete command message
        let commandMsg = makeCommandMessage("open;3000")
        session.handleDataReceived(commandMsg)

        XCTAssertEqual(receivedPort, 3000)
        // Command should NOT be added to scrollback buffer
        XCTAssertTrue(session.scrollbackBuffer.isEmpty)
    }

    func testCommandMessageForward() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        var forwardedPort: Int?

        session.onPortForwardRequested = { port in
            forwardedPort = port
        }

        let commandMsg = makeCommandMessage("forward;8080")
        session.handleDataReceived(commandMsg)

        XCTAssertEqual(forwardedPort, 8080)
    }

    func testNormalDataNotMistaken() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        var receivedData: Data?

        session.onDataReceived = { data in
            receivedData = data
        }

        // Normal terminal data starting with something other than 0x02
        let normalData = "Hello terminal".data(using: .utf8)!
        session.handleDataReceived(normalData)

        XCTAssertEqual(receivedData, normalData)
        XCTAssertEqual(session.scrollbackBuffer, normalData)
    }

    func testCommandMessageSplitAcrossPackets() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        var receivedPort: Int?

        session.onOpenTabRequested = { port in
            receivedPort = port
        }

        // Full message: [02][09 00 00 00][open;3000]
        let fullMessage = makeCommandMessage("open;3000")

        // Split into: header partial, header rest + data partial, data rest
        let part1 = fullMessage.prefix(3)  // type + 2 bytes of length
        let part2 = fullMessage.dropFirst(3).prefix(4)  // rest of length + partial command
        let part3 = fullMessage.dropFirst(7)  // rest of command

        session.handleDataReceived(Data(part1))
        XCTAssertNil(receivedPort, "Should not trigger yet - header incomplete")

        session.handleDataReceived(Data(part2))
        XCTAssertNil(receivedPort, "Should not trigger yet - data incomplete")

        session.handleDataReceived(Data(part3))
        XCTAssertEqual(receivedPort, 3000, "Should trigger after all data received")
    }

    func testMixedCommandAndTerminalData() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        var receivedPort: Int?
        var terminalData = Data()

        session.onOpenTabRequested = { port in
            receivedPort = port
        }
        session.onDataReceived = { data in
            terminalData.append(data)
        }

        // Send terminal data first
        let beforeData = "Before command\n".data(using: .utf8)!
        session.handleDataReceived(beforeData)

        // Then a command
        let commandMsg = makeCommandMessage("open;5000")
        session.handleDataReceived(commandMsg)

        // Then more terminal data
        let afterData = "After command\n".data(using: .utf8)!
        session.handleDataReceived(afterData)

        XCTAssertEqual(receivedPort, 5000)
        XCTAssertEqual(String(data: terminalData, encoding: .utf8), "Before command\nAfter command\n")
    }

    func testUnknownCommandIgnored() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        var openCalled = false
        var forwardCalled = false

        session.onOpenTabRequested = { _ in openCalled = true }
        session.onPortForwardRequested = { _ in forwardCalled = true }

        // Unknown command should be silently ignored
        let commandMsg = makeCommandMessage("unknown;arg")
        session.handleDataReceived(commandMsg)

        XCTAssertFalse(openCalled)
        XCTAssertFalse(forwardCalled)
        XCTAssertTrue(session.scrollbackBuffer.isEmpty)
    }

    func testInvalidCommandLengthTreatedAsTerminalData() {
        let config = SavedConnection(
            name: "",
            host: "localhost",
            port: 22,
            username: "test",
            authMethod: .password
        )

        let session = Session(connectionConfig: config)
        var terminalData = Data()

        session.onDataReceived = { data in
            terminalData.append(data)
        }

        // Create a message that starts with type=2 but has absurdly large length
        // This should be treated as terminal data, not a command
        var badMessage = Data()
        badMessage.append(2) // type = command
        var hugeLength = UInt32(0xFFFFFFFF).littleEndian // 4GB - way too large
        badMessage.append(Data(bytes: &hugeLength, count: 4))
        badMessage.append("normal text".data(using: .utf8)!)

        session.handleDataReceived(badMessage)

        // The header bytes should be forwarded as terminal data since length is invalid
        XCTAssertFalse(terminalData.isEmpty)
    }

    // MARK: - Image Inbox

    func testImageArgumentWithInboxId() {
        let (path, id) = ImageInbox.parseImageArgument("1791500593207-97841-0;/tmp/a;b.png")
        XCTAssertEqual(path, "/tmp/a;b.png")
        XCTAssertEqual(id, "1791500593207-97841-0")
    }

    func testImageArgumentWithoutInboxId() {
        let (path, id) = ImageInbox.parseImageArgument("/tmp/shot.png")
        XCTAssertEqual(path, "/tmp/shot.png")
        XCTAssertNil(id)
    }

    func testInboxIdValidation() {
        XCTAssertTrue(ImageInbox.isValidId("1791500593207-97841-0"))
        XCTAssertFalse(ImageInbox.isValidId("1791500593207-97841"))
        XCTAssertFalse(ImageInbox.isValidId("1-2-3;rm"))
        XCTAssertFalse(ImageInbox.isValidId("1--3"))
        XCTAssertEqual(ImageInbox.createdAt("1791500593207-1-0"), Date(timeIntervalSince1970: 1791500593.207))
    }

    func testInboxListParsing() {
        let output = "1791500593207-97841-0\t/tmp/a.png\n.junk\tx\n1791500593549-97848-1\t/tmp/b c.png\n"
        XCTAssertEqual(ImageInbox.parseList(output), [
            .init(id: "1791500593207-97841-0", path: "/tmp/a.png"),
            .init(id: "1791500593549-97848-1", path: "/tmp/b c.png"),
        ])
    }

    func testInboxRemoveCommandSkipsInvalidIds() {
        XCTAssertEqual(ImageInbox.removeCommand(["1-2-3", "x; rm -rf ~"]), "rm -f ~/.clauntty/inbox/1-2-3")
        XCTAssertNil(ImageInbox.removeCommand(["bad"]))
    }
}
