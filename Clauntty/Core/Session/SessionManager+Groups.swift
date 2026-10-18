import CryptoKit
import Foundation
import os.log

/// Several panes on a machine shown as one Clauntty tab, one pane at a time. Each pane
/// is an rtach session; the tab keeps a Session for each pane it has shown.
///
/// Groups come from rtach workspaces (`rtach ws`): every workspace on a connected host
/// is a tab, unless the user closed it on this phone.
struct SessionGroup: Identifiable, Equatable {
    let id: UUID
    let connectionId: UUID
    /// The rtach workspace this tab shows
    let workspaceId: String
    var title: String
    /// In display order: tabs in order, then panes in layout order
    var panes: [TabPane]
    /// The pane the tab shows
    var activePaneId: String
    /// Panes shown before, newest first
    var recentPaneIds: [String] = []
}

/// A workspace tab saved across launches, so it's back before its host is reached
struct PersistedGroup: Codable {
    let id: UUID
    let connectionId: UUID
    let workspaceId: String
    let title: String
    let panes: [Pane]
    let activePaneId: String

    struct Pane: Codable {
        let id: String
        let title: String
        let tab: Int
    }
}

extension SessionManager {
    // MARK: Lookup

    /// The session showing a group's current pane
    func currentSession(of group: SessionGroup) -> Session? {
        sessions.first { $0.groupId == group.id && $0.pane?.paneId == group.activePaneId }
    }

    func sessionGroup(for session: Session) -> SessionGroup? {
        guard let id = session.groupId else { return nil }
        return sessionGroups.first { $0.id == id }
    }

    /// The panes of a session's group, and the index of the one shown
    func panes(for session: Session) -> (panes: [TabPane], activeIndex: Int)? {
        guard let group = sessionGroup(for: session) else { return nil }
        let index = group.panes.firstIndex { $0.id == group.activePaneId } ?? 0
        return (group.panes, index)
    }

    /// The session for a pane, created disconnected if needed. It connects when shown.
    @discardableResult
    private func paneSession(for group: SessionGroup, paneId: String, config: SavedConnection) -> Session? {
        if let existing = sessions.first(where: { $0.groupId == group.id && $0.pane?.paneId == paneId }) {
            return existing
        }
        guard group.panes.contains(where: { $0.id == paneId }) else { return nil }

        // A stable id, so the active tab and thumbnails survive a relaunch
        let session = Session(connectionConfig: config, id: Self.stableId("\(group.id)/\(paneId)"), groupId: group.id)
        session.pane = PaneRef(paneId: paneId, groupTitle: group.title)
        // A pane is an rtach session, named by its id
        session.rtachSessionId = paneId
        session.state = .disconnected
        session.onStateChange = { [weak self] in
            self?.sessionStateVersion += 1
        }
        sessions.append(session)
        return session
    }

