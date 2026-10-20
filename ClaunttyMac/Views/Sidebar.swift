import SwiftUI

/// What the sidebar selects: a workspace (its tab, split as on the host), or a web
/// page from a port on the host.
enum SidebarItem: Hashable {
    case workspace(UUID)
    case web(UUID)
}

/// Hosts, each with one row per workspace: what's running in it, the phone's status
/// glyph, and its pane dots. The panes themselves are in the split. Web pages sit
/// under the workspace that opened them.
struct Sidebar: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts
    @EnvironmentObject private var window: WindowState

    var body: some View {
        List(selection: selection) {
            ForEach(hosts.opened) { connection in
                Section {
                    ForEach(groups(on: connection)) { group in
                        WorkspaceRow(group: group)
                            .tag(SidebarItem.workspace(group.id))
                        ForEach(sessionManager.webTabs.filter { $0.workspaceId == group.id }) { webTab in
                            WebTabRow(webTab: webTab)
                                .padding(.leading, 26)
                        }
                    }
                    // Opened outside any workspace shown here
                    ForEach(looseWebTabs(on: connection)) { webTab in
                        WebTabRow(webTab: webTab)
                    }
                } header: {
                    HostHeader(connection: connection)
                }
            }
        }
        .listStyle(.sidebar)
        // In the row of the window's buttons, where the toolbar was
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                Spacer()
                Button { window.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                    .help("Hide Sidebar (⌃⌘S)")
                AddHostMenu()
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: PaneHeader.height)
        }
        // The window has no title bar: that row is ours
        .ignoresSafeArea(.container, edges: .top)
    }

    private func groups(on connection: SavedConnection) -> [SessionGroup] {
        sessionManager.sessionGroups.filter { $0.connectionId == connection.id }
    }

    private func looseWebTabs(on connection: SavedConnection) -> [WebTab] {
        let groupIds = Set(sessionManager.sessionGroups.map(\.id))
        return sessionManager.webTabs(on: connection).filter { webTab in
            webTab.workspaceId.map { !groupIds.contains($0) } ?? true
        }
    }

    /// The workspace or page shown, as the list's selection; picking a row shows it.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if let webTab = sessionManager.activeWebTab { return .web(webTab.id) }
                return sessionManager.activeSession?.groupId.map { .workspace($0) }
            },
            set: { newValue in
                switch newValue {
                case .workspace(let id):
                    guard let group = sessionManager.sessionGroups.first(where: { $0.id == id }) else { return }
                    MainView.show(PaneSelection(groupId: id, paneId: group.activePaneId), sessionManager)
                case .web(let id):
                    if let webTab = sessionManager.webTabs.first(where: { $0.id == id }) {
                        sessionManager.switchTo(webTab)
                    }
                case nil:
                    break
                }
            }
        )
    }
}

/// A workspace: what's running in the pane it shows, its most pressing status, and a
/// dot per pane as on the phone's tab.
private struct WorkspaceRow: View {
    let group: SessionGroup

