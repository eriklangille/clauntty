import SwiftUI

/// A pane in the sidebar: which workspace (group) and which pane in it.
struct PaneSelection: Hashable {
    let groupId: UUID
    let paneId: String
}

/// The window: hosts, their workspaces and panes in the sidebar, and the pane
/// you're on filling the rest.
struct MainView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts
    @EnvironmentObject private var switcher: PaneSwitcherState
    let views: TerminalViews

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } detail: {
            detail
        }
        .navigationTitle(title)
        .overlay(alignment: .top) {
            if switcher.shown {
                ZStack(alignment: .top) {
                    // A click anywhere else closes it
                    Color.black.opacity(0.001)
                        .onTapGesture { switcher.shown = false }
                    PaneSwitcher()
                        .padding(.top, 70)
                }
            }
        }
        .overlay {
            ImageViewer(content: $sessionManager.imageViewer)
        }
        // Closed: typing goes back to the pane you're in
        .onChange(of: switcher.shown) { _, shown in
            if !shown { refocus() }
        }
        .onChange(of: sessionManager.imageViewer == nil) { _, closed in
            if closed { refocus() }
        }
        .onChange(of: sessionManager.sessions.map(\.id)) { _, ids in
            views.prune(keeping: Set(ids))
        }
        // Another pane, or a split from the host: every pane in the tab runs
        .onChange(of: sessionManager.activeSessionId) { _, _ in sessionManager.showSplitPanes() }
        .onChange(of: shownLayout) { _, _ in sessionManager.showSplitPanes() }
        .onChange(of: sessionManager.sessionStateVersion) { _, _ in sessionManager.refreshLayoutIfMissing() }
        .alert("Clauntty", isPresented: workspaceMessageShown) {
            Button("OK") { sessionManager.workspaceMessage = nil }
        } message: {
            Text(sessionManager.workspaceMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let webTab = sessionManager.activeWebTab {
            WebPane(webTab: webTab)
        } else if let session = sessionManager.activeSession, let group = sessionManager.sessionGroup(for: session) {
            SplitPanes(group: group, views: views)
                .background(ThemeColors.background)
        } else if hosts.opened.isEmpty {
            HostPicker()
        } else {
            Text("Pick a pane")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func refocus() {
        guard let session = sessionManager.activeSession else { return }
        DispatchQueue.main.async { views.focus(session) }
    }

    private var shownLayout: PaneLayout? {
        sessionManager.activeSession.flatMap { sessionManager.sessionGroup(for: $0) }?.shownLayout
    }

    private var title: String {
        if let webTab = sessionManager.activeWebTab { return webTab.title }
        guard let session = sessionManager.activeSession,
              let group = sessionManager.sessionGroup(for: session),
              let pane = group.panes.first(where: { $0.id == group.activePaneId }) else {
            return "Clauntty"
        }
        return group.panes.count > 1 ? "\(group.title) · \(pane.title)" : group.title
    }

    private var workspaceMessageShown: Binding<Bool> {
        Binding(get: { sessionManager.workspaceMessage != nil },
                set: { if !$0 { sessionManager.workspaceMessage = nil } })
    }
}

/// The theme's background, behind the terminal and as it resizes.
@MainActor
enum ThemeColors {
    static var background: Color {
        ThemeManager.shared.defaultTheme(dark: true)?.backgroundColor ?? .black
    }
}

/// Hosts from ~/.ssh/config, to open one.
struct HostPicker: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts

    var body: some View {
        VStack(spacing: 14) {
            Text("Open a host")
                .font(.title2.weight(.semibold))
            if hosts.addable.isEmpty {
                Text("No hosts in ~/.ssh/config")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(hosts.addable) { host in
                            Button {
                                let connection = hosts.open(host)
                                Task { await MainView.openHost(connection, sessionManager) }
                            } label: {
                                HStack {
                                    Image(systemName: "server.rack")
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(host.alias)
                                        Text("\(host.user)@\(host.hostName)\(host.port == 22 ? "" : ":\(host.port)")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .glass(in: .rect(cornerRadius: 10))
                        }
                    }
                    .frame(maxWidth: 360)
                }
                .frame(maxHeight: 420)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension MainView {
    /// List a host's workspaces; with none, start one in the home folder.
    static func openHost(_ connection: SavedConnection, _ sessionManager: SessionManager) async {
        await sessionManager.refreshWorkspaces(for: connection)
        let groups = sessionManager.sessionGroups.filter { $0.connectionId == connection.id }
        if let group = groups.first, let session = sessionManager.currentSession(of: group) {
            sessionManager.switchTo(session)
        } else if groups.isEmpty {
            await sessionManager.newWorkspace(on: connection, folder: "~")
        }
    }

    /// Show a pane: make it its workspace's pane, then switch to it.
    static func show(_ selection: PaneSelection, _ sessionManager: SessionManager) {
        sessionManager.selectPane(groupId: selection.groupId, paneId: selection.paneId)
        guard let group = sessionManager.sessionGroups.first(where: { $0.id == selection.groupId }),
              let session = sessionManager.currentSession(of: group) else { return }
        if sessionManager.activeSession?.id != session.id {
            sessionManager.switchTo(session)
        }
    }
}

extension View {
    /// Liquid glass on macOS 26, the blurred material before it
    @ViewBuilder
    func glass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}
