import Foundation
import NIOCore
import NIOSSH
import os.log

/// Manages all terminal sessions, web tabs, and connection pooling
/// Reuses SSH connections when opening multiple tabs to the same server
@MainActor
class SessionManager: ObservableObject {
    // MARK: - Published State

    /// All active terminal sessions
    @Published var sessions: [Session] = []

    /// All active web tabs
    @Published var webTabs: [WebTab] = []

    /// Ports being forwarded without a web tab (background forwarding)
    @Published var forwardedPorts: [ForwardedPort] = []

    /// Currently active tab type and ID
    enum ActiveTab: Equatable {
        case terminal(UUID)
        case web(UUID)
    }

    @Published var activeTab: ActiveTab?

    /// Version counter incremented when session states change (for SwiftUI updates)
    @Published var sessionStateVersion: Int = 0

    /// Global tab ordering - list of tab IDs in display order
    /// Contains all terminal session IDs and web tab IDs mixed together
    @Published var tabOrder: [UUID] = []

    /// Previously active tab (for "go back" navigation)
    private(set) var previousActiveTab: ActiveTab?

    /// Currently active terminal session (if a terminal is active)
    var activeSession: Session? {
        if case .terminal(let id) = activeTab {
            return sessions.first { $0.id == id }
        }
        return nil
    }

    /// Currently active web tab (if a web tab is active)
    var activeWebTab: WebTab? {
        if case .web(let id) = activeTab {
            return webTabs.first { $0.id == id }
        }
        return nil
    }

    /// Legacy compatibility - active session ID
    var activeSessionId: UUID? {
        get {
            if case .terminal(let id) = activeTab {
                return id
            }
            return nil
        }
        set {
            if let id = newValue {
                activeTab = .terminal(id)
            }
        }
    }

    // MARK: - Connection Pool

    /// Pool of SSH connections, keyed by "user@host:port"
    private var connectionPool: [String: SSHConnection] = [:]

    // MARK: - Reconnection Throttling

    /// Tracks last reconnect attempt time per session to prevent crash loops
    private var lastReconnectAttempt: [UUID: Date] = [:]

    /// Minimum time between reconnect attempts (prevents rapid crash loops)
    private let reconnectBackoff: TimeInterval = 2.0

    // MARK: - Session Management

    /// Create a new session for a connection config
    /// Reuses existing SSH connection if available
    func createSession(for config: SavedConnection) -> Session {
        let session = Session(connectionConfig: config)

        // Set up callback to increment version when state changes (triggers SwiftUI updates)
        session.onStateChange = { [weak self] in
            self?.sessionStateVersion += 1
        }

        sessions.append(session)

        // Add to global tab order
        tabOrder.append(session.id)
        saveTabOrder()

        // Always make new session active (user just opened it)
        activeSessionId = session.id

        Logger.clauntty.debugOnly("SessionManager: created session \(session.id.uuidString.prefix(8)) for \(config.host)")
        return session
    }

    /// Whether to use rtach for session persistence
    /// Reads from UserDefaults, defaults to true
    var useRtach: Bool {
        UserDefaults.standard.object(forKey: "sessionManagementEnabled") as? Bool ?? true
    }

    /// Cache of RtachDeployer per connection (for session listing)
    private var rtachDeployers: [String: RtachDeployer] = [:]

    /// UserDefaults key for persisted tabs
    private let persistedTabsKey = "clauntty_persisted_tabs"
    private let persistedWebTabsKey = "clauntty_persisted_web_tabs"
    private let activeTabIdKey = "clauntty_active_tab_id"
    private let tabOrderKey = "clauntty_tab_order"

    /// Cached persisted tabs (loaded once on startup)
    private var persistedTabs: [PersistedTab] = []

