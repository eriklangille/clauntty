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

        Logger.clauntty.debugOnly("Added SSH key: \(label) (id: \(id.prefix(8)))")
        return key
    }

    /// A new Ed25519 key made here; its public half goes in a server's `authorized_keys`
    func generateKey(label: String) throws -> SSHKey {
        try addKey(label: label, privateKeyData: OpenSSHKeyFile.generateEd25519(comment: Self.keyComment))
    }

    /// The app's own key, made the first time a server needs one: a tailnet machine added
    /// with a tap signs in with it (or Tailscale SSH lets it in without)
    func appKey() throws -> SSHKey {
        if let id = UserDefaults.standard.string(forKey: appKeyIdKey), let key = key(withId: id) {
            return key
        }
        var label = "Clauntty"
        var n = 2
        while keyExists(withLabel: label) {
            label = "Clauntty \(n)"
            n += 1
        }
        let key = try generateKey(label: label)
        UserDefaults.standard.set(key.id, forKey: appKeyIdKey)
        return key
    }

    /// The key's line for `authorized_keys`, for keys kept in the Keychain
    func publicKey(for key: SSHKey) -> String? {
        guard let stored = try? KeychainHelper.getSSHKey(id: key.id) else { return nil }
        return OpenSSHKeyFile.publicKeyLine(privateKey: stored.privateKey, comment: Self.keyComment)
    }

    private static let keyComment = "clauntty"
    private let appKeyIdKey = "appSSHKeyId"

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
        Logger.clauntty.debugOnly("Deleted SSH key: \(key.label)")
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
            Logger.clauntty.debugOnly("Loaded \(self.keys.count) SSH keys")
        } catch {
            Logger.clauntty.error("Failed to load SSH keys: \(error.localizedDescription)")
        }
    }
}
