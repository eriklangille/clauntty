import Foundation
import SwiftUI
import os.log

/// Manages persistence of SSH key metadata
/// Key data is stored in Keychain, this stores labels and IDs in UserDefaults
@MainActor
class SSHKeyStore: ObservableObject {
    @Published private(set) var keys: [SSHKey] = []

    private let storageKey = "savedSSHKeys"

    init() {
        load()
    }

    // MARK: - CRUD Operations

    /// Add a new SSH key
    /// - Parameters:
    ///   - label: User-provided name for the key
    ///   - privateKeyData: The raw private key data
    ///   - passphrase: Optional passphrase for encrypted keys
    /// - Returns: The created SSHKey metadata
    func addKey(label: String, privateKeyData: Data, passphrase: String? = nil) throws -> SSHKey {
        let id = UUID().uuidString

        // Save to Keychain first
        try KeychainHelper.saveSSHKey(id: id, privateKey: privateKeyData, passphrase: passphrase)

        // Create metadata
        let key = SSHKey(id: id, label: label, createdAt: Date())
        keys.append(key)
        save()

        Logger.clauntty.info("Added SSH key: \(label) (id: \(id.prefix(8)))")
        return key
    }

    /// Update an existing key's label
    func update(_ key: SSHKey) {
        if let index = keys.firstIndex(where: { $0.id == key.id }) {
            keys[index] = key
            save()
        }
    }

    /// Delete an SSH key (removes from both Keychain and metadata)
    func deleteKey(_ key: SSHKey) throws {
        try KeychainHelper.deleteSSHKey(id: key.id)
        keys.removeAll { $0.id == key.id }
        save()
        Logger.clauntty.info("Deleted SSH key: \(key.label)")
    }

    /// Get a key by ID
    func key(withId id: String) -> SSHKey? {
        keys.first { $0.id == id }
    }

    /// Check if a key with the given label already exists
    func keyExists(withLabel label: String) -> Bool {
        keys.contains { $0.label.lowercased() == label.lowercased() }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(keys)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            Logger.clauntty.error("Failed to save SSH keys: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return
        }
        do {
            keys = try JSONDecoder().decode([SSHKey].self, from: data)
            Logger.clauntty.info("Loaded \(self.keys.count) SSH keys")
        } catch {
            Logger.clauntty.error("Failed to load SSH keys: \(error.localizedDescription)")
        }
    }
}
