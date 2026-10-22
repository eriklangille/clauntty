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
    @AppStorage(PaneCommands.numberKeysKey) private var numberKeys = PaneCommands.NumberKeys.workspace

    var body: some View {
        let shortcuts = window.commandHeld ? shortcuts() : [:]
        List(selection: selection) {
            ForEach(hosts.opened) { connection in
                let rows = rows(on: connection)
                Section {
                    ForEach(rows) { row in
                        switch row {
                        case .workspace(let group):
                            WorkspaceRow(group: group, images: sessionManager.windowImages[group.id]?.items.count ?? 0,
                                         shortcut: shortcuts[group.id])
                                .tag(SidebarItem.workspace(group.id))
                        case .web(let webTab, let nested):
                            WebTabRow(webTab: webTab)
                                .padding(.leading, nested ? WorkspaceRow.titleInset : 0)
                                // They go with their workspace
                                .moveDisabled(true)
                        }
                    }
                    .onMove { source, destination in move(in: rows, from: source, to: destination) }
                } header: {
                    HostHeader(connection: connection)
                }
            }
        }
        .listStyle(.sidebar)
        // In the row of the window's buttons, where the toolbar was
        .safeAreaInset(edge: .top, spacing: 8) {
            HStack(spacing: 0) {
                SidebarToggle()
                    .padding(.leading, SidebarToggle.leading)
                Spacer()
                AddHostMenu()
                    .fixedSize()
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.trailing, 12)
            .frame(height: PaneHeader.height)
        }
        // The window has no title bar: that row is ours
        .ignoresSafeArea(.container, edges: .top)
    }

    /// Each workspace's Cmd+number, as the Pane menu counts them: ⌘4, or ⌘4–6 for its
    /// panes when the numbers go to panes. Only 1 to 9.
    private func shortcuts() -> [UUID: String] {
        var labels: [UUID: String] = [:]
        var next = 1
        for group in PaneCommands.groups(sessionManager, hosts) {
            let count = numberKeys == .workspace ? 1 : group.panes.count
            let last = min(next + count - 1, 9)
            if next <= 9 {
                labels[group.id] = last > next ? "⌘\(next)–\(last)" : "⌘\(next)"
            }
            next += count
        }
        return labels
    }

    /// A host's workspaces in your order, each followed by the pages it opened, then
    /// pages opened outside any workspace shown here
    private func rows(on connection: SavedConnection) -> [SidebarRow] {
        let groups = sessionManager.orderedGroups(on: connection)
        var rows: [SidebarRow] = []
        for group in groups {
            rows.append(.workspace(group))
            for webTab in sessionManager.webTabs where webTab.workspaceId == group.id {
                rows.append(.web(webTab, nested: true))
            }
        }
        let groupIds = Set(sessionManager.sessionGroups.map(\.id))
        for webTab in sessionManager.webTabs(on: connection) where webTab.workspaceId.map({ !groupIds.contains($0) }) ?? true {
            rows.append(.web(webTab, nested: false))
        }
        return rows
    }

    /// A workspace dragged to `destination`: it goes before the next workspace there,
    /// or after the host's last one
    private func move(in rows: [SidebarRow], from source: IndexSet, to destination: Int) {
        guard let index = source.first, case .workspace(let moved) = rows[index] else { return }
        let workspaces = rows.compactMap(\.groupId)
        let next = rows[min(destination, rows.count)...].lazy.compactMap(\.groupId).first { $0 != moved.id }
        sessionManager.moveWorkspace(moved.id, before: next, among: workspaces)
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

/// Shows or hides the sidebar. In the same place either way, just past the window's
/// buttons: in the sidebar when it's shown, else in the top-left title bar.
struct SidebarToggle: View {
    @EnvironmentObject private var window: WindowState
    /// From the window's left edge
    static let leading: CGFloat = 78

    var body: some View {
        Button { window.toggleSidebar() } label: {
            Image(systemName: "sidebar.left")
                .font(.callout)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(window.sidebar == .detailOnly ? "Show Sidebar (⌃⌘S)" : "Hide Sidebar (⌃⌘S)")
    }
}

/// A row in a host's section
private enum SidebarRow: Identifiable {
    case workspace(SessionGroup)
    case web(WebTab, nested: Bool)

    var id: UUID {
        switch self {
        case .workspace(let group): return group.id
        case .web(let webTab, _): return webTab.id
        }
    }

    var groupId: UUID? {
        if case .workspace(let group) = self { return group.id }
        return nil
    }
}

extension SessionManager {
    /// A host's workspaces in the host's order (the tab order follows it), which a drag
    /// here or on another device changes
    func orderedGroups(on connection: SavedConnection) -> [SessionGroup] {
        let rank = Dictionary(tabOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return sessionGroups.enumerated()
            .filter { $0.element.connectionId == connection.id }
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// Move a workspace before `next`, or after the last of `workspaces` (its host's)
    func moveWorkspace(_ id: UUID, before next: UUID?, among workspaces: [UUID]) {
        var order = tabOrder
        for workspace in workspaces where !order.contains(workspace) {
            order.append(workspace)
        }
        order.removeAll { $0 == id }
        let index: Int
        if let next, let nextIndex = order.firstIndex(of: next) {
            index = nextIndex
        } else if let last = workspaces.last(where: { $0 != id }), let lastIndex = order.firstIndex(of: last) {
            index = lastIndex + 1
        } else {
            index = order.count
        }
        order.insert(id, at: index)
        tabOrder = order
        saveTabOrder()
        moveWorkspaceOnHost(id)
    }
}

/// A workspace: its name (or what's running, for one named after a folder), its most
/// pressing status, and a dot per pane as on the phone's tab.
private struct WorkspaceRow: View {
    let group: SessionGroup
    /// Images its panes sent with `clauntty show`, waiting to be seen
    var images = 0
    /// Its Cmd+number, while Cmd is held
    var shortcut: String?
    private static let glyphSpacing: CGFloat = 9
    /// Where the title starts, for the rows nested under it
    static let titleInset = StatusGlyph.defaultSize + glyphSpacing

    var body: some View {
        let (title, subtitle) = group.sidebarTitles
        // One line, so every row is the same height; what runs in a named workspace is
        // in its pane's title bar, and in the tooltip
        HStack(spacing: Self.glyphSpacing) {
            StatusGlyph(status: group.mostPressingStatus)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            if images > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "photo")
                    if images > 1 { Text("\(images)") }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .transition(.opacity)
                .help(images == 1 ? "An image to see" : "\(images) images to see")
            }
            if group.panes.count > 1 {
                PaneDots(panes: group.panes, activeId: group.activePaneId)
                    .opacity(shortcut == nil ? 1 : 0)
            }
        }
        // Over the row's end, so the title keeps its room
        .overlay(alignment: .trailing) {
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 2)
        .help(subtitle.map { "\(title) · \($0)" } ?? title)
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
    static let defaultSize: CGFloat = 10
    let status: PaneStatus
    var size: CGFloat = defaultSize

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
        // Switching panes: the capsule springs across, as the phone's slides
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: activeId)
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

/// The host's name in small caps, with a "…": its menu (New Workspace, Refresh,
/// Remove Host).
private struct HostHeader: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts
    let connection: SavedConnection

    var body: some View {
        Menu {
            Button("New Workspace") {
                Task { await sessionManager.newWorkspace(on: connection, folder: "~") }
            }
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
            HStack(spacing: 4) {
                Text(connection.name.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                // Not a chevron: the section's own folds it, on hover
                Image(systemName: "ellipsis")
                    .font(.caption2.weight(.semibold))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        // In line with the rows' status glyphs, and clear of the first row: the sections
        // are already spaced apart
        .padding(.leading, 2)
        .padding(.bottom, 4)
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
