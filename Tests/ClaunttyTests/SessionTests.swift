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
}
