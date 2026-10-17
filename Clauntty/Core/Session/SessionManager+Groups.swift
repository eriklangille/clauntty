import Foundation
import os.log

/// Several panes on a machine shown as one Clauntty tab, one pane at a time. Each pane
/// is an rtach session; the tab keeps a Session for each pane it has shown.
///
/// Nothing creates groups yet. They'll come from rtach workspaces.
struct SessionGroup: Identifiable, Equatable {
    let id: UUID
    let connectionId: UUID
    var title: String
    /// In display order: tabs in order, then panes in layout order
    var panes: [TabPane]
    /// The pane the tab shows
    var activePaneId: String
    /// Panes shown before, newest first
    var recentPaneIds: [String] = []
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

        let session = Session(connectionConfig: config, groupId: group.id)
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

        guard let session = paneSession(for: group, paneId: paneId, config: config) else { return }
        if groupIsActive {
            switchTo(session)
        }
    }

    // MARK: Closing

    /// The user closed a group's tab: detach its panes. The panes keep running on the machine.
    func closeSessionGroup(_ groupId: UUID) {
        sessionGroups.removeAll { $0.id == groupId }
        tabOrder.removeAll { $0 == groupId }
        saveTabOrder()
        for session in sessions.filter({ $0.groupId == groupId }) {
            closeSession(session, killRemote: false)
        }
    }
}
