import GhosttyKit
import SwiftUI

@main
struct ClaunttyMacApp: App {
    @StateObject private var ghostty: MacGhosttyApp
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var hosts = MacHosts(store: ConnectionStore())

    init() {
        // Ghostty's global state (allocator, logging) must exist before any config or app.
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            macLog.error("ghostty_init failed")
        }
        _ghostty = StateObject(wrappedValue: MacGhosttyApp())
    }

    var body: some Scene {
        Window("Clauntty", id: "main") {
            Group {
                if let views = ghostty.terminalViews {
                    MainView(views: views)
                } else {
                    Text("Ghostty failed to start")
                }
            }
            .environmentObject(sessionManager)
            .environmentObject(hosts)
            .frame(minWidth: 640, minHeight: 360)
            // Dark like the terminal and the phone app
            .preferredColorScheme(.dark)
            .task { await start() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Back at the Mac: the pane on screen takes its size back from the phone
                sessionManager.activeSession?.claimActive()
            }
        }
        .commands { PaneCommands(sessionManager: sessionManager, hosts: hosts) }
    }

    /// Saved workspaces first, so the sidebar is there at once, then each host's
    /// current ones.
    private func start() async {
        sessionManager.loadPersistedGroups(connectionStore: hosts.store)
        for connection in hosts.opened {
            await sessionManager.refreshWorkspaces(for: connection)
        }
        if sessionManager.activeSession == nil,
           let group = PaneCommands.groups(sessionManager, hosts).first,
           let session = sessionManager.currentSession(of: group) {
            sessionManager.switchTo(session)
        }
    }
}

/// The Pane menu: new, close and move between panes. Cmd keys stay with the app;
/// everything else goes to the terminal.
struct PaneCommands: Commands {
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var hosts: MacHosts

    var body: some Commands {
        CommandMenu("Pane") {
            Button("New Pane") { newPane() }
                .keyboardShortcut("t")
                .disabled(activeGroup == nil)
            Button("New Workspace") { newWorkspace() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(activeConnection == nil)
            Button("Close Pane…") { closePane() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(activeGroup == nil)
            Divider()
            Button("Next Pane") { move(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Pane") { move(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { n in
                Button("Pane \(n)") { show(at: n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }
    }

    private var activeGroup: SessionGroup? {
        sessionManager.activeSession.flatMap { sessionManager.sessionGroup(for: $0) }
    }

    private var activeConnection: SavedConnection? {
        sessionManager.activeSession?.connectionConfig
    }

    /// Workspaces in sidebar order: by host as opened, then as the host lists them
    static func groups(_ sessionManager: SessionManager, _ hosts: MacHosts) -> [SessionGroup] {
        hosts.opened.flatMap { connection in
            sessionManager.sessionGroups.filter { $0.connectionId == connection.id }
        }
    }

    /// Every pane in sidebar order
    private var panes: [PaneSelection] {
        Self.groups(sessionManager, hosts).flatMap { group in
            group.panes.map { PaneSelection(groupId: group.id, paneId: $0.id) }
        }
    }

    private func newPane() {
        guard let group = activeGroup else { return }
        Task { await sessionManager.performPaneAction(.split, groupId: group.id) }
    }

    private func newWorkspace() {
        guard let connection = activeConnection else { return }
        Task { await sessionManager.newWorkspace(on: connection, folder: "~") }
    }

    private func closePane() {
        guard let group = activeGroup,
              let pane = group.panes.first(where: { $0.id == group.activePaneId }) else { return }
        let alert = NSAlert()
        alert.messageText = "Close “\(pane.title)”?"
        alert.informativeText = "Whatever runs in it ends, on every device."
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await sessionManager.performPaneAction(.close, groupId: group.id) }
    }

    private func move(by offset: Int) {
        let all = panes
        guard !all.isEmpty else { return }
        let current = sessionManager.activeSession.flatMap { session in
            all.firstIndex { $0.groupId == session.groupId && $0.paneId == session.pane?.paneId }
        } ?? 0
        show(at: (current + offset + all.count) % all.count)
    }

    private func show(at index: Int) {
        let all = panes
        guard all.indices.contains(index) else { return }
        MainView.show(all[index], sessionManager)
    }
}
