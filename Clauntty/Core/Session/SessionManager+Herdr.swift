import Foundation
import UIKit
import os.log

/// One Herdr session (workspace) on a machine, shown as one Clauntty tab. The tab shows
/// one pane at a time; each pane it has shown is an rtach session running
/// `herdr terminal attach` for that pane.
struct HerdrTab: Identifiable, Equatable {
    let id: UUID
    let connectionId: UUID
    var workspace: HerdrWorkspaceInfo
    /// The pane the tab shows
    var activePaneId: String
    /// Panes shown before, newest first. Their attaches stay open so switching back is instant.
    var recentPaneIds: [String] = []
}

enum HerdrError: LocalizedError {
    case unsafeId(String)

    var errorDescription: String? {
        switch self {
        case .unsafeId(let id): return "Unexpected Herdr id: \(id)"
        }
    }
}

extension SessionManager {
    /// How often Herdr's state is read while the app is in the foreground
    static let herdrPollInterval: Duration = .seconds(3)
    /// How long to wait before looking for Herdr again on a machine without it
    static let herdrRetryInterval: TimeInterval = 60
    /// Attaches kept open per Herdr tab besides the visible pane. Each holds its pane at
    /// the phone's size on the laptop until it's closed.
    static let herdrWarmPanes = 2

    // MARK: Lookup

    /// The session showing a Herdr tab's current pane
    func currentSession(of tab: HerdrTab) -> Session? {
        sessions.first { $0.herdrTabId == tab.id && $0.herdrPane?.paneId == tab.activePaneId }
    }

    func herdrTab(for session: Session) -> HerdrTab? {
        guard let id = session.herdrTabId else { return nil }
        return herdrTabs.first { $0.id == id }
    }

    /// The panes of a session's Herdr tab, and the index of the one shown
    func herdrPanes(for session: Session) -> (panes: [HerdrPaneInfo], activeIndex: Int)? {
        guard let tab = herdrTab(for: session) else { return nil }
        let index = tab.workspace.panes.firstIndex { $0.paneId == tab.activePaneId } ?? 0
        return (tab.workspace.panes, index)
    }

    // MARK: Snapshot

    /// Read Herdr's state on a machine and update its tabs. Machines without Herdr are
    /// left alone for a while.
    func refreshHerdr(for config: SavedConnection) async {
        if let retry = herdrRetryAfter[config.id], retry > Date() { return }
        guard !herdrRefreshing.contains(config.id) else { return }
        herdrRefreshing.insert(config.id)
        defer { herdrRefreshing.remove(config.id) }

        let workspaces: [HerdrWorkspaceInfo]
        do {
            let connection = try await pooledConnection(for: config)
            let output = try await connection.executeCommandData(HerdrCommands.snapshot)
            workspaces = try HerdrSnapshot.parse(output).workspaceInfos()
        } catch {
            // No Herdr, or it isn't running. Existing tabs stay; their attaches show the error.
            Logger.clauntty.debugOnly("Herdr: no snapshot from \(config.host): \(error.localizedDescription)")
            herdrRetryAfter[config.id] = Date().addingTimeInterval(Self.herdrRetryInterval)
            return
        }
        herdrRetryAfter[config.id] = nil
        apply(workspaces, config: config)
    }

    private func apply(_ workspaces: [HerdrWorkspaceInfo], config: SavedConnection) {
        let before = herdrTabs
        var seen: Set<UUID> = []

        for workspace in workspaces where !workspace.panes.isEmpty {
            let id = HerdrCommands.tabId(connectionId: config.id, workspaceId: workspace.workspaceId)
            seen.insert(id)
            guard !hiddenHerdrTabIds.contains(id) else { continue }

            if let index = herdrTabs.firstIndex(where: { $0.id == id }) {
                var tab = herdrTabs[index]
                tab.workspace = workspace
                // The shown pane closed: fall back to the one Herdr has focused
                if !workspace.panes.contains(where: { $0.paneId == tab.activePaneId }) {
                    tab.activePaneId = workspace.focusedPaneId ?? workspace.panes[0].paneId
                }
                tab.recentPaneIds.removeAll { id in !workspace.panes.contains { $0.paneId == id } }
                if tab != herdrTabs[index] {
                    herdrTabs[index] = tab
                }
                syncPaneSessions(of: tab, config: config)
            } else {
                let tab = HerdrTab(
                    id: id,
                    connectionId: config.id,
                    workspace: workspace,
                    activePaneId: workspace.focusedPaneId ?? workspace.panes[0].paneId
                )
                herdrTabs.append(tab)
                if !tabOrder.contains(id) {
                    tabOrder.append(id)
                    saveTabOrder()
                }
                syncPaneSessions(of: tab, config: config)
                Logger.clauntty.debugOnly("Herdr: tab for '\(workspace.label)' on \(config.host), \(workspace.panes.count) panes")
            }
        }

        // Herdr sessions that ended
        for tab in herdrTabs where tab.connectionId == config.id && !seen.contains(tab.id) {
            removeHerdrTab(tab)
        }

        if herdrTabs != before {
            sessionStateVersion += 1
        }
    }