    var body: some View {
        let (title, subtitle) = group.sidebarTitles
        HStack(alignment: .top, spacing: 10) {
            // Centred on the title's line
            StatusGlyph(status: group.mostPressingStatus)
                .frame(width: 18, height: 17)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if group.panes.count > 1 {
                        PaneDots(panes: group.panes, activeId: group.activePaneId)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

extension SessionGroup {
    /// The workspace's name and what's running in the pane it shows. Workspaces named
    /// after a folder (`~`, a path) take the running thing's name instead.
    var sidebarTitles: (title: String, subtitle: String?) {
        let shown = panes.first { $0.id == activePaneId } ?? panes.first
        let paneTitle = shown?.title ?? ""
        guard !title.isEmpty, title != "~", !title.hasPrefix("/") else {
            return (paneTitle.isEmpty || paneTitle == "~" ? "shell" : paneTitle, nil)
        }
        // A shell at home says nothing more than the name
        return (title, paneTitle == title || paneTitle == "~" || paneTitle.isEmpty ? nil : paneTitle)
    }
}

/// The phone's status indicator (`PaneStatusIndicator`): a spinning arc while working,
/// a pulsing orange dot when it needs you, green when done, a hollow ring when idle, a
/// small dot for a pane with no agent.
struct StatusGlyph: View {
    let status: PaneStatus
    var size: CGFloat = 10

    var body: some View {
        Group {
            switch status {
            case .idle:
                Circle().strokeBorder(status.color, lineWidth: 1.5)
            case .working:
                Spinning(color: status.color)
            case .blocked:
                Pulsing { Circle().fill(status.color).padding(size * 0.1) }
            case .done:
                Circle().fill(status.color).padding(size * 0.1)
            case .none:
                Circle().fill(status.color).padding(size * 0.3)
            }
        }
        .frame(width: size, height: size)
        // A new status starts its own animation
        .id(status)
    }

    private struct Spinning: View {
        let color: Color
        @State private var turned = false

        var body: some View {
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .padding(0.75)
                .rotationEffect(.degrees(turned ? 360 : 0))
                .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turned)
                .onAppear { turned = true }
        }
    }

    private struct Pulsing<Content: View>: View {
        @ViewBuilder let content: Content
        @State private var faded = false

        var body: some View {
            content
                .opacity(faded ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: faded)
                .onAppear { faded = true }
        }
    }
}

/// One dot per pane, as under the phone's tab title: the shown pane a short capsule,
/// the others orange when they need you and green when done.
private struct PaneDots: View {
    let panes: [TabPane]
    let activeId: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(panes.prefix(7), id: \.id) { pane in
                let active = pane.id == activeId
                Capsule()
                    .fill(color(pane, active: active))
                    .frame(width: active ? 10 : 4, height: 4)
            }
        }
    }

    private func color(_ pane: TabPane, active: Bool) -> Color {
        if active { return .primary.opacity(0.9) }
        switch pane.status {
        case .blocked, .done: return pane.status.color
        default: return .primary.opacity(0.3)
        }
    }
}

/// A forwarded port's page; closing it stops the forward.
private struct WebTabRow: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @ObservedObject var webTab: WebTab

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(webTab.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            // The title is the port until the page has loaded once
            if webTab.title != ":\(String(webTab.remotePort.port))" {
                Text(":\(String(webTab.remotePort.port))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .tag(SidebarItem.web(webTab.id))
        .contextMenu {
            Button("Close Page") { sessionManager.closeWebTab(webTab) }
        }
    }
}

extension PaneStatus {
    /// The phone's status colours
    var color: Color {
        switch self {
        case .none: return .primary.opacity(0.35)
        case .idle: return .primary.opacity(0.6)
        case .working: return .cyan
        case .blocked: return .orange
        case .done: return .green
        }
    }

    /// Which of two statuses to show for a workspace: what needs you first
    fileprivate var urgency: Int {
        switch self {
        case .blocked: return 4
        case .done: return 3
        case .working: return 2
        case .idle: return 1
        case .none: return 0
        }
    }
}

extension SessionGroup {
    /// What needs you most among its panes: one waiting on you beats one that's done,
    /// which beats one working
    var mostPressingStatus: PaneStatus {
        panes.map(\.status).max { $0.urgency < $1.urgency } ?? .none
    }
}

/// The host's name in small caps; New Workspace and its menu show on hover.
private struct HostHeader: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts
    let connection: SavedConnection
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(connection.name.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
            Spacer()
            Group {
                Button {
                    Task { await sessionManager.newWorkspace(on: connection, folder: "~") }
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Workspace")
                Menu {
                    Button("Refresh") {
                        Task { await sessionManager.refreshWorkspaces(for: connection) }
                    }
                    Divider()
                    Button("Remove Host", role: .destructive) {
                        // Its workspaces leave the sidebar; the panes keep running on the host
                        sessionManager.applyWorkspaces([], hostName: nil, config: connection)
                        for session in sessionManager.sessions where session.connectionConfig.id == connection.id {
                            sessionManager.closeSession(session, killRemote: false)
                        }
                        hosts.remove(connection)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.top, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Opens another host from ~/.ssh/config: the + in the sidebar's toolbar.
private struct AddHostMenu: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts

    var body: some View {
        Menu {
            if hosts.addable.isEmpty {
                Text("No other hosts in ~/.ssh/config")
            }
            ForEach(hosts.addable) { host in
                Button(host.alias) {
                    let connection = hosts.open(host)
                    Task { await MainView.openHost(connection, sessionManager) }
                }
            }
            Divider()
            Button("Reload ~/.ssh/config") { hosts.reload() }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .help("Open Host")
    }
}
