import XCTest
@testable import Clauntty

@MainActor
final class SessionManagerTests: XCTestCase {

    var sessionManager: SessionManager!

    override func setUp() {
        super.setUp()
        sessionManager = SessionManager()
    }

    override func tearDown() {
        sessionManager.closeAllSessions()
        sessionManager = nil
        super.tearDown()
    }

    // MARK: - Session Creation

    func testCreateSession() {
        let config = SavedConnection(
            name: "Test",
            host: "localhost",
            port: 22,
            username: "user",
            authMethod: .password
        )

        let session = sessionManager.createSession(for: config)

        XCTAssertEqual(sessionManager.sessions.count, 1)
        XCTAssertEqual(session.connectionConfig.host, "localhost")
        XCTAssertEqual(session.state, .disconnected)
    }

    func testFirstSessionBecomesActive() {
        let config = SavedConnection(
            name: "Test",
            host: "localhost",
            port: 22,
            username: "user",
            authMethod: .password
        )

        let session = sessionManager.createSession(for: config)

        XCTAssertEqual(sessionManager.activeSessionId, session.id)
        XCTAssertEqual(sessionManager.activeSession?.id, session.id)
    }

    func testNewSessionBecomesActive() {
        let config1 = SavedConnection(
            name: "Server1",
            host: "server1.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        let config2 = SavedConnection(
            name: "Server2",
            host: "server2.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        _ = sessionManager.createSession(for: config1)
        let session2 = sessionManager.createSession(for: config2)

        XCTAssertEqual(sessionManager.sessions.count, 2)
        // New session should always become active
        XCTAssertEqual(sessionManager.activeSessionId, session2.id)
    }

    // MARK: - Session Switching

    func testSwitchToSession() {
        let config1 = SavedConnection(
            name: "Server1",
            host: "server1.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        let config2 = SavedConnection(
            name: "Server2",
            host: "server2.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        _ = sessionManager.createSession(for: config1)
        let session2 = sessionManager.createSession(for: config2)

        sessionManager.switchTo(session2)

        XCTAssertEqual(sessionManager.activeSessionId, session2.id)
    }

    // MARK: - Session Closing

    func testCloseSession() {
        let config = SavedConnection(
            name: "Test",
            host: "localhost",
            port: 22,
            username: "user",
            authMethod: .password
        )

        let session = sessionManager.createSession(for: config)
        sessionManager.closeSession(session)

        XCTAssertEqual(sessionManager.sessions.count, 0)
        XCTAssertNil(sessionManager.activeSessionId)
    }

    func testCloseActiveSessionSwitchesToAnother() {
        let config1 = SavedConnection(
            name: "Server1",
            host: "server1.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        let config2 = SavedConnection(
            name: "Server2",
            host: "server2.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        let session1 = sessionManager.createSession(for: config1)
        let session2 = sessionManager.createSession(for: config2)

        // session1 is active
        XCTAssertEqual(sessionManager.activeSessionId, session1.id)

        // Close session1
        sessionManager.closeSession(session1)

        // session2 should now be active
        XCTAssertEqual(sessionManager.sessions.count, 1)
        XCTAssertEqual(sessionManager.activeSessionId, session2.id)
    }

    func testCloseAllSessions() {
        let config1 = SavedConnection(
            name: "Server1",
            host: "server1.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        let config2 = SavedConnection(
            name: "Server2",
            host: "server2.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        _ = sessionManager.createSession(for: config1)
        _ = sessionManager.createSession(for: config2)

        sessionManager.closeAllSessions()

        XCTAssertEqual(sessionManager.sessions.count, 0)
        XCTAssertNil(sessionManager.activeSessionId)
        XCTAssertFalse(sessionManager.hasSessions)
    }

    // MARK: - Session Lookup

    func testSessionById() {
        let config = SavedConnection(
            name: "Test",
            host: "localhost",
            port: 22,
            username: "user",
            authMethod: .password
        )

        let session = sessionManager.createSession(for: config)
        let found = sessionManager.session(id: session.id)

        XCTAssertEqual(found?.id, session.id)
    }

    func testSessionByIdNotFound() {
        let found = sessionManager.session(id: UUID())
        XCTAssertNil(found)
    }

    // MARK: - Session Count

    func testSessionCountForConnection() {
        let config = SavedConnection(
            name: "Server",
            host: "server.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        // Create multiple sessions to same server
        _ = sessionManager.createSession(for: config)
        _ = sessionManager.createSession(for: config)
        _ = sessionManager.createSession(for: config)

        XCTAssertEqual(sessionManager.sessionCount(for: config), 3)
    }

    func testSessionCountDifferentServers() {
        let config1 = SavedConnection(
            name: "Server1",
            host: "server1.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        let config2 = SavedConnection(
            name: "Server2",
            host: "server2.com",
            port: 22,
            username: "user",
            authMethod: .password
        )

        _ = sessionManager.createSession(for: config1)
        _ = sessionManager.createSession(for: config1)
        _ = sessionManager.createSession(for: config2)

        XCTAssertEqual(sessionManager.sessionCount(for: config1), 2)
        XCTAssertEqual(sessionManager.sessionCount(for: config2), 1)
    }

    // MARK: - Has Sessions

    func testHasSessionsEmpty() {
        XCTAssertFalse(sessionManager.hasSessions)
    }

    func testHasSessionsWithSessions() {
        let config = SavedConnection(
            name: "Test",
            host: "localhost",
            port: 22,
            username: "user",
            authMethod: .password
        )

        _ = sessionManager.createSession(for: config)

        XCTAssertTrue(sessionManager.hasSessions)
    }
}
