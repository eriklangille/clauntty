import CryptoKit
import Foundation
import os.log

/// Several panes on a machine shown as one Clauntty tab, one pane at a time. Each pane
/// is an rtach session; the tab keeps a Session for each pane it has shown.
///
/// Groups come from rtach workspaces (`rtach ws`): every workspace on a connected host
/// is a tab. With rtach, every terminal tab is a workspace; a new tab is a one-pane one.
struct SessionGroup: Identifiable, Equatable {
    let id: UUID
    let connectionId: UUID
    /// The rtach workspace this tab shows
    let workspaceId: String
    var title: String
    /// In display order: tabs in order, then panes in layout order
    var panes: [TabPane]
    /// Each tab's split layout, in tab order (from the host; empty until it's listed)
    var layouts: [PaneLayout] = []
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
    func paneSession(for group: SessionGroup, paneId: String, config: SavedConnection) -> Session? {
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
        markPaneSeen(paneId)
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

    // MARK: Pane state

    /// A pane's title: an agent's task, else the program in front and its directory
    func paneTitle(_ paneId: String, fallback: String?) -> String {
        let fallbackTitle = fallback.flatMap { $0.isEmpty ? nil : $0 } ?? "shell"
        guard let state = paneStates[paneId] else { return fallbackTitle }
        if state.hasAgent {
            // Claude Code names the conversation in its title, after a spinner or "✳"
            // (any other title is the shell's). Until it does ("Claude Code"), the last
            // prompt the user sent it.
            let task = state.task.flatMap { $0.isEmpty ? nil : $0 }
            let title = state.title ?? ""
            guard let first = title.unicodeScalars.first, !first.properties.isAlphabetic, !CharacterSet.alphanumerics.contains(first),
                  first.value >= 0x2000 else { return task ?? state.agent ?? "agent" }
            let topic = String(title.drop { !$0.isLetter && !$0.isNumber })
            if topic.isEmpty || topic == "Claude Code" { return task ?? state.agent ?? "agent" }
            return topic
        }
        let dir = Self.directoryName(state.cwd)
        if let fg = state.fg, !fg.isEmpty, !Self.shells.contains(fg) {
            // At home the directory says nothing
            return dir.isEmpty || dir == "~" ? fg : "\(fg) · \(dir)"
        }
        return dir.isEmpty ? fallbackTitle : dir
    }

    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "login"]

