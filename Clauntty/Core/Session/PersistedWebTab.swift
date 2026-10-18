import Foundation

/// Persisted web tab state for restoring tabs after app restart
/// Stored in UserDefaults, tabs are restored in disconnected state and reconnect on demand
struct PersistedWebTab: Codable, Identifiable {
    /// Unique tab identifier (matches WebTab.id)
    let id: UUID

    /// Reference to the saved connection (for reconnecting)
    let connectionId: UUID

    /// Remote port number being forwarded
    let remotePort: Int

    /// Process name if known (e.g., "node", "bun")
    let remotePortProcess: String?

    /// Address the port is bound to (e.g., "0.0.0.0", "127.0.0.1")
    let remotePortAddress: String

    /// When the tab was first created
    let createdAt: Date

    /// When the tab was last active
    var lastActiveAt: Date

    /// Cached page title from web view
    var cachedPageTitle: String?

    /// Last visited path (for restoring navigation state)
    var lastPath: String?

    /// Order index for tab ordering
    var orderIndex: Int

    /// The workspace tab it belongs to (a session group id), if any
    var workspaceId: UUID?
}
