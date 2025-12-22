import XCTest
@testable import Clauntty

final class SSHConnectionTests: XCTestCase {

    // Note: Full SSH tests require a running SSH server
    // These tests verify initialization and state management

    @MainActor
    func testConnectionInitialization() async {
        // Test that SSHConnection can be created with valid parameters
        let connectionId = UUID()
        let connection = SSHConnection(
            host: "localhost",
            port: 22,
            username: "testuser",
            authMethod: .password,
            connectionId: connectionId
        )

        // Initial state should be disconnected
        XCTAssertEqual(connection.state, .disconnected)
    }

    @MainActor
    func testDataReceivedCallback() async {
        // Test that the onDataReceived callback can be set
        let connectionId = UUID()
        let connection = SSHConnection(
            host: "localhost",
            port: 22,
            username: "testuser",
            authMethod: .password,
            connectionId: connectionId
        )

        var receivedData: Data?
        connection.onDataReceived = { data in
            receivedData = data
        }

        // The callback should be set (we can't test actual SSH data without a server)
        XCTAssertNotNil(connection.onDataReceived)
    }

    @MainActor
    func testConnectionWithSSHKey() async {
        // Test that SSHConnection can be created with SSH key auth
        let connectionId = UUID()
        let connection = SSHConnection(
            host: "localhost",
            port: 22,
            username: "testuser",
            authMethod: .sshKey(keyId: "test-key-id"),
            connectionId: connectionId
        )

        XCTAssertEqual(connection.state, .disconnected)
    }

    // MARK: - Integration Tests (require running SSH server)

    // To test with local SSH (enabled on Mac):
    // 1. Enable SSH: System Settings > General > Sharing > Remote Login
    // 2. Run test with valid credentials

    @MainActor
    func testConnectionToLocalhost() async throws {
        // Skip this test if SSH isn't enabled locally
        // This test would connect to localhost SSH server

        // Uncomment to test with local SSH:
        /*
        let connectionId = UUID()
        // First save a password to keychain for the test
        try KeychainHelper.savePassword(for: connectionId, password: "your-password")

        let connection = SSHConnection(
            host: "localhost",
            port: 22,
            username: "your-username",
            authMethod: .password,
            connectionId: connectionId
        )

        var dataReceived = false
        connection.onDataReceived = { data in
            dataReceived = true
            print("Received \(data.count) bytes")
        }

        do {
            try await connection.connect()
            XCTAssertEqual(connection.state, .connected)

            // Wait for some data (shell prompt)
            try await Task.sleep(for: .seconds(1))
            XCTAssertTrue(dataReceived, "Should have received data from shell")

            connection.disconnect()
        } catch {
            XCTFail("Connection failed: \(error)")
        }
        */
    }

    // TODO: Add mock SSH server tests
    // This would allow testing:
    // - Connection establishment
    // - Authentication flows
    // - Channel creation
    // - Data transfer
}

// MARK: - SSHConnection.State Equatable conformance for testing

extension SSHConnection.State: Equatable {
    public static func == (lhs: SSHConnection.State, rhs: SSHConnection.State) -> Bool {
        switch (lhs, rhs) {
        case (.disconnected, .disconnected):
            return true
        case (.connecting, .connecting):
            return true
        case (.authenticating, .authenticating):
            return true
        case (.connected, .connected):
            return true
        case (.error, .error):
            return true
        default:
            return false
        }
    }
}