    /// Make sure the tab's current pane has a session (the tab bar shows tabs through
    /// sessions), drop sessions of panes that closed, and keep labels current
    private func syncPaneSessions(of tab: HerdrTab, config: SavedConnection) {
        let paneIds = Set(tab.workspace.panes.map(\.paneId))
        for session in sessions.filter({ $0.herdrTabId == tab.id }) {
            guard let paneId = session.herdrPane?.paneId, paneIds.contains(paneId) else {
                // The attach ends on its own when Herdr closes the pane
                closeSession(session, killRemote: true)
                continue
            }
            if session.herdrPane?.workspaceLabel != tab.workspace.label {
                session.herdrPane?.workspaceLabel = tab.workspace.label
            }
        }
        paneSession(for: tab, paneId: tab.activePaneId, config: config)
    }

    /// The session for a pane, created disconnected if needed. It connects when shown.
    @discardableResult
    private func paneSession(for tab: HerdrTab, paneId: String, config: SavedConnection) -> Session? {
        if let existing = sessions.first(where: { $0.herdrTabId == tab.id && $0.herdrPane?.paneId == paneId }) {
            return existing
        }
        guard let pane = tab.workspace.panes.first(where: { $0.paneId == paneId }) else { return nil }

        let session = Session(connectionConfig: config, herdrTabId: tab.id)
        session.herdrPane = HerdrPaneRef(
            workspaceId: tab.workspace.workspaceId,
            workspaceLabel: tab.workspace.label,
            paneId: pane.paneId,
            terminalId: pane.terminalId
        )
        session.rtachSessionId = HerdrCommands.rtachSessionId(terminalId: pane.terminalId)
        session.state = .disconnected
        session.onStateChange = { [weak self] in
            self?.sessionStateVersion += 1
        }
        sessions.append(session)
        return session
    }

    // MARK: Switching panes

    /// Show another pane in a Herdr tab
    func selectHerdrPane(tabId: UUID, paneId: String) {
        guard let index = herdrTabs.firstIndex(where: { $0.id == tabId }) else { return }
        var tab = herdrTabs[index]
        guard tab.activePaneId != paneId, let config = currentSession(of: tab)?.connectionConfig else { return }

        let tabIsActive = activeSession?.herdrTabId == tabId
        tab.recentPaneIds.removeAll { $0 == paneId || $0 == tab.activePaneId }
        tab.recentPaneIds.insert(tab.activePaneId, at: 0)
        tab.activePaneId = paneId
        herdrTabs[index] = tab

        guard let session = paneSession(for: tab, paneId: paneId, config: config) else { return }
        if tabIsActive {
            switchTo(session)
        }
        closeColdAttaches(of: tabId)
    }

    /// Close attaches beyond the warm ones, so the laptop gets those panes back at its size
    private func closeColdAttaches(of tabId: UUID) {
        guard let index = herdrTabs.firstIndex(where: { $0.id == tabId }) else { return }
        let warm = Array(herdrTabs[index].recentPaneIds.prefix(Self.herdrWarmPanes))
        herdrTabs[index].recentPaneIds = warm
        let keep = Set(warm + [herdrTabs[index].activePaneId])
        for session in sessions.filter({ $0.herdrTabId == tabId }) {
            if let paneId = session.herdrPane?.paneId, !keep.contains(paneId) {
                closeSession(session, killRemote: true)
            }
        }
    }

    // MARK: Closing

    /// The user closed a Herdr tab: end its attaches and hide it until the app restarts.
    /// The Herdr session itself keeps running.
    func closeHerdrTab(_ tabId: UUID) {
        hiddenHerdrTabIds.insert(tabId)
        if let tab = herdrTabs.first(where: { $0.id == tabId }) {
            removeHerdrTab(tab)
        }
    }

    private func removeHerdrTab(_ tab: HerdrTab) {
        herdrTabs.removeAll { $0.id == tab.id }
        tabOrder.removeAll { $0 == tab.id }
        saveTabOrder()
        for session in sessions.filter({ $0.herdrTabId == tab.id }) {
            closeSession(session, killRemote: true)
        }
    }

    // MARK: Polling

    /// Keep Herdr tabs current while the app is in the foreground
    func startHerdrPolling() {
        guard herdrPollTask == nil else { return }
        herdrPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.herdrPollInterval)
                guard let self else { return }
                guard UIApplication.shared.applicationState == .active else { continue }
                for config in self.herdrMachines() {
                    await self.refreshHerdr(for: config)
                }
            }
        }
    }

    /// Machines with open tabs; Herdr may be started on one later
    private func herdrMachines() -> [SavedConnection] {
        var seen: Set<UUID> = []
        var configs: [SavedConnection] = []
        for session in sessions where seen.insert(session.connectionConfig.id).inserted {
            configs.append(session.connectionConfig)
        }
        return configs
    }
}