    /// The last path component, "~" for a home directory
    private static func directoryName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        let parts = path.split(separator: "/")
        if (parts.count == 2 && (parts[0] == "Users" || parts[0] == "home")) || (parts.count == 1 && parts[0] == "root") {
            return "~"
        }
        return parts.last.map(String.init) ?? "/"
    }

    /// The status glyph: an agent's state, with done only until the user has seen it
    func paneStatus(_ paneId: String) -> PaneStatus {
        guard let state = paneStates[paneId], state.hasAgent else { return .none }
        switch state.state {
        case "working": return .working
        case "blocked": return .blocked
        case "done":
            if let doneAt = state.doneAt { return seenDoneAt[paneId] == doneAt ? .idle : .done }
            return unseenDonePanes.contains(paneId) ? .done : .idle
        default: return .idle
        }
    }

    /// The pane the user is looking at: the one shown, with the app in front
    private func paneIsShown(_ paneId: String) -> Bool {
        #if os(iOS)
        let appShown = !NotificationManager.shared.appIsBackgrounded
        #else
        let appShown = true
        #endif
        return activeSession?.pane?.paneId == paneId && appShown
    }

    /// Record that the user has seen a pane as it is now. True if its glyph changes.
    @discardableResult
    private func noteSeen(_ paneId: String) -> Bool {
        var changed = unseenDonePanes.remove(paneId) != nil
        if let doneAt = paneStates[paneId]?.doneAt, seenDoneAt[paneId] != doneAt {
            seenDoneAt[paneId] = doneAt
            changed = true
        }
        return changed
    }

    /// `pane;<id>;<json>` from rtach: one pane's state changed. Notifies the user when
    /// its agent needs them or finished out of sight.
    func paneStateChanged(paneId: String, json: String) {
        guard let state = try? JSONDecoder().decode(RemotePaneState.self, from: Data(json.utf8)) else { return }
        let previous = paneStates[paneId]
        paneStates[paneId] = state
        guard let index = sessionGroups.firstIndex(where: { $0.panes.contains { $0.id == paneId } }) else { return }

        if paneIsShown(paneId) {
            noteSeen(paneId)
        } else if state.state == "done", previous?.state != "done" {
            unseenDonePanes.insert(paneId)
        }
        if state.state != "done" {
            unseenDonePanes.remove(paneId)
            // Its next finish is a new one
            if seenDoneAt[paneId] != nil { seenDoneAt[paneId] = nil }
        }

        var group = sessionGroups[index]
        if let paneIndex = group.panes.firstIndex(where: { $0.id == paneId }) {
            group.panes[paneIndex].title = paneTitle(paneId, fallback: group.panes[paneIndex].title)
            group.panes[paneIndex].status = paneStatus(paneId)
        }
        sessionGroups[index] = group
        for session in sessions where session.pane?.paneId == paneId {
            session.agentTracked = state.hasAgent
        }

        guard state.hasAgent, previous?.state != state.state else { return }
        let paneName = group.panes.first { $0.id == paneId }?.title ?? "agent"
        let body: String?
        switch state.state {
        case "blocked": body = state.note ?? "Needs you"
        case "done": body = "Finished"
        default: body = nil
        }
        // A master that pushes tells the phone itself, even once iOS has suspended the app
        #if os(iOS)
        if let body, !(state.pushes == true && PushNotifications.shared.isActive) {
            Task { await NotificationManager.shared.schedulePaneAttention(workspace: group.title, pane: paneName, body: body, paneId: paneId) }
        }
        #else
        onPaneAttention?(group.title == paneName ? paneName : "\(group.title) · \(paneName)", body, paneId, state.state == "blocked")
        #endif
    }

    /// The user has seen a pane: its finished agent shows as idle from now on
    func markPaneSeen(_ paneId: String) {
        guard noteSeen(paneId),
              let index = sessionGroups.firstIndex(where: { $0.panes.contains { $0.id == paneId } }),
              let paneIndex = sessionGroups[index].panes.firstIndex(where: { $0.id == paneId }) else { return }
        sessionGroups[index].panes[paneIndex].status = paneStatus(paneId)
    }

    /// Show a pane (a notification was tapped)
    func showPane(_ paneId: String) {
        guard let group = sessionGroups.first(where: { $0.panes.contains { $0.id == paneId } }) else { return }
        selectPane(groupId: group.id, paneId: paneId)
        if let updated = sessionGroups.first(where: { $0.id == group.id }), let session = currentSession(of: updated) {
            switchTo(session)
        }
    }

    // MARK: Closing

    /// Close what a tab shows: in a workspace, end the pane shown (the last one takes
    /// the workspace and its tab along); a plain tab (no rtach) closes its session
    func closeTab(_ session: Session) {
        if session.groupId != nil, let paneId = session.pane?.paneId {
            session.isClosing = true
            let config = session.connectionConfig
            // Gone now, not when the host answers. That takes the group too if it was
            // its last pane, so the close below doesn't look the group up.
            paneEnded(paneId, config: config, refresh: false)
            Task {
                do {
                    _ = try await withHost(config) { connection in
                        try await RtachDeployer(connection: connection)
                            .workspaceCommand(["close", paneId, "--quiet"], as: WorkspacePaneClosed.self)
                    }
                } catch {
                    workspaceMessage = error.localizedDescription
                }
                await refreshWorkspaces(for: config)
                // Still there (closing failed): it comes back
                if workspacePaneIds[config.id]?.contains(paneId) == true {
                    session.isClosing = false
                    endedPanes.remove(paneId)
                    if let workspaces = knownWorkspaces[config.id] {
                        applyWorkspaces(workspaces, hostName: knownHostNames[config.id], config: config)
                    }
                }
            }
        } else {
            closeSession(session)
        }
    }

    /// A pane's session ended (its shell exited, it was stopped, or the user closed it):
    /// take it out of the host's last known workspaces now, so its tab goes (or shows the
    /// workspace's next pane) without waiting for the host, then check with the host
    func paneEnded(_ paneId: String, config: SavedConnection, refresh: Bool = true) {
        guard endedPanes.insert(paneId).inserted else { return }
        Logger.clauntty.debugOnly("SessionManager: pane \(paneId.prefix(8)) ended")
        if seenDoneAt[paneId] != nil { seenDoneAt[paneId] = nil }
        if let workspaces = knownWorkspaces[config.id] {
            applyWorkspaces(workspaces, hostName: knownHostNames[config.id], config: config)
        }
        if refresh {
            Task { await refreshWorkspaces(for: config) }
        }
    }

    /// Take a group's tab away (its workspace ended)
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
    func applyWorkspaces(_ listed: [RemoteWorkspace], hostName: String?, config: SavedConnection) {
        knownWorkspaces[config.id] = listed
        if let hostName { knownHostNames[config.id] = hostName }
        // As the host lists them, so a pane that failed to close shows up here
        workspacePaneIds[config.id] = Set(listed.flatMap { $0.tabs.flatMap { $0.panes.map(\.id) } })
        let workspaces = endedPanes.isEmpty ? listed : listed.compactMap { $0.without(endedPanes) }
        var shown = Set<UUID>()
        var order: [UUID] = []

        var seen = seenDoneAt
        for pane in workspaces.flatMap({ $0.tabs.flatMap(\.panes) }) {
            paneStates[pane.id] = pane.state
            // Not done: its next finish is a new one
            if pane.state?.doneAt == nil { seen[pane.id] = nil }
        }
        if seen != seenDoneAt { seenDoneAt = seen }
        // A finish on screen is seen (at launch, the pane shown before its state was known)
        if let pane = activeSession?.pane?.paneId, paneIsShown(pane) { noteSeen(pane) }

        for workspace in workspaces {
            let panes = workspace.tabs.enumerated().flatMap { tabIndex, tab in
                tab.panes.map { pane in
                    TabPane(id: pane.id, title: paneTitle(pane.id, fallback: pane.title), status: paneStatus(pane.id), group: tabIndex)
                }
            }
            guard !panes.isEmpty else { continue }
            // Named by the machine, so two saved connections to it show the workspace once
            let groupId = Self.stableId("\(hostName ?? config.id.uuidString)/\(workspace.id)")
            if let existing = sessionGroups.first(where: { $0.id == groupId }), existing.connectionId != config.id {
                continue
            }
            shown.insert(groupId)
            order.append(groupId)
            updateGroup(id: groupId, workspace: workspace, panes: panes, config: config)
        }

        for group in sessionGroups where group.connectionId == config.id && !shown.contains(group.id) {
            removeSessionGroup(group.id)
        }
        // Not over a drag the host hasn't heard about yet
        if pendingWorkspaceMoves[config.id] == nil {
            followHostOrder(order)
        } else {
            for id in order where !tabOrder.contains(id) {
                tabOrder.append(id)
            }
        }
        saveGroups()
        saveTabOrder()
    }

    /// A host's workspace tabs in the host's order (`rtach ws reorder`, from any
    /// device), in the places they have among other hosts' tabs and pages. A new one
    /// goes right after the one before it on the host.
    private func followHostOrder(_ order: [UUID]) {
        for (index, id) in order.enumerated() where !tabOrder.contains(id) {
            let previous = order[..<index].last.flatMap { tabOrder.firstIndex(of: $0) }
            tabOrder.insert(id, at: previous.map { $0 + 1 } ?? tabOrder.endIndex)
        }
        let ids = Set(order)
        let places = tabOrder.indices.filter { ids.contains(tabOrder[$0]) }
        for (place, id) in zip(places, order) {
            tabOrder[place] = id
        }
    }

    private func updateGroup(id groupId: UUID, workspace: RemoteWorkspace, panes: [TabPane], config: SavedConnection) {
        let paneIds = Set(panes.map(\.id))
        // A tab's panes side by side if the host didn't say how they're split
        let layouts = workspace.tabs.map { tab in
            tab.layout ?? tab.panes.dropFirst().reduce(PaneLayout.pane(tab.panes.first?.id ?? "")) {
                .split(vertical: false, ratio: 0.5, first: $0, second: .pane($1.id))
            }
        }
        var group: SessionGroup
        if let index = sessionGroups.firstIndex(where: { $0.id == groupId }) {
            group = sessionGroups[index]
            group.title = workspace.name
            group.panes = panes
            group.layouts = layouts
            group.recentPaneIds.removeAll { !paneIds.contains($0) }
            if !paneIds.contains(group.activePaneId) {
                group.activePaneId = group.recentPaneIds.first ?? panes[0].id
            }
            sessionGroups[index] = group
        } else {
            group = SessionGroup(id: groupId, connectionId: config.id, workspaceId: workspace.id,
                                 title: workspace.name, panes: panes, layouts: layouts, activePaneId: panes[0].id)
            sessionGroups.append(group)
        }

        let current = paneSession(for: group, paneId: group.activePaneId, config: config)
        for session in sessions where session.groupId == groupId {
            session.pane?.groupTitle = group.title
            session.agentTracked = session.pane.flatMap { paneStates[$0.paneId] }?.hasAgent ?? false
        }
        // Panes gone from the workspace: show the current one before closing them
        let gone = sessions.filter { $0.groupId == groupId && !paneIds.contains($0.pane?.paneId ?? "") }
        if let current, gone.contains(where: { $0.id == activeSessionId }) {
            switchTo(current)
        }
        for session in gone {
            closeSession(session, killRemote: false)
        }
        // A plain tab on one of these panes: the workspace's tab replaces it. Any
        // connection's: pane ids are unique, and another saved connection to this
        // machine may have adopted the pane before it knew about the workspace.
        for session in sessions where session.groupId == nil && paneIds.contains(session.rtachSessionId ?? "") {
            closeSession(session, killRemote: false)
        }
    }

    // MARK: Workspace actions

    /// Run something on a host, over its shared connection. If that fails and the
    /// connection no longer answers (the network changed under it), once more on a new one.
    func withHost<T>(_ config: SavedConnection, _ body: (SSHConnection) async throws -> T) async throws -> T {
        let connection = try await hostConnection(for: config)
        do {
            return try await run(body, on: connection, config: config)
        } catch let error as RtachDeployError {
            // rtach answered: running it again wouldn't help
            throw error
        } catch {
            guard await !connection.isResponsive() else { throw error }
            Logger.clauntty.debugOnly("SessionManager: connection to \(config.displayName) stopped answering (\(error.localizedDescription)), using a new one")
            dropConnection(connection, reconnect: true)
            return try await run(body, on: try await hostConnection(for: config), config: config)
        }
    }

    private func run<T>(_ body: (SSHConnection) async throws -> T, on connection: SSHConnection,
                        config: SavedConnection) async throws -> T {
        // rtach may not be on a host this run hasn't reached yet
        _ = try await hostDeployer(for: config)
        return try await body(connection)
    }

    /// A menu action on the pane a group's tab shows
    func performPaneAction(_ action: PaneAction, groupId: UUID) async {
        guard let group = sessionGroups.first(where: { $0.id == groupId }),
              let config = currentSession(of: group)?.connectionConfig else { return }
        do {
            switch action {
            case .split, .splitDown:
                let created = try await withHost(config) { connection in
                    try await RtachDeployer(connection: connection)
                        .workspaceCommand(["split", group.activePaneId, action == .splitDown ? "-v" : "-h", "--quiet"],
                                          as: WorkspaceCreated.self)
                }
                await refreshWorkspaces(for: config)
                selectPane(groupId: groupId, paneId: created.pane)
            case .newWorkspace:
                await newWorkspace(on: config, folder: "~")
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

    /// A new terminal tab on a host: a one-pane workspace in the home folder. Without
    /// rtach (no persistent sessions), a plain tab.
    @discardableResult
    func openTerminal(on config: SavedConnection) async -> Session? {
        guard useRtach else { return createSession(for: config) }
        return await newWorkspace(on: config, folder: "~")
    }

    /// Start a workspace on a host, in `folder` (its git root, if any), and show it.
    /// It goes right after the workspace you're in, if that's on the same host.
    @discardableResult
    func newWorkspace(on config: SavedConnection, folder: String) async -> Session? {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        let current = activeSession.flatMap { sessionGroup(for: $0) }
        let after = current.flatMap { $0.connectionId == config.id ? ["--after", $0.workspaceId] : nil } ?? []
        do {
            let created = try await withHost(config) { connection in
                try await RtachDeployer(connection: connection)
                    .workspaceCommand(["new"] + after + ["--quiet"], in: folder.isEmpty ? "~" : folder, as: WorkspaceCreated.self)
            }
            await refreshWorkspaces(for: config)
            return showWorkspace(created.workspace)
        } catch {
            workspaceMessage = error.localizedDescription
            return nil
        }
    }

    /// Sessions on a host that aren't in a workspace (started by an older app, or by
    /// hand) become one-pane workspaces, so every tab is one
    func adoptSessions(_ sessionIds: [String], on config: SavedConnection) async {
        guard !sessionIds.isEmpty else { return }
        do {
            _ = try await withHost(config) { connection in
                try await RtachDeployer(connection: connection)
                    .workspaceCommand(["add"] + sessionIds + ["--quiet"], as: [WorkspaceCreated].self)
            }
            await refreshWorkspaces(for: config)
        } catch {
            Logger.clauntty.warning("SessionManager: can't adopt \(sessionIds.count) sessions on \(config.displayName): \(error.localizedDescription)")
        }
    }

    /// A workspace tab was dragged to a new place here: put it there on its host too
    /// (before the next of the host's tabs), so every device shows that order. A drag
    /// on the phone moves the tab at every swap, so the host hears once it settles. If
    /// that fails, the refresh puts back the host's order.
    func moveWorkspaceOnHost(_ groupId: UUID) {
        guard let group = sessionGroups.first(where: { $0.id == groupId }) else { return }
        let connectionId = group.connectionId
        let previous = pendingWorkspaceMoves[connectionId]
        previous?.send.cancel()
        var moved = previous?.groupIds ?? []
        if !moved.contains(groupId) { moved.append(groupId) }
        let token = UUID()
        let send = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // One at a time: one already under way finishes first
            await previous?.send.value
            await sendWorkspaceMoves(moved, connectionId: connectionId)
            // Moved again meanwhile: the later one refreshes
            guard pendingWorkspaceMoves[connectionId]?.token == token else { return }
            pendingWorkspaceMoves[connectionId] = nil
            if let config = sessionGroups.first(where: { $0.connectionId == connectionId })
                .flatMap({ currentSession(of: $0) })?.connectionConfig {
                await refreshWorkspaces(for: config)
            }
        }
        pendingWorkspaceMoves[connectionId] = (moved, send, token)
    }

    /// `rtach ws reorder` for each moved workspace, before the next of its host's tabs
    /// here, in turn
    private func sendWorkspaceMoves(_ groupIds: [UUID], connectionId: UUID) async {
        for groupId in groupIds {
            guard let group = sessionGroups.first(where: { $0.id == groupId }),
                  let config = currentSession(of: group)?.connectionConfig else { continue }
            let hostGroups = tabOrder.compactMap { id in
                sessionGroups.first { $0.id == id && $0.connectionId == connectionId }
            }
            let local = hostGroups.map(\.workspaceId)
            // The host has them in this order already
            guard knownWorkspaces[config.id]?.map(\.id).filter(local.contains) != local,
                  let index = hostGroups.firstIndex(where: { $0.id == groupId }) else { continue }
            let before = hostGroups.dropFirst(index + 1).first.map { ["--before", $0.workspaceId] } ?? []
            do {
                _ = try await withHost(config) { connection in
                    try await RtachDeployer(connection: connection)
                        // Not --quiet: rtach tells the device with the active pane to refresh
                        // (`workspace;`), which may be another one
                        .workspaceCommand(["reorder", group.workspaceId] + before, as: WorkspaceReordered.self)
                }
            } catch {
                workspaceMessage = error.localizedDescription
                return
            }
        }
    }

    /// The divider between two panes of a tab was dragged: `pane`'s side takes `ratio`
    /// of the space, here at once and on the host (`rtach ws resize`)
    func resizeSplit(groupId: UUID, pane: String, other: String, ratio: Double) {
        guard let index = sessionGroups.firstIndex(where: { $0.id == groupId }),
              let config = currentSession(of: sessionGroups[index])?.connectionConfig else { return }
        let ratio = (ratio * 1000).rounded() / 1000
        sessionGroups[index].layouts = sessionGroups[index].layouts.map {
            $0.paneIds.contains(pane) ? $0.resized(pane, other, ratio: ratio) : $0
        }
        Task {
            do {
                _ = try await withHost(config) { connection in
                    try await RtachDeployer(connection: connection)
                        // Not --quiet, as reorder
                        .workspaceCommand(["resize", pane, other, String(ratio)], as: WorkspaceResized.self)
                }
            } catch {
                workspaceMessage = error.localizedDescription
                await refreshWorkspaces(for: config)
            }
        }
    }

    private func showWorkspace(_ workspaceId: String) -> Session? {
        guard let group = sessionGroups.first(where: { $0.workspaceId == workspaceId }),
              let session = currentSession(of: group) else { return nil }
        switchTo(session)
        return session
    }

    /// `rtach ws` changed a host's workspaces (from a terminal, or an agent): refresh, and
    /// show the pane it made
    func workspaceChanged(on config: SavedConnection, workspaceId: String?, paneId: String?) async {
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
        // Images that were waiting in their viewers, and those closed
        let images = WaitingImages.load(workspaces: Set(sessionGroups.map(\.id)))
        restoreImages(open: images.open, recent: images.recent)
    }
}
