import Foundation

/// Model for storing SSH key metadata
/// The actual key data is stored in Keychain, this just tracks the label and ID
struct SSHKey: Codable, Identifiable, Hashable {
    /// UUID string, used as keychain ID reference
    let id: String

    /// User-provided name (e.g., "Work Laptop", "Personal")
    var label: String

    /// When the key was imported
    let createdAt: Date

    /// Optional SHA256 fingerprint for display
    var fingerprint: String?

    init(id: String = UUID().uuidString, label: String, createdAt: Date = Date(), fingerprint: String? = nil) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
        self.fingerprint = fingerprint
    }
}
