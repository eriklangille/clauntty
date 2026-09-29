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

// MARK: - Login Callback Ports

final class LoopbackCallbackTests: XCTestCase {
    private func ports(_ string: String) -> [Int] {
        LoopbackCallback.ports(in: URL(string: string)!)
    }

    func testEncodedRedirectURI() {
        XCTAssertEqual(ports("https://auth.openai.com/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=abc"), [1455])
    }

    func testLoopbackIPs() {
        XCTAssertEqual(ports("https://claude.ai/oauth/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A54545%2Fcallback"), [54545])
        XCTAssertEqual(ports("https://x.test/auth?redirect_uri=http%3A%2F%2F%5B%3A%3A1%5D%3A8123%2F"), [8123])
    }

    func testDirectLocalhostURL() {
        XCTAssertEqual(ports("http://localhost:5173/"), [5173])
    }

    func testNestedRedirect() {
        let inner = "https://auth.test/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A9000%2Fcb"
        let outer = "https://auth.test/login?return_to=" + inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertEqual(ports(outer), [9000])
    }

    func testIgnoresNonLoopbackAndPortlessURLs() {
        XCTAssertEqual(ports("https://github.com/login/device"), [])
        XCTAssertEqual(ports("https://x.test/a?redirect_uri=https%3A%2F%2Fexample.com%3A8443%2Fcb"), [])
        XCTAssertEqual(ports("https://x.test/a?redirect_uri=http%3A%2F%2Flocalhost%2Fcb"), [])
    }
}