    /// A UUID derived from a string
    static func stableId(_ key: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(key.utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    // MARK: Switching panes

    /// Show another pane in a group's tab
    func selectPane(groupId: UUID, paneId: String) {
        guard let index = sessionGroups.firstIndex(where: { $0.id == groupId }) else { return }
        var group = sessionGroups[index]
        guard group.activePaneId != paneId, let config = currentSession(of: group)?.connectionConfig else { return }

        let groupIsActive = activeSession?.groupId == groupId
        group.recentPaneIds.removeAll { $0 == paneId || $0 == group.activePaneId }
        group.recentPaneIds.insert(group.activePaneId, at: 0)
        group.activePaneId = paneId
        sessionGroups[index] = group
        saveGroups()

        guard let session = paneSession(for: group, paneId: paneId, config: config) else { return }
        if groupIsActive {
            switchTo(session)
        }
    }

    // MARK: Closing

    /// The user closed a group's tab: detach its panes and stop showing the workspace on
    /// this phone. The panes keep running on the machine.
    func closeSessionGroup(_ groupId: UUID) {
        if let group = sessionGroups.first(where: { $0.id == groupId }) {
            hiddenWorkspaces.insert(Self.workspaceKey(group.connectionId, group.workspaceId))
        }
        removeSessionGroup(groupId)
    }

    /// Take a group's tab away (its workspace closed, or the user hid it)
    private func removeSessionGroup(_ groupId: UUID) {
        sessionGroups.removeAll { $0.id == groupId }
        tabOrder.removeAll { $0 == groupId }
        saveTabOrder()
        saveGroups()
        for session in sessions.filter({ $0.groupId == groupId }) {
            closeSession(session, killRemote: false)
        }
    }

    // MARK: Workspaces from the host

    static func workspaceKey(_ connectionId: UUID, _ workspaceId: String) -> String {
        "\(connectionId.uuidString)/\(workspaceId)"
    }

    /// Workspaces closed on this phone. They stay running and can be opened again from
    /// the server list.
    var hiddenWorkspaces: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "clauntty_hidden_workspaces") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "clauntty_hidden_workspaces") }
    }

    /// Workspaces on a host that aren't shown as tabs here
    func hiddenWorkspaces(for config: SavedConnection) -> [RemoteWorkspace] {
        let shown = Set(sessionGroups.filter { $0.connectionId == config.id }.map(\.workspaceId))
        return (knownWorkspaces[config.id] ?? []).filter { !shown.contains($0.id) }
    }

    /// Fetch a host's workspaces and update their tabs
    func refreshWorkspaces(for config: SavedConnection) async {
        do {
            let result = try await withHost(config) { connection in
                try await RtachDeployer(connection: connection).listWorkspaces()
            }
            applyWorkspaces(result.workspaces, hostName: result.hostName, config: config)
        } catch {
            Logger.clauntty.warning("SessionManager: can't list workspaces on \(config.displayName): \(error.localizedDescription)")
        }
    }

    /// Refresh every host with a tab open (the app came to the foreground)
    func refreshAllWorkspaces() async {
        var seen = Set<UUID>()
        let configs = sessions.map(\.connectionConfig).filter { seen.insert($0.id).inserted }
        for config in configs where rtachDeployers[connectionKey(for: config)] != nil {
            await refreshWorkspaces(for: config)
        }
    }

    /// Make the group tabs match a host's workspaces
    func applyWorkspaces(_ workspaces: [RemoteWorkspace], hostName: String?, config: SavedConnection) {
        knownWorkspaces[config.id] = workspaces
        workspacePaneIds[config.id] = Set(workspaces.flatMap { $0.tabs.flatMap { $0.panes.map(\.id) } })
        let hidden = hiddenWorkspaces
        var shown = Set<UUID>()

        for workspace in workspaces where !hidden.contains(Self.workspaceKey(config.id, workspace.id)) {
            let panes = workspace.tabs.enumerated().flatMap { tabIndex, tab in
                tab.panes.map { pane in
                    TabPane(id: pane.id, title: pane.title.flatMap { $0.isEmpty ? nil : $0 } ?? "shell", status: .none, group: tabIndex)
                }
            }
            guard !panes.isEmpty else { continue }
            // Named by the machine, so two saved connections to it show the workspace once
            let groupId = Self.stableId("\(hostName ?? config.id.uuidString)/\(workspace.id)")
            if let existing = sessionGroups.first(where: { $0.id == groupId }), existing.connectionId != config.id {
                continue
            }
            shown.insert(groupId)
            updateGroup(id: groupId, workspace: workspace, panes: panes, config: config)
        }

        for group in sessionGroups where group.connectionId == config.id && !shown.contains(group.id) {
            removeSessionGroup(group.id)
        }
        saveGroups()
        saveTabOrder()
    }

    private func updateGroup(id groupId: UUID, workspace: RemoteWorkspace, panes: [TabPane], config: SavedConnection) {
        let paneIds = Set(panes.map(\.id))
        var group: SessionGroup
        if let index = sessionGroups.firstIndex(where: { $0.id == groupId }) {
            group = sessionGroups[index]
            group.title = workspace.name
            group.panes = panes
            group.recentPaneIds.removeAll { !paneIds.contains($0) }
            if !paneIds.contains(group.activePaneId) {
                group.activePaneId = group.recentPaneIds.first ?? panes[0].id
            }
            sessionGroups[index] = group
        } else {
            group = SessionGroup(id: groupId, connectionId: config.id, workspaceId: workspace.id,
                                 title: workspace.name, panes: panes, activePaneId: panes[0].id)
            sessionGroups.append(group)
            if !tabOrder.contains(groupId) {
                tabOrder.append(groupId)
            }
        }

        let current = paneSession(for: group, paneId: group.activePaneId, config: config)
        for session in sessions where session.groupId == groupId {
            session.pane?.groupTitle = group.title
        }
        // Panes gone from the workspace: show the current one before closing them
        let gone = sessions.filter { $0.groupId == groupId && !paneIds.contains($0.pane?.paneId ?? "") }
        if let current, gone.contains(where: { $0.id == activeSessionId }) {
            switchTo(current)
        }
        for session in gone {
            closeSession(session, killRemote: false)
        }
        // A plain tab on one of these panes: the workspace's tab replaces it
        for session in sessions where session.groupId == nil && session.connectionConfig.id == config.id
            && paneIds.contains(session.rtachSessionId ?? "") {
            closeSession(session, killRemote: false)
        }
    }

    // MARK: Workspace actions

    /// Run something on a host: over its pooled connection if that works, else a new
    /// one. The connection kept from deploying may have closed since.
    func withHost<T>(_ config: SavedConnection, _ body: (SSHConnection) async throws -> T) async throws -> T {
        if let pooled = connectionPool[connectionKey(for: config)], pooled.isConnected {
            do {
                return try await body(pooled)
            } catch let error as RtachDeployError {
                // rtach answered: running it again wouldn't help
                throw error
            } catch {
                Logger.clauntty.debugOnly("SessionManager: pooled connection failed (\(error.localizedDescription)), using a new one")
            }
        }
        let connection = SSHConnection(
            host: config.host,
            port: config.port,
            username: config.username,
            authMethod: config.authMethod,
            connectionId: config.id,
            useTailscale: config.useTailscale
        )
        try await connection.connect()
        defer { connection.disconnect() }
        // rtach may not be on a host this run hasn't reached yet
        if rtachDeployers[connectionKey(for: config)] == nil {
            try await RtachDeployer(connection: connection).ensureDeployed()
        }
        return try await body(connection)
    }

    /// A menu action on the pane a group's tab shows
    func performPaneAction(_ action: PaneAction, groupId: UUID) async {
        guard let group = sessionGroups.first(where: { $0.id == groupId }),
              let config = currentSession(of: group)?.connectionConfig else { return }
        do {
            switch action {
            case .split:
                let created = try await withHost(config) { connection in
                    try await RtachDeployer(connection: connection)
                        .workspaceCommand(["split", group.activePaneId, "--quiet"], as: WorkspaceCreated.self)
                }
                await refreshWorkspaces(for: config)
                selectPane(groupId: groupId, paneId: created.pane)
            case .newTab:
                let created = try await withHost(config) { connection in
                    try await RtachDeployer(connection: connection)
                        .workspaceCommand(["tab", group.workspaceId, "--quiet"], as: WorkspaceCreated.self)
                }
                await refreshWorkspaces(for: config)
                selectPane(groupId: groupId, paneId: created.pane)
            case .close:
                _ = try await withHost(config) { connection in
                    try await RtachDeployer(connection: connection)
                        .workspaceCommand(["close", group.activePaneId, "--quiet"], as: WorkspacePaneClosed.self)
                }
                await refreshWorkspaces(for: config)
            }
        } catch {
            workspaceMessage = error.localizedDescription
        }
    }

    /// Start a workspace on a host, in `folder` (its git root, if any), and show it
    func newWorkspace(on config: SavedConnection, folder: String) async {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        do {
            let created = try await withHost(config) { connection in
                try await RtachDeployer(connection: connection)
                    .workspaceCommand(["new", "--quiet"], in: folder.isEmpty ? "~" : folder, as: WorkspaceCreated.self)
            }
            await refreshWorkspaces(for: config)
            showWorkspace(created.workspace, config: config)
        } catch {
            workspaceMessage = error.localizedDescription
        }
    }

    /// `rtach ws` changed a host's workspaces (from a terminal, or an agent): refresh, and
    /// show the pane it made
    func workspaceChanged(on config: SavedConnection, workspaceId: String?, paneId: String?) async {
        // Asked to show it: a workspace closed on this phone comes back
        if let workspaceId {
            hiddenWorkspaces.remove(Self.workspaceKey(config.id, workspaceId))
        }
        await refreshWorkspaces(for: config)
        guard let paneId,
              let groupId = sessionGroups.first(where: { $0.panes.contains { $0.id == paneId } })?.id else { return }
        selectPane(groupId: groupId, paneId: paneId)
        // Looked up again: selectPane changed the group's pane. Shows the group's tab if
        // another tab was active.
        if let group = sessionGroups.first(where: { $0.id == groupId }),
           let session = currentSession(of: group), activeSessionId != session.id {
            switchTo(session)
        }
    }

    /// Show a workspace closed on this phone again
    func openWorkspace(_ workspaceId: String, config: SavedConnection) async {
        hiddenWorkspaces.remove(Self.workspaceKey(config.id, workspaceId))
        await refreshWorkspaces(for: config)
        showWorkspace(workspaceId, config: config)
    }

    private func showWorkspace(_ workspaceId: String, config: SavedConnection) {
        guard let group = sessionGroups.first(where: { $0.connectionId == config.id && $0.workspaceId == workspaceId }),
              let session = currentSession(of: group) else { return }
        switchTo(session)
    }

    // MARK: Persistence

    func saveGroups() {
        let saved = sessionGroups.map { group in
            PersistedGroup(
                id: group.id,
                connectionId: group.connectionId,
                workspaceId: group.workspaceId,
                title: group.title,
                panes: group.panes.map { PersistedGroup.Pane(id: $0.id, title: $0.title, tab: $0.group) },
                activePaneId: group.activePaneId
            )
        }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: "clauntty_persisted_groups")
        }
    }

    /// Bring back the workspace tabs of the last run, disconnected. Their hosts refresh
    /// them once connected.
    func loadPersistedGroups(connectionStore: ConnectionStore) {
        guard let data = UserDefaults.standard.data(forKey: "clauntty_persisted_groups"),
              let saved = try? JSONDecoder().decode([PersistedGroup].self, from: data) else { return }
        for persisted in saved {
            guard let config = connectionStore.connections.first(where: { $0.id == persisted.connectionId }),
                  !persisted.panes.isEmpty else { continue }
            let group = SessionGroup(
                id: persisted.id,
                connectionId: persisted.connectionId,
                workspaceId: persisted.workspaceId,
                title: persisted.title,
                panes: persisted.panes.map { TabPane(id: $0.id, title: $0.title, status: .none, group: $0.tab) },
                activePaneId: persisted.activePaneId
            )
            sessionGroups.append(group)
            paneSession(for: group, paneId: group.activePaneId, config: config)
        }
    }
}
