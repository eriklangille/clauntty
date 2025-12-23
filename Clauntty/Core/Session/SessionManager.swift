import Foundation
import NIOCore
import NIOSSH
import os.log

/// Manages all terminal sessions and connection pooling
/// Reuses SSH connections when opening multiple tabs to the same server
@MainActor
class SessionManager: ObservableObject {
    // MARK: - Published State

    /// All active sessions
    @Published var sessions: [Session] = []

    /// Currently active session ID (shown in terminal view)
    @Published var activeSessionId: UUID?

    /// Currently active session
    var activeSession: Session? {
        sessions.first { $0.id == activeSessionId }
    }

    // MARK: - Connection Pool

    /// Pool of SSH connections, keyed by "user@host:port"
    private var connectionPool: [String: SSHConnection] = [:]

    // MARK: - Session Management

    /// Create a new session for a connection config
    /// Reuses existing SSH connection if available
    func createSession(for config: SavedConnection) -> Session {
        let session = Session(connectionConfig: config)
        sessions.append(session)

        // Always make new session active (user just opened it)
        activeSessionId = session.id

        Logger.clauntty.info("SessionManager: created session \(session.id.uuidString.prefix(8)) for \(config.host)")
        return session
    }

    /// Connect a session (authenticate and open channel)
    func connect(session: Session) async throws {
        session.state = .connecting

        let config = session.connectionConfig
        let poolKey = connectionKey(for: config)

        // Get or create SSH connection
        let connection: SSHConnection
        if let existing = connectionPool[poolKey], existing.isConnected {
            Logger.clauntty.info("SessionManager: reusing existing connection for \(poolKey)")
            connection = existing
        } else {
            Logger.clauntty.info("SessionManager: creating new connection for \(poolKey)")
            connection = SSHConnection(
                host: config.host,
                port: config.port,
                username: config.username,
                authMethod: config.authMethod,
                connectionId: config.id
            )

            // Connect (authenticates)
            try await connection.connect()
            connectionPool[poolKey] = connection
        }

        // Create a new channel for this session
        let (channel, handler) = try await connection.createChannel { [weak session] data in
            Task { @MainActor in
                session?.handleDataReceived(data)
            }
        }

        session.attach(channel: channel, handler: handler, connection: connection)
        Logger.clauntty.info("SessionManager: session \(session.id.uuidString.prefix(8)) connected")
    }

    /// Close a session
    func closeSession(_ session: Session) {
        Logger.clauntty.info("SessionManager: closing session \(session.id.uuidString.prefix(8))")

        // Detach from channel
        session.detach()

        // Remove from sessions list
        sessions.removeAll { $0.id == session.id }

        // If this was the active session, switch to another
        if activeSessionId == session.id {
            activeSessionId = sessions.first?.id
        }

        // Check if connection should be closed (no more sessions using it)
        cleanupUnusedConnections()
    }

    /// Switch to a different session
    func switchTo(_ session: Session) {
        guard sessions.contains(where: { $0.id == session.id }) else {
            Logger.clauntty.warning("SessionManager: cannot switch to unknown session")
            return
        }
        activeSessionId = session.id
        Logger.clauntty.info("SessionManager: switched to session \(session.id.uuidString.prefix(8))")
    }

    /// Close all sessions
    func closeAllSessions() {
        Logger.clauntty.info("SessionManager: closing all sessions")
        for session in sessions {
            session.detach()
        }
        sessions.removeAll()
        activeSessionId = nil

        // Close all connections
        for (_, connection) in connectionPool {
            connection.disconnect()
        }
        connectionPool.removeAll()
    }

    // MARK: - Connection Pooling

    /// Generate pool key for a connection config
    private func connectionKey(for config: SavedConnection) -> String {
        return "\(config.username)@\(config.host):\(config.port)"
    }

    /// Clean up connections that have no active sessions
    private func cleanupUnusedConnections() {
        // Get all pool keys that have active sessions
        let activeKeys = Set(sessions.map { connectionKey(for: $0.connectionConfig) })

        // Close connections not in use
        for (key, connection) in connectionPool {
            if !activeKeys.contains(key) {
                Logger.clauntty.info("SessionManager: closing unused connection \(key)")
                connection.disconnect()
                connectionPool.removeValue(forKey: key)
            }
        }
    }

    /// Get the number of sessions using a particular connection
    func sessionCount(for config: SavedConnection) -> Int {
        let key = connectionKey(for: config)
        return sessions.filter { connectionKey(for: $0.connectionConfig) == key }.count
    }

    // MARK: - Convenience

    /// Check if there are any active sessions
    var hasSessions: Bool {
        !sessions.isEmpty
    }

    /// Get session by ID
    func session(id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }
}
