import GhosttyKit
import SwiftUI

@main
struct ClaunttyMacApp: App {
    @StateObject private var ghostty: MacGhosttyApp
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var hosts = MacHosts(store: ConnectionStore())
    @StateObject private var window = WindowState()

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
            .environmentObject(window)
            .frame(minWidth: 640, minHeight: 360)
            // Dark like the terminal and the phone app
            .preferredColorScheme(.dark)
            .task { await start() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                // Back at the Mac: the panes on screen take their size back from the phone,
                // and workspaces changed elsewhere show up (the phone does this on foreground)
                sessionManager.showSplitPanes()
                Task {
                    for connection in hosts.opened { await sessionManager.refreshWorkspaces(for: connection) }
                }
            }
            // Remember the pane you're on, so a relaunch (or a crash) comes back to it
            .onChange(of: sessionManager.activeSessionId) { _, _ in
                sessionManager.savePersistence()
                // Seen: its notification goes
                if let pane = sessionManager.activeSession?.pane?.paneId {
                    MacNotifications.shared.seen(paneId: pane)
                }
            }
            // A pane's status changed (live, or listed again): the Dock's count follows
            .onChange(of: sessionManager.sessionGroups.flatMap { $0.panes.map(\.status) }) { _, _ in
                MacNotifications.shared.updateBadge()
            }
        }
        // No title bar: each pane's title bar is the top of the window, as in Rex
        .windowStyle(.hiddenTitleBar)
        .commands {
            PaneCommands(sessionManager: sessionManager, hosts: hosts, window: window)
            CommandGroup(replacing: .sidebar) {
                Button(window.sidebar == .detailOnly ? "Show Sidebar" : "Hide Sidebar") { window.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandGroup(after: .toolbar) {
                Button(sessionManager.shownImages == nil ? "Bigger" : "Zoom In") { zoom(by: 1) }
                    .keyboardShortcut("=")
                Button(sessionManager.shownImages == nil ? "Smaller" : "Zoom Out") { zoom(by: -1) }
                    .keyboardShortcut("-")
                Button(sessionManager.shownImages == nil ? "Actual Size" : "Fit Image") { zoom(by: nil) }
                    .keyboardShortcut("0")
            }
        }
    }

    /// The image shown, if the viewer is open, else the terminals' font
    private func zoom(by step: Float?) {
        if sessionManager.shownImages != nil {
            NotificationCenter.default.post(name: ImageViewer.zoomCommand, object: step.map { NSNumber(value: $0) })
        } else {
            ghostty.terminalViews?.adjustFontSize(by: step)
        }
    }

    /// Saved workspaces first, so the sidebar is there at once, then each host's
    /// current ones.
    private func start() async {
        MacNotifications.shared.start(sessionManager: sessionManager)
        sessionManager.loadPersistedTabs(connectionStore: hosts.store)
        // Pages reconnect their port when shown
        sessionManager.loadPersistedWebTabs(connectionStore: hosts.store)
        // The order you've dragged workspaces to
        sessionManager.loadTabOrder()
        for connection in hosts.opened {
            await sessionManager.refreshWorkspaces(for: connection)
        }
        // The pane from last time if it's still there, else the first one; switching connects it
        if let session = sessionManager.activeSession
            ?? PaneCommands.groups(sessionManager, hosts).first.flatMap({ sessionManager.currentSession(of: $0) }) {
            sessionManager.switchTo(session)
        }
    }
}

/// The Pane menu: new, close and move between panes. Cmd keys stay with the app;
/// everything else goes to the terminal.
struct PaneCommands: Commands {
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var hosts: MacHosts
    @ObservedObject var window: WindowState

    var body: some Commands {
        CommandMenu("Pane") {
            Button("Go to Pane…") { window.switcherShown.toggle() }
                .keyboardShortcut("k")
                .disabled(sessionManager.sessionGroups.isEmpty)
            Divider()
            Button("New Workspace") { newWorkspace() }
                .keyboardShortcut("t")
                .disabled(activeConnection == nil)
            Button("Split Right") { split(.split) }
                .keyboardShortcut("d")
                .disabled(activeGroup == nil)
            Button("Split Down") { split(.splitDown) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(activeGroup == nil)
            Button(sessionManager.activeWebTab == nil ? "Close Pane…" : "Close Page") { closePane() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(activeGroup == nil && sessionManager.activeWebTab == nil)
            Button(window.zoomedPane == nil ? "Zoom Pane" : "Show All Panes") { toggleZoom() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(activeGroup.map { $0.shownLayout.paneIds.count < 2 } ?? true)
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
        hosts.opened.flatMap { sessionManager.orderedGroups(on: $0) }
    }

    /// Every pane in sidebar order
    private var panes: [PaneSelection] {
        Self.groups(sessionManager, hosts).flatMap { group in
            group.panes.map { PaneSelection(groupId: group.id, paneId: $0.id) }
        }
    }

    /// A new pane beside or below the one you're in, as `clauntty ws split [-v]` makes
    private func split(_ action: PaneAction) {
        guard let group = activeGroup else { return }
        Task { await sessionManager.performPaneAction(action, groupId: group.id) }
    }

    private func newWorkspace() {
        guard let connection = activeConnection else { return }
        Task { await sessionManager.newWorkspace(on: connection, folder: "~") }
    }

    private func closePane() {
        // A page only stops forwarding its port: nothing to confirm
        if let webTab = sessionManager.activeWebTab {
            sessionManager.closeWebTab(webTab)
            return
        }
        guard let group = activeGroup,
              let pane = group.panes.first(where: { $0.id == group.activePaneId }) else { return }
        MainView.closePane(PaneSelection(groupId: group.id, paneId: pane.id), title: pane.title, sessionManager)
    }

    private func toggleZoom() {
        guard let group = activeGroup else { return }
        window.zoomedPane = window.zoomedPane == group.activePaneId ? nil : group.activePaneId
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
