import Foundation
import SwiftUI

/// Manages persistence of saved SSH connections
@MainActor
class ConnectionStore: ObservableObject {
    @Published var connections: [SavedConnection] = []

    private let storageKey = "savedConnections"

    init() {
        load()
    }

    // MARK: - CRUD Operations

    func add(_ connection: SavedConnection) {
        connections.append(connection)
        save()
    }

    func update(_ connection: SavedConnection) {
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = connection
            save()
        }
    }

    func delete(_ connection: SavedConnection) {
        connections.removeAll { $0.id == connection.id }
        // Also remove credentials from Keychain
        try? KeychainHelper.deleteCredentials(for: connection.id)
        save()
    }

    func delete(at offsets: IndexSet) {
        let connectionsToDelete = offsets.map { connections[$0] }
        for connection in connectionsToDelete {
            try? KeychainHelper.deleteCredentials(for: connection.id)
        }
        connections.remove(atOffsets: offsets)
        save()
    }

    /// Put a connection where `target` is, moving the ones between along
    func move(_ id: UUID, to target: UUID) {
        guard id != target,
              let from = connections.firstIndex(where: { $0.id == id }),
              let to = connections.firstIndex(where: { $0.id == target }) else { return }
        connections.insert(connections.remove(at: from), at: to)
        save()
    }

    func updateLastConnected(_ connection: SavedConnection) {
        var updated = connection
        updated.lastConnected = Date()
        update(updated)
    }

    /// Check if a connection with the same host, port, username, and name already exists
    /// Returns the existing connection if found, nil otherwise
    /// Excludes the connection with the given ID (for editing)
    func findDuplicate(of connection: SavedConnection, excludingId: UUID? = nil) -> SavedConnection? {
        return connections.first { existing in
            existing.id != excludingId &&
            existing.host.lowercased() == connection.host.lowercased() &&
            existing.port == connection.port &&
            existing.username == connection.username &&
            existing.name.lowercased() == connection.name.lowercased()
        }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(connections)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            print("Failed to save connections: \(error)")
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return
        }
        do {
            connections = try JSONDecoder().decode([SavedConnection].self, from: data)
        } catch {
            print("Failed to load connections: \(error)")
        }
    }
}
