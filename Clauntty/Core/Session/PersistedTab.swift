import Foundation

/// Persisted tab state for restoring tabs after app restart
/// Stored in UserDefaults, tabs are restored in disconnected state
struct PersistedTab: Codable, Identifiable {
    /// Unique tab identifier (matches Session.id)
    let id: UUID

    /// Reference to the saved connection (for reconnecting)
    let connectionId: UUID

    /// The rtach session ID on the remote server
    let rtachSessionId: String

    /// When the tab was first created
    let createdAt: Date

    /// When the tab was last active
    var lastActiveAt: Date

    /// Cached session title (shown while disconnected)
    var cachedTitle: String?

    /// Cached dynamic title from terminal escape sequences
    var cachedDynamicTitle: String?

    /// Order index for tab ordering
    var orderIndex: Int

    /// Font size for this tab (nil = use global default)
    var fontSize: Float?
}
