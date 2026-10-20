import Foundation
import os.log

/// A host's SSH connections, shared by everything on it: each pane is a channel on one
/// of them, and commands (deploys, `rtach ws`, listing, uploads) and port forwards use
/// the first. A host gets another connection only when its panes don't fit on one:
/// sshd allows 10 sessions per connection by default (`MaxSessions`), and every pane's
/// channel and every running command is one.
extension SessionManager {
    /// Panes per connection, under sshd's default of 10 sessions: commands (a refresh
    /// and a reorder at once, uploads) and connection checks open sessions too
    static let panesPerConnection = 6

    /// A live connection to the host, connecting if it has none
    func hostConnection(for config: SavedConnection) async throws -> SSHConnection {
        let key = connectionKey(for: config)
        if let live = liveConnections(key).first {
            return live
        }
        if let pending = connectingHosts[key] {
            return try await pending.value
        }
        return try await openConnection(for: config)
    }

    /// A live connection with room for another pane, opening one if they're all full.
    /// The pane takes its place on it now (`releasePane` gives it back).
    func paneConnection(for config: SavedConnection) async throws -> SSHConnection {
        let key = connectionKey(for: config)
        while true {
            if let roomy = liveConnections(key).first(where: {
                $0.paneChannels < ($0.paneLimit ?? Self.panesPerConnection)
            }) {
                roomy.reservePane()
                return roomy
            }
            // Another pane is connecting the host: it may have room once that's done
            if let pending = connectingHosts[key] {
                _ = try await pending.value
                continue
            }
            // Then take a place on it like everyone else: others waiting may have filled it
            _ = try await openConnection(for: config)
        }
    }

    /// The host's live connection, without connecting
    func liveConnection(for config: SavedConnection) -> SSHConnection? {
        liveConnections(connectionKey(for: config)).first
    }

    /// Every live connection, to every host
    var allConnections: [SSHConnection] {
        hostConnections.values.flatMap { $0.filter(\.isConnected) }
    }

    /// Close a connection that stopped answering and take it out. Its panes go
    /// disconnected; with `reconnect`, the one you're in (if it was there) reconnects.
    func dropConnection(_ connection: SSHConnection, reconnect: Bool) {
        for key in hostConnections.keys {
            hostConnections[key]?.removeAll { $0 === connection }
        }
        let attached = sessions.filter { $0.sshConnection === connection }
        connection.disconnect()
        for session in attached {
            session.handleChannelInactive()
            if reconnect {
                session.onNeedsReconnect?()
            }
        }
    }

    /// Close the connections of hosts with no tab left, and a host's extra connections
    /// once no pane is on them. The first stays for commands, forwards and new panes.
    func closeIdleConnections() {
        let hostsInUse = Set(sessions.map { connectionKey(for: $0.connectionConfig) })
        for (key, connections) in hostConnections {
            let live = connections.filter(\.isConnected)
            guard hostsInUse.contains(key) else {
                Logger.clauntty.debugOnly("SessionManager: closing \(live.count) connection(s) to \(key), no tabs left")
                live.forEach { $0.disconnect() }
                hostConnections[key] = nil
                continue
            }
            var kept = Array(live.prefix(1))
            for connection in live.dropFirst() {
                if connection.paneChannels > 0 {
                    kept.append(connection)
                } else {
                    Logger.clauntty.debugOnly("SessionManager: closing an extra connection to \(key), no panes left on it")
                    connection.disconnect()
                }
            }
            hostConnections[key] = kept
        }
    }

    /// A connection's server refused another channel (it allows fewer sessions per
    /// connection than we assume): no more panes go on it. Call after giving back the
    /// refused pane's place.
    func channelRefused(on connection: SSHConnection) {
        // One fewer than fit, so commands still fit
        connection.paneLimit = max(connection.paneChannels - 1, 1)
    }

    private func liveConnections(_ key: String) -> [SSHConnection] {
        hostConnections[key]?.filter(\.isConnected) ?? []
    }

    /// Connect to the host once more. Callers that need one meanwhile wait for this one
    /// (`connectingHosts`), so the panes of a split reconnecting together share it.
    private func openConnection(for config: SavedConnection) async throws -> SSHConnection {
        let key = connectionKey(for: config)
        // The task itself records the connection, so whoever awaits it next finds it
        // listed: one who looked again before the opener resumed spun on the main actor
        let connecting = Task { () throws -> SSHConnection in
            defer { connectingHosts[key] = nil }
            let connection = SSHConnection(
                host: config.host,
                port: config.port,
                username: config.username,
                authMethod: config.authMethod,
                connectionId: config.id,
                useTailscale: config.useTailscale,
                proxyCommand: config.proxyCommand
            )
            try await connection.connect()
            hostConnections[key] = liveConnections(key) + [connection]
            Logger.clauntty.debugOnly("SessionManager: connected to \(key) (\(self.hostConnections[key]?.count ?? 0) connection(s))")
            return connection
        }
        connectingHosts[key] = connecting
        return try await connecting.value
    }
}