    /// Connect SSH and list existing rtach sessions
    /// Returns sessions and deployer, or nil if rtach is disabled or deployment fails
    func connectAndListSessions(for config: SavedConnection) async throws -> (sessions: [RtachSession], deployer: RtachDeployer)? {
        let poolKey = connectionKey(for: config)

        // Get or create SSH connection
        let connection: SSHConnection
        if let existing = connectionPool[poolKey], existing.isConnected {
            Logger.clauntty.debugOnly("SessionManager: reusing existing connection for \(poolKey)")
            connection = existing
        } else {
            Logger.clauntty.debugOnly("SessionManager: creating new connection for \(poolKey)")
            connection = SSHConnection(
                host: config.host,
                port: config.port,
                username: config.username,
                authMethod: config.authMethod,
                connectionId: config.id
            )

            try await connection.connect()
            connectionPool[poolKey] = connection
        }

        guard useRtach else { return nil }

        // Deploy rtach and list sessions
        do {
            let deployer = RtachDeployer(connection: connection)
            Logger.clauntty.debugOnly("SessionManager: ensuring rtach deployed...")
            try await deployer.ensureDeployed()
            rtachDeployers[poolKey] = deployer
            Logger.clauntty.debugOnly("SessionManager: listing sessions...")
            let sessions = try await deployer.listSessions()
            Logger.clauntty.debugOnly("SessionManager: found \(sessions.count) existing sessions")
            return (sessions: sessions, deployer: deployer)
        } catch {
            Logger.clauntty.warning("SessionManager: rtach deployment failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Connect a session with optional rtach session ID
    /// - Parameter rtachSessionId: The rtach session to attach to, or nil for new session
    func connect(session: Session, rtachSessionId: String? = nil) async throws {
        Logger.clauntty.debugOnly("SessionManager.connect called for session \(session.id.uuidString.prefix(8))")
        session.state = .connecting

        let config = session.connectionConfig
        let poolKey = connectionKey(for: config)

        // Create a fresh SSH connection for the terminal session
        // (The connection from connectAndListSessions may be in a bad state after exec commands)
        Logger.clauntty.debugOnly("SessionManager: creating fresh connection for terminal session \(session.id.uuidString.prefix(8))")
        let connection = SSHConnection(
            host: config.host,
            port: config.port,
            username: config.username,
            authMethod: config.authMethod,
            connectionId: config.id
        )
        try await connection.connect()
        Logger.clauntty.debugOnly("SessionManager: SSH connection established for \(session.id.uuidString.prefix(8))")

        // Store this session's connection - don't disconnect other sessions' connections!
        // Each session gets its own SSH connection to avoid killing other sessions' channels
        session.sshConnection = connection

        // Build rtach command - deploy if needed
        var shellCommand: String? = nil
        var usingRtach = false
        if useRtach {
            // Ensure rtach is deployed (may already be cached in rtachDeployers)
            var deployer = rtachDeployers[poolKey]
            if deployer == nil {
                Logger.clauntty.debugOnly("SessionManager: deploying rtach for session \(session.id.uuidString.prefix(8))...")
                let newDeployer = RtachDeployer(connection: connection)
                do {
                    try await newDeployer.ensureDeployed()
                    rtachDeployers[poolKey] = newDeployer
                    deployer = newDeployer
                    Logger.clauntty.debugOnly("SessionManager: rtach deployed successfully")
                } catch {
                    Logger.clauntty.warning("SessionManager: rtach deployment failed: \(error.localizedDescription)")
                }
            }

            if let deployer = deployer {
                // Use session's rtach ID, or generate new UUID for new session
                let sessionId = session.rtachSessionId ?? UUID().uuidString
                // Store back so we can track which rtach session this tab is using
                session.rtachSessionId = sessionId
                shellCommand = deployer.shellCommand(sessionId: sessionId)
                usingRtach = true
                Logger.clauntty.debugOnly("SessionManager: using rtach session: \(sessionId.prefix(8))...")

                // Update last accessed time for this session
                try? await deployer.updateLastAccessed(sessionId: sessionId)
            } else {
                Logger.clauntty.warning("SessionManager: rtach not available, falling back to plain SSH (no session persistence)")
            }
        }

        // Create a new channel for this session with the correct terminal size
        Logger.clauntty.debugOnly("SessionManager: creating channel for \(session.id.uuidString.prefix(8)), command=\(shellCommand ?? "shell"), rtach=\(usingRtach)")
        let (channel, handler) = try await connection.createChannel(
            terminalSize: session.initialTerminalSize,
            command: shellCommand,
            onDataReceived: { [weak session] data in
                Task { @MainActor in
                    session?.handleDataReceived(data)
                }
            },
            onChannelInactive: { [weak session] in
                Task { @MainActor in
                    Logger.clauntty.debugOnly("Session \(session?.id.uuidString.prefix(8) ?? "nil"): channel became inactive, marking disconnected")
                    session?.handleChannelInactive()
                }
            }
        )
        Logger.clauntty.debugOnly("SessionManager: channel created for \(session.id.uuidString.prefix(8))")

        session.attach(channel: channel, handler: handler, connection: connection, expectsRtach: usingRtach)

        // Wire up OSC 777 callbacks for port forwarding
        session.onPortForwardRequested = { [weak self, weak session] port in
            guard let self = self, let session = session else { return }
            self.handlePortForwardRequest(from: session, port: port)
        }
        session.onOpenTabRequested = { [weak self, weak session] port in
            guard let self = self, let session = session else { return }
            self.handleOpenTabRequest(from: session, port: port)
        }

        // Wire up auto-reconnect callback for when send detects nil channel
        session.onNeedsReconnect = { [weak self, weak session] in
            guard let self = self, let session = session else { return }
            // Only auto-reconnect if this is the active session
            guard self.activeTab == .terminal(session.id) else {
                Logger.clauntty.debugOnly("SessionManager: session \(session.id.uuidString.prefix(8)) needs reconnect but is not active, skipping auto-reconnect")
                return
            }
            Logger.clauntty.debugOnly("SessionManager: active session \(session.id.uuidString.prefix(8)) needs reconnect, triggering auto-reconnect")
            Task {
                do {
                    try await self.reconnect(session: session)
                    Logger.clauntty.debugOnly("SessionManager: auto-reconnect succeeded for session \(session.id.uuidString.prefix(8))")
                } catch {
                    Logger.clauntty.error("SessionManager: auto-reconnect failed for session \(session.id.uuidString.prefix(8)): \(error.localizedDescription)")
                }
            }
        }

        Logger.clauntty.debugOnly("SessionManager: session \(session.id.uuidString.prefix(8)) connected and attached")

        // Request notification permission on first session connect
        await NotificationManager.shared.requestAuthorizationIfNeeded()
    }

    /// Reconnect a disconnected session
    /// Uses the session's existing rtach session ID to reattach
    func reconnect(session: Session) async throws {
        guard session.state == .disconnected else {
            Logger.clauntty.debugOnly("SessionManager: session \(session.id.uuidString.prefix(8)) not disconnected, skipping reconnect")
            return
        }

        // Throttle reconnect attempts to prevent crash loops
        if let lastAttempt = lastReconnectAttempt[session.id],
           Date().timeIntervalSince(lastAttempt) < reconnectBackoff {
            Logger.clauntty.debugOnly("SessionManager: throttling reconnect for session \(session.id.uuidString.prefix(8)) (too soon)")
            return
        }
        lastReconnectAttempt[session.id] = Date()

        guard let rtachSessionId = session.rtachSessionId else {
            Logger.clauntty.warning("SessionManager: session \(session.id.uuidString.prefix(8)) has no rtach session ID, cannot reconnect")
            throw SessionError.notConnected
        }

        Logger.clauntty.debugOnly("SessionManager: reconnecting session \(session.id.uuidString.prefix(8)) to rtach session \(rtachSessionId.prefix(8))")

        // Ensure rtach deployer exists for this connection
        let config = session.connectionConfig
        let poolKey = connectionKey(for: config)

        if rtachDeployers[poolKey] == nil {
            // Need to reconnect SSH and redeploy rtach
            let connection = SSHConnection(
                host: config.host,
                port: config.port,
                username: config.username,
                authMethod: config.authMethod,
                connectionId: config.id
            )
            try await connection.connect()
            connectionPool[poolKey] = connection

            let deployer = RtachDeployer(connection: connection)
            try await deployer.ensureDeployed()
            rtachDeployers[poolKey] = deployer
        }

        // Reconnect using existing rtach session ID
        try await connect(session: session, rtachSessionId: rtachSessionId)
    }

    /// Reconnect all disconnected sessions
    /// Called when app returns to foreground after background timeout
    func reconnectDisconnectedSessions() async {
        let disconnectedSessions = sessions.filter { $0.state == .disconnected }

        if disconnectedSessions.isEmpty {
            Logger.clauntty.debugOnly("SessionManager: no disconnected sessions to reconnect")
            return
        }

        Logger.clauntty.debugOnly("SessionManager: reconnecting \(disconnectedSessions.count) disconnected sessions")

        for session in disconnectedSessions {
            do {
                try await reconnect(session: session)
                Logger.clauntty.debugOnly("SessionManager: reconnected session \(session.id.uuidString.prefix(8))")

                // Resume the active session after reconnect (others stay paused for battery)
                if activeTab == .terminal(session.id) {
                    session.resumeOutput()
                    Logger.clauntty.debugOnly("SessionManager: resumed active session \(session.id.uuidString.prefix(8)) after reconnect")
                }
            } catch {
                Logger.clauntty.error("SessionManager: failed to reconnect session \(session.id.uuidString.prefix(8)): \(error.localizedDescription)")
                // Keep session in disconnected state, user can try again
            }
        }
    }

    /// Close a session
    /// - Parameter killRemote: Whether to kill the rtach session on the server (default true)
    func closeSession(_ session: Session, killRemote: Bool = true) {
        Logger.clauntty.debugOnly("SessionManager: closing session \(session.id.uuidString.prefix(8)), killRemote=\(killRemote)")

        // Detach from channel
        session.detach()

        // Kill rtach session on server if requested
        if killRemote, let rtachSessionId = session.rtachSessionId {
            Task {
                await killRtachSession(sessionId: rtachSessionId, config: session.connectionConfig)
            }
        }

        // Remove from persistence
        removePersistedTab(session.id)

        // Remove from sessions list
        sessions.removeAll { $0.id == session.id }

        // Remove from global tab order
        tabOrder.removeAll { $0 == session.id }
        saveTabOrder()

        // If this was the active session, switch to previous or fallback to first
        if activeSessionId == session.id {
            switchToTabAfterClose(closedTab: .terminal(session.id))
        }

        // Clear previousActiveTab if it was the closed session
        if case .terminal(let id) = previousActiveTab, id == session.id {
            previousActiveTab = nil
        }

        // Check if connection should be closed (no more sessions using it)
        cleanupUnusedConnections()
    }

    /// Kill an rtach session on the remote server
    private func killRtachSession(sessionId: String, config: SavedConnection) async {
        let poolKey = connectionKey(for: config)

        // Try to reuse existing connection, or create a new one just for the kill
        let connection: SSHConnection
        if let existing = connectionPool[poolKey], existing.isConnected {
            connection = existing
        } else {
            connection = SSHConnection(
                host: config.host,
                port: config.port,
                username: config.username,
                authMethod: config.authMethod,
                connectionId: config.id
            )
            do {
                try await connection.connect()
            } catch {
                Logger.clauntty.error("SessionManager: failed to connect for session kill: \(error.localizedDescription)")
                return
            }
        }

        let deployer = RtachDeployer(connection: connection)
        do {
            try await deployer.deleteSession(sessionId: sessionId)
            Logger.clauntty.debugOnly("SessionManager: killed rtach session \(sessionId.prefix(8))")
        } catch {
            Logger.clauntty.error("SessionManager: failed to kill rtach session: \(error.localizedDescription)")
        }
    }

    /// Switch to a different session
    /// If the session is disconnected, triggers lazy reconnection
    func switchTo(_ session: Session) {
        let sessionTitle = session.title.prefix(20)
        let sessionId = session.id.uuidString.prefix(8)
        let previousId = activeSession?.id.uuidString.prefix(8) ?? "none"
        let previousTitle = activeSession?.title.prefix(20) ?? "none"

        Logger.clauntty.debugOnly("TAB_TAP: switchTo '\(sessionTitle)' [\(sessionId)] from '\(previousTitle)' [\(previousId)]")

        guard sessions.contains(where: { $0.id == session.id }) else {
            Logger.clauntty.warning("SessionManager: cannot switch to unknown session")
            return
        }
        // Track previous tab for "go back" navigation
        if let current = activeTab, current != .terminal(session.id) {
            previousActiveTab = current
        }

        // Pause the previous active session (battery optimization)
        if let previousSession = activeSession, previousSession.id != session.id {
            Logger.clauntty.debugOnly("TAB_TAP: pausing previous session '\(previousSession.title.prefix(20))'")
            previousSession.pauseOutput()
        }

        activeSessionId = session.id
        Logger.clauntty.debugOnly("TAB_TAP: activeSessionId set to \(sessionId)")

        // If the session is disconnected, trigger lazy reconnect
        if session.state == .disconnected {
            Logger.clauntty.debugOnly("SessionManager: lazy reconnecting session \(session.id.uuidString.prefix(8))")
            Task {
                do {
                    try await reconnect(session: session)
                } catch {
                    Logger.clauntty.error("SessionManager: lazy reconnect failed: \(error.localizedDescription)")
                }
            }
        } else {
            // Already connected - resume output
            session.resumeOutput()
        }
    }

    /// Close all sessions
    func closeAllSessions() {
        Logger.clauntty.debugOnly("SessionManager: closing all sessions")
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
                Logger.clauntty.debugOnly("SessionManager: closing unused connection \(key)")
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

    /// Check if there are any active sessions or web tabs
    var hasSessions: Bool {
        !sessions.isEmpty || !webTabs.isEmpty
    }

    /// Check if there are only terminal sessions (no web tabs)
    var hasOnlyTerminals: Bool {
        !sessions.isEmpty && webTabs.isEmpty
    }

    // MARK: - Web Tab Management

    /// Scan for listening ports on a connection
    func scanPorts(for config: SavedConnection) async throws -> [RemotePort] {
        let poolKey = connectionKey(for: config)

        guard let connection = connectionPool[poolKey], connection.isConnected else {
            throw SessionError.notConnected
        }

        let scanner = PortScanner(connection: connection)
        return try await scanner.listListeningPorts()
    }

    /// Create a web tab for a remote port
    /// - Parameters:
    ///   - port: The remote port to forward
    ///   - config: Connection configuration
    ///   - makeActive: Whether to switch to this tab (default true)
    func createWebTab(for port: RemotePort, config: SavedConnection, makeActive: Bool = true) async throws -> WebTab {
        let poolKey = connectionKey(for: config)

        // Get or create connection
        let connection: SSHConnection
        if let existing = connectionPool[poolKey], existing.isConnected {
            connection = existing
        } else {
            connection = SSHConnection(
                host: config.host,
                port: config.port,
                username: config.username,
                authMethod: config.authMethod,
                connectionId: config.id
            )
            try await connection.connect()
            connectionPool[poolKey] = connection
        }

        let webTab = WebTab(remotePort: port, connectionConfig: config, sshConnection: connection)
        webTabs.append(webTab)

        // Add to global tab order
        tabOrder.append(webTab.id)
        saveTabOrder()

        // Start port forwarding
        try await webTab.startForwarding()

        // Make it active if requested
        if makeActive {
            activeTab = .web(webTab.id)
        }

        // Persist web tabs
        saveWebTabPersistence()

        Logger.clauntty.debugOnly("SessionManager: created web tab for port \(port.port)")
        return webTab
    }

    /// Close a web tab
    func closeWebTab(_ webTab: WebTab) {
        Logger.clauntty.debugOnly("SessionManager: closing web tab for port \(webTab.remotePort.port)")

        Task {
            await webTab.close()
        }

        webTabs.removeAll { $0.id == webTab.id }

        // Remove from global tab order
        tabOrder.removeAll { $0 == webTab.id }
        saveTabOrder()

        // If this was active, switch to previous or fallback
        if case .web(let id) = activeTab, id == webTab.id {
            switchToTabAfterClose(closedTab: .web(webTab.id))
        }

        // Clear previousActiveTab if it was the closed web tab
        if case .web(let id) = previousActiveTab, id == webTab.id {
            previousActiveTab = nil
        }

        // Persist web tabs
        saveWebTabPersistence()

        cleanupUnusedConnections()
    }

    /// Switch to a web tab
    func switchTo(_ webTab: WebTab) {
        guard webTabs.contains(where: { $0.id == webTab.id }) else {
            Logger.clauntty.warning("SessionManager: cannot switch to unknown web tab")
            return
        }
        // Track previous tab for "go back" navigation
        if let current = activeTab, current != .web(webTab.id) {
            previousActiveTab = current
        }
        activeTab = .web(webTab.id)

        // If the web tab is closed/disconnected, reconnect
        if webTab.state == .closed {
            Logger.clauntty.debugOnly("SessionManager: web tab is closed, reconnecting...")
            Task {
                do {
                    try await reconnectWebTab(webTab)
                } catch {
                    Logger.clauntty.error("SessionManager: failed to reconnect web tab: \(error.localizedDescription)")
                }
            }
        }

        Logger.clauntty.debugOnly("SessionManager: switched to web tab \(webTab.id.uuidString.prefix(8))")
    }

    /// Reconnect a web tab (establish SSH connection and start port forwarding)
    func reconnectWebTab(_ webTab: WebTab) async throws {
        let config = webTab.connectionConfig
        let poolKey = connectionKey(for: config)

        Logger.clauntty.debugOnly("SessionManager: reconnecting web tab for port \(webTab.remotePort.port)")

        // Get or create connection
        let connection: SSHConnection
        if let existing = connectionPool[poolKey], existing.isConnected {
            Logger.clauntty.debugOnly("SessionManager: reusing existing connection for web tab")
            connection = existing
        } else {
            Logger.clauntty.debugOnly("SessionManager: creating new connection for web tab")
            connection = SSHConnection(
                host: config.host,
                port: config.port,
                username: config.username,
                authMethod: config.authMethod,
                connectionId: config.id
            )
            try await connection.connect()
            connectionPool[poolKey] = connection
        }

        // Reconnect the web tab with this connection
        try await webTab.reconnect(with: connection)

        Logger.clauntty.debugOnly("SessionManager: web tab reconnected successfully")
    }

    /// Check if a port is already open in a web tab
    func webTabForPort(_ port: Int, config: SavedConnection) -> WebTab? {
        let poolKey = connectionKey(for: config)
        return webTabs.first { tab in
            tab.remotePort.port == port &&
            tab.sshConnection != nil &&
            connectionKey(for: tab.sshConnection!.host, tab.sshConnection!.port, tab.sshConnection!.username) == poolKey
        }
    }

    private func connectionKey(for host: String, _ port: Int, _ username: String) -> String {
        return "\(username)@\(host):\(port)"
    }

    /// Get session by ID
    func session(id: UUID) -> Session? {
        sessions.first { $0.id == id }
    }

    /// Check if an rtach session is already open in a tab
    /// Returns the Session if open, nil otherwise
    func sessionForRtach(_ rtachSessionId: String) -> Session? {
        sessions.first { $0.rtachSessionId == rtachSessionId }
    }

    // MARK: - Tab Reordering

    /// Move a terminal session to a new index
    func moveSession(from source: IndexSet, to destination: Int) {
        sessions.move(fromOffsets: source, toOffset: destination)
        Logger.clauntty.debugOnly("SessionManager: reordered sessions")
    }

    /// Move a terminal session by ID to a new index
    func moveSession(id: UUID, toIndex destination: Int) {
        guard let sourceIndex = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: sourceIndex)
        let adjustedDestination = destination > sourceIndex ? destination - 1 : destination
        sessions.insert(session, at: min(adjustedDestination, sessions.count))
        Logger.clauntty.debugOnly("SessionManager: moved session to index \(adjustedDestination)")
    }

    /// Move a web tab to a new index
    func moveWebTab(from source: IndexSet, to destination: Int) {
        webTabs.move(fromOffsets: source, toOffset: destination)
        Logger.clauntty.debugOnly("SessionManager: reordered web tabs")
    }

    /// Move a web tab by ID to a new index
    func moveWebTab(id: UUID, toIndex destination: Int) {
        guard let sourceIndex = webTabs.firstIndex(where: { $0.id == id }) else { return }
        let webTab = webTabs.remove(at: sourceIndex)
        let adjustedDestination = destination > sourceIndex ? destination - 1 : destination
        webTabs.insert(webTab, at: min(adjustedDestination, webTabs.count))
        Logger.clauntty.debugOnly("SessionManager: moved web tab to index \(adjustedDestination)")
    }

    // MARK: - Global Tab Ordering

    /// Get all tabs in global display order
    /// Returns tabs in the order specified by tabOrder, with any unordered tabs appended at the end
    func orderedTabs() -> [TabItem] {
        var result: [TabItem] = []
        var orderedIds = Set<UUID>()

        // First, add tabs in the specified order
        for id in tabOrder {
            if let session = sessions.first(where: { $0.id == id }) {
                result.append(.terminal(session))
                orderedIds.insert(id)
            } else if let webTab = webTabs.first(where: { $0.id == id }) {
                result.append(.web(webTab))
                orderedIds.insert(id)
            }
            // Skip IDs that no longer exist
        }

        // Append any tabs not in the order (newly created)
        for session in sessions where !orderedIds.contains(session.id) {
            result.append(.terminal(session))
        }
        for webTab in webTabs where !orderedIds.contains(webTab.id) {
            result.append(.web(webTab))
        }

        return result
    }

    /// Move a tab from one global index to another
    /// Handles both terminal and web tabs in a unified order
    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex >= 0, sourceIndex < tabOrder.count else { return }
        guard sourceIndex != destinationIndex else { return }  // No-op if same position

        let movedId = tabOrder.remove(at: sourceIndex)
        // Insert at destination index (clamped to valid range)
        // No adjustment needed - destinationIndex is where we want the item to end up
        let insertIndex = min(max(destinationIndex, 0), tabOrder.count)
        tabOrder.insert(movedId, at: insertIndex)

        saveTabOrder()
        Logger.clauntty.debugOnly("SessionManager: moved tab from index \(sourceIndex) to \(insertIndex)")
    }

    /// Move a tab by ID to a specific global index
    func moveTab(id: UUID, toGlobalIndex destination: Int) {
        // Ensure tabOrder is complete before moving
        ensureTabOrderComplete()

        guard let sourceIndex = tabOrder.firstIndex(of: id) else {
            Logger.clauntty.warning("SessionManager: tab \(id) not found in tabOrder after sync")
            return
        }

        moveTab(from: sourceIndex, to: destination)
    }

    /// Move a tab to the end of the order
    func moveTabToEnd(id: UUID) {
        // Ensure tabOrder is complete before moving
        ensureTabOrderComplete()

        // Remove from current position (if present)
        tabOrder.removeAll { $0 == id }
        // Append to end
        tabOrder.append(id)
        saveTabOrder()
        Logger.clauntty.debugOnly("SessionManager: moved tab to end")
    }

    /// Ensure tabOrder contains all current tabs (rebuilds if incomplete)
    private func ensureTabOrderComplete() {
        let allIds = Set(sessions.map { $0.id } + webTabs.map { $0.id })
        let orderedIds = Set(tabOrder)

        // Check if tabOrder is missing any tabs
        let missingIds = allIds.subtracting(orderedIds)
        if !missingIds.isEmpty {
            Logger.clauntty.debugOnly("SessionManager: tabOrder missing \(missingIds.count) tabs, rebuilding")
            // Append missing tabs (preserves existing order)
            for session in sessions where missingIds.contains(session.id) {
                tabOrder.append(session.id)
            }
            for webTab in webTabs where missingIds.contains(webTab.id) {
                tabOrder.append(webTab.id)
            }
            saveTabOrder()
        }

        // Also remove any stale IDs that no longer exist
        let staleIds = orderedIds.subtracting(allIds)
        if !staleIds.isEmpty {
            tabOrder.removeAll { staleIds.contains($0) }
            saveTabOrder()
        }
    }

    /// Save tab order to UserDefaults
    func saveTabOrder() {
        let orderStrings = tabOrder.map { $0.uuidString }
        UserDefaults.standard.set(orderStrings, forKey: tabOrderKey)
        Logger.clauntty.debugOnly("SessionManager: saved tab order with \(tabOrder.count) tabs")
    }

    /// Load tab order from UserDefaults
    func loadTabOrder() {
        guard let orderStrings = UserDefaults.standard.stringArray(forKey: tabOrderKey) else {
            Logger.clauntty.debugOnly("SessionManager: no saved tab order found, will migrate from existing tabs")
            migrateToGlobalTabOrder()
            return
        }
        tabOrder = orderStrings.compactMap { UUID(uuidString: $0) }
        Logger.clauntty.debugOnly("SessionManager: loaded tab order with \(self.tabOrder.count) tabs")
    }

    /// Migrate from per-type ordering to global tab order
    /// Called when no tabOrder exists but we have tabs (first launch after update)
    private func migrateToGlobalTabOrder() {
        // Only migrate if we have tabs
        guard !sessions.isEmpty || !webTabs.isEmpty else { return }

        Logger.clauntty.debugOnly("SessionManager: migrating to global tab order")

        // Build initial order: terminals first (in their array order), then web tabs
        tabOrder = sessions.map { $0.id } + webTabs.map { $0.id }

        saveTabOrder()
        Logger.clauntty.debugOnly("SessionManager: migrated \(self.tabOrder.count) tabs to global order")
    }

    // MARK: - Tab Navigation

    // MARK: - OSC 777 Port Forwarding

    /// Handle a port forward request from a session (triggered by OSC 777;forward;PORT)
    func handlePortForwardRequest(from session: Session, port: Int) {
        let config = session.connectionConfig
        let remotePort = RemotePort(id: port, port: port, process: nil, address: "127.0.0.1")

        Task {
            do {
                try await startForwarding(port: remotePort, config: config)
                Logger.clauntty.debugOnly("SessionManager: forwarded port \(port) via OSC 777")
            } catch {
                Logger.clauntty.error("SessionManager: failed to forward port \(port): \(error)")
            }
        }
    }

    /// Handle an open tab request from a session (triggered by OSC 777;open;PORT)
    /// Opens the tab in background without switching to it
    func handleOpenTabRequest(from session: Session, port: Int) {
        let config = session.connectionConfig
        let remotePort = RemotePort(id: port, port: port, process: nil, address: "127.0.0.1")

        Task {
            do {
                // Check if already open - just log and return, don't switch
                if webTabForPort(port, config: config) != nil {
                    Logger.clauntty.debugOnly("SessionManager: web tab for port \(port) already exists")
                    return
                }

                // Create new web tab in background (don't switch to it)
                _ = try await createWebTab(for: remotePort, config: config, makeActive: false)
                Logger.clauntty.debugOnly("SessionManager: opened web tab for port \(port) via OSC 777 (background)")
            } catch {
                Logger.clauntty.error("SessionManager: failed to open tab for port \(port): \(error)")
            }
        }
    }

    /// Switch to an appropriate tab after closing one
    /// Prefers previousActiveTab if valid, otherwise falls back to first available
    private func switchToTabAfterClose(closedTab: ActiveTab) {
        // Try to switch to previous tab if it exists and is not the closed tab
        if let previous = previousActiveTab, previous != closedTab {
            switch previous {
            case .terminal(let id):
                if let session = sessions.first(where: { $0.id == id }) {
                    activeTab = .terminal(session.id)
                    session.resumeOutput()
                    return
                }
            case .web(let id):
                if webTabs.contains(where: { $0.id == id }) {
                    activeTab = .web(id)
                    return
                }
            }
        }

        // Fallback: switch to first available tab
        if let firstSession = sessions.first {
            activeTab = .terminal(firstSession.id)
        } else if let firstWebTab = webTabs.first {
            activeTab = .web(firstWebTab.id)
        } else {
            activeTab = nil
        }
    }

    /// Switch to the previous tab (for "go back" gesture)
    func switchToPreviousTab() {
        guard let previous = previousActiveTab else {
            Logger.clauntty.debugOnly("SessionManager: no previous tab to switch to")
            return
        }

        // Verify the tab still exists
        switch previous {
        case .terminal(let id):
            if let session = sessions.first(where: { $0.id == id }) {
                switchTo(session)
            }
        case .web(let id):
            if let webTab = webTabs.first(where: { $0.id == id }) {
                switchTo(webTab)
            }
        }
    }

    /// Find and switch to the next terminal session that is waiting for input
    /// Returns true if a tab was found and switched to
    @discardableResult
    func switchToNextWaitingTab() -> Bool {
        // Get sessions waiting for input, excluding the current one
        let waitingSessions = sessions.filter { session in
            session.isWaitingForInput && activeTab != .terminal(session.id)
        }

        if let nextSession = waitingSessions.first {
            switchTo(nextSession)
            Logger.clauntty.debugOnly("SessionManager: switched to waiting session \(nextSession.id.uuidString.prefix(8))")
            return true
        }

        Logger.clauntty.debugOnly("SessionManager: no tabs waiting for input")
        return false
    }

    /// Get the next terminal session waiting for input without switching
    /// Used for interactive swipe preview
    func nextWaitingTab() -> ActiveTab? {
        let waitingSessions = sessions.filter { session in
            session.isWaitingForInput && activeTab != .terminal(session.id)
        }

        if let nextSession = waitingSessions.first {
            return .terminal(nextSession.id)
        }
        return nil
    }

    // MARK: - Background Port Forwarding

    /// Start forwarding a port without opening a web tab
    func startForwarding(port: RemotePort, config: SavedConnection) async throws {
        let poolKey = connectionKey(for: config)

        // Check if already forwarded
        if isPortForwarded(port.port, config: config) {
            Logger.clauntty.debugOnly("SessionManager: port \(port.port) already forwarded")
            return
        }

        // Get or create connection
        let connection: SSHConnection
        if let existing = connectionPool[poolKey], existing.isConnected {
            connection = existing
        } else {
            connection = SSHConnection(
                host: config.host,
                port: config.port,
                username: config.username,
                authMethod: config.authMethod,
                connectionId: config.id
            )
            try await connection.connect()
            connectionPool[poolKey] = connection
        }

        // Create forwarded port
        let forwardedPort = ForwardedPort(
            remotePort: port,
            connectionConfig: config,
            sshConnection: connection
        )

        // Start forwarding
        try await forwardedPort.startForwarding()

        forwardedPorts.append(forwardedPort)
        Logger.clauntty.debugOnly("SessionManager: started forwarding port \(port.port) -> localhost:\(forwardedPort.localPort)")
    }

    /// Stop forwarding a port
    func stopForwarding(port: RemotePort, config: SavedConnection) {
        let poolKey = connectionKey(for: config)

        // Find and remove the forwarded port
        if let index = forwardedPorts.firstIndex(where: {
            $0.remotePort.port == port.port &&
            connectionKey(for: $0.connectionConfig) == poolKey
        }) {
            let forwarded = forwardedPorts.remove(at: index)
            Task {
                await forwarded.stopForwarding()
            }
            Logger.clauntty.debugOnly("SessionManager: stopped forwarding port \(port.port)")
        }

        // Also close any web tab using this port
        if let webTab = webTabForPort(port.port, config: config) {
            closeWebTab(webTab)
        }

        cleanupUnusedConnections()
    }

    /// Check if a port is being forwarded (either background or via web tab)
    func isPortForwarded(_ port: Int, config: SavedConnection) -> Bool {
        let poolKey = connectionKey(for: config)

        // Check background forwarded ports
        let isBackgroundForwarded = forwardedPorts.contains {
            $0.remotePort.port == port &&
            connectionKey(for: $0.connectionConfig) == poolKey
        }

        // Check web tabs (which also have port forwarding)
        let hasWebTab = webTabForPort(port, config: config) != nil

        return isBackgroundForwarded || hasWebTab
    }

    /// Get a forwarded port by port number and config
    func forwardedPort(_ port: Int, config: SavedConnection) -> ForwardedPort? {
        let poolKey = connectionKey(for: config)
        return forwardedPorts.first {
            $0.remotePort.port == port &&
            connectionKey(for: $0.connectionConfig) == poolKey
        }
    }

    // MARK: - Tab Persistence

    /// Save current tabs to UserDefaults
    func savePersistence() {
        var tabs: [PersistedTab] = []

        for (index, session) in sessions.enumerated() {
            guard let rtachId = session.rtachSessionId else { continue }

            let tab = PersistedTab(
                id: session.id,
                connectionId: session.connectionConfig.id,
                rtachSessionId: rtachId,
                createdAt: session.createdAt,
                lastActiveAt: Date(),
                cachedTitle: session.title,
                cachedDynamicTitle: session.dynamicTitle,
                orderIndex: index,
                fontSize: session.fontSize
            )
            tabs.append(tab)
        }

        do {
            let data = try JSONEncoder().encode(tabs)
            UserDefaults.standard.set(data, forKey: persistedTabsKey)

            // Also persist the active tab ID
            if case .terminal(let id) = activeTab {
                UserDefaults.standard.set(id.uuidString, forKey: activeTabIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeTabIdKey)
            }

            Logger.clauntty.debugOnly("SessionManager: persisted \(tabs.count) tabs")
        } catch {
            Logger.clauntty.error("SessionManager: failed to persist tabs: \(error.localizedDescription)")
        }
    }

    /// Load persisted tabs (call on app launch)
    /// Creates Session objects in disconnected state
    func loadPersistedTabs(connectionStore: ConnectionStore) {
        guard let data = UserDefaults.standard.data(forKey: persistedTabsKey) else {
            Logger.clauntty.debugOnly("SessionManager: no persisted tabs found")
            return
        }

        do {
            persistedTabs = try JSONDecoder().decode([PersistedTab].self, from: data)

            // Sort by order index to preserve tab order
            persistedTabs.sort { $0.orderIndex < $1.orderIndex }

            // Create Session objects in disconnected state
            for persisted in persistedTabs {
                guard let config = connectionStore.connections.first(where: { $0.id == persisted.connectionId }) else {
                    Logger.clauntty.warning("SessionManager: connection not found for persisted tab \(persisted.id.uuidString.prefix(8))")
                    continue
                }

                let session = Session(connectionConfig: config, id: persisted.id, createdAt: persisted.createdAt)
                session.rtachSessionId = persisted.rtachSessionId
                session.dynamicTitle = persisted.cachedDynamicTitle
                session.fontSize = persisted.fontSize
                // Note: state is already .disconnected by default

                // Set up state change callback
                session.onStateChange = { [weak self] in
                    self?.sessionStateVersion += 1
                }

                self.sessions.append(session)
            }

            // Restore the previously active tab, or fall back to first session
            if let activeIdString = UserDefaults.standard.string(forKey: activeTabIdKey),
               let activeId = UUID(uuidString: activeIdString),
               self.sessions.contains(where: { $0.id == activeId }) {
                self.activeTab = .terminal(activeId)
                Logger.clauntty.debugOnly("SessionManager: restored active tab \(activeIdString.prefix(8))")
            } else if let first = self.sessions.first {
                self.activeTab = .terminal(first.id)
            }

            Logger.clauntty.debugOnly("SessionManager: loaded \(self.sessions.count) persisted tabs")
        } catch {
            Logger.clauntty.error("SessionManager: failed to load persisted tabs: \(error.localizedDescription)")
        }
    }

    /// Remove a single tab from persistence
    private func removePersistedTab(_ id: UUID) {
        persistedTabs.removeAll { $0.id == id }
        savePersistence()
    }

    // MARK: - Web Tab Persistence

    /// Save web tabs to UserDefaults
    func saveWebTabPersistence() {
        var tabs: [PersistedWebTab] = []

        for (index, webTab) in webTabs.enumerated() {
            // Update last path before saving
            webTab.updateLastPath()

            let tab = PersistedWebTab(
                id: webTab.id,
                connectionId: webTab.connectionConfig.id,
                remotePort: webTab.remotePort.port,
                remotePortProcess: webTab.remotePort.process,
                remotePortAddress: webTab.remotePort.address,
                createdAt: webTab.createdAt,
                lastActiveAt: Date(),
                cachedPageTitle: webTab.pageTitle,
                lastPath: webTab.lastPath,
                orderIndex: index
            )
            tabs.append(tab)
        }

        do {
            let data = try JSONEncoder().encode(tabs)
            UserDefaults.standard.set(data, forKey: persistedWebTabsKey)
            Logger.clauntty.debugOnly("SessionManager: persisted \(tabs.count) web tabs")
        } catch {
            Logger.clauntty.error("SessionManager: failed to persist web tabs: \(error.localizedDescription)")
        }
    }

    /// Load persisted web tabs (call on app launch)
    /// Creates WebTab objects in closed state - they reconnect on demand
    func loadPersistedWebTabs(connectionStore: ConnectionStore) {
        guard let data = UserDefaults.standard.data(forKey: persistedWebTabsKey) else {
            Logger.clauntty.debugOnly("SessionManager: no persisted web tabs found")
            return
        }

        do {
            var persistedWebTabs = try JSONDecoder().decode([PersistedWebTab].self, from: data)

            // Sort by order index to preserve tab order
            persistedWebTabs.sort { $0.orderIndex < $1.orderIndex }

            // Create WebTab objects in closed state
            for persisted in persistedWebTabs {
                guard let config = connectionStore.connections.first(where: { $0.id == persisted.connectionId }) else {
                    Logger.clauntty.warning("SessionManager: connection not found for persisted web tab \(persisted.id.uuidString.prefix(8))")
                    continue
                }

                // Reconstruct RemotePort
                let remotePort = RemotePort(
                    id: persisted.remotePort,
                    port: persisted.remotePort,
                    process: persisted.remotePortProcess,
                    address: persisted.remotePortAddress
                )

                // Create WebTab from persisted state
                let webTab = WebTab(
                    id: persisted.id,
                    remotePort: remotePort,
                    connectionConfig: config,
                    createdAt: persisted.createdAt,
                    lastPath: persisted.lastPath,
                    cachedPageTitle: persisted.cachedPageTitle
                )

                self.webTabs.append(webTab)
            }

            Logger.clauntty.debugOnly("SessionManager: loaded \(self.webTabs.count) persisted web tabs")
        } catch {
            Logger.clauntty.error("SessionManager: failed to load persisted web tabs: \(error.localizedDescription)")
        }
    }

    // MARK: - Session Sync with Server

    /// Sync local tabs with server sessions
    /// - Marks missing sessions as remotely deleted
    /// - Auto-creates tabs for sessions not in local persistence
    func syncSessionsWithServer(config: SavedConnection, deployer: RtachDeployer) async {
        do {
            let serverSessions = try await deployer.listSessions()
            let serverSessionIds = Set(serverSessions.map { $0.id })

            // Get local rtach IDs for this connection
            let localSessions = sessions.filter { $0.connectionConfig.id == config.id }
            let localRtachIds = Set(localSessions.compactMap { $0.rtachSessionId })

            // 1. Mark missing sessions as remotely deleted
            for session in localSessions {
                if let rtachId = session.rtachSessionId, !serverSessionIds.contains(rtachId) {
                    session.state = .remotelyDeleted
                    session.remoteClosureReason = "Session no longer exists on server"
                    Logger.clauntty.debugOnly("SessionManager: marked session \(session.id.uuidString.prefix(8)) as remotely deleted")
                }
            }

            // 2. Auto-create tabs for sessions not in local persistence
            for serverSession in serverSessions where !localRtachIds.contains(serverSession.id) {
                // Check if this rtach session exists under a DIFFERENT connection (e.g., IP vs DNS for same host)
                if let existingSession = sessionForRtach(serverSession.id) {
                    // Update existing session to use the new connection
                    existingSession.connectionConfig = config
                    Logger.clauntty.debugOnly("SessionManager: updated connection for existing rtach session \(serverSession.id.prefix(8)) from different host")
                    continue
                }

                let session = Session(connectionConfig: config)
                session.rtachSessionId = serverSession.id
                session.dynamicTitle = serverSession.title
                session.state = .disconnected

                // Set up state change callback
                session.onStateChange = { [weak self] in
                    self?.sessionStateVersion += 1
                }

                sessions.append(session)
                tabOrder.append(session.id)  // Add to global tab order
                Logger.clauntty.debugOnly("SessionManager: auto-created tab for remote session \(serverSession.id.prefix(8))")
            }

            savePersistence()
            saveTabOrder()
        } catch {
            Logger.clauntty.error("SessionManager: failed to sync sessions with server: \(error.localizedDescription)")
        }
    }
}

// MARK: - ForwardedPort

/// A port being forwarded in the background (without a web tab)
@MainActor
class ForwardedPort: Identifiable, ObservableObject {
    let id: UUID
    let remotePort: RemotePort
    @Published var localPort: Int
    let connectionConfig: SavedConnection

    private var portForwarder: PortForwardingManager?
    weak var sshConnection: SSHConnection?

    init(remotePort: RemotePort, connectionConfig: SavedConnection, sshConnection: SSHConnection) {
        self.id = UUID()
        self.remotePort = remotePort
        self.localPort = remotePort.port
        self.connectionConfig = connectionConfig
        self.sshConnection = sshConnection
    }

    /// Start port forwarding
    func startForwarding() async throws {
        guard let connection = sshConnection,
              let channel = connection.nioChannel else {
            throw ForwardedPortError.noConnection
        }
        let eventLoop = connection.nioEventLoopGroup

        Logger.clauntty.debugOnly("ForwardedPort: starting forwarding for port \(self.remotePort.port)")

        let forwarder = PortForwardingManager(
            localPort: remotePort.port,
            remoteHost: "127.0.0.1",
            remotePort: remotePort.port,
            eventLoopGroup: eventLoop,
            sshChannel: channel
        )

        let actualPort = try await forwarder.start()
        self.localPort = actualPort
        self.portForwarder = forwarder

        Logger.clauntty.debugOnly("ForwardedPort: forwarding started on localhost:\(actualPort)")
    }

    /// Stop port forwarding
    func stopForwarding() async {
        if let forwarder = portForwarder {
            try? await forwarder.stop()
            portForwarder = nil
            Logger.clauntty.debugOnly("ForwardedPort: stopped forwarding for port \(self.remotePort.port)")
        }
    }
}

enum ForwardedPortError: Error, LocalizedError {
    case noConnection

    var errorDescription: String? {
        switch self {
        case .noConnection:
            return "SSH connection not available"
        }
    }
}

// MARK: - Errors

enum SessionError: Error, LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "SSH connection not established"
        }
    }
}
