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
                let groups = sessionManager.orderedGroups(on: connection)
                Section {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        let pages = sessionManager.webTabs.filter { $0.workspaceId == group.id }
                        let next = index + 1 < groups.count ? groups[index + 1].id : nil
                        WorkspaceRow(group: group, images: sessionManager.windowImages[group.id]?.items.count ?? 0,
                                     shortcut: shortcuts[group.id],
                                     selected: selection.wrappedValue == .workspace(group.id),
                                     pages: pages,
                                     pageShown: pages.first { $0.id == sessionManager.activeWebTab?.id }?.id,
                                     beforeLit: next.map(isLit) ?? false)
                            .tag(SidebarItem.workspace(group.id))
                            .contextMenu {
                                Button("Open Port…") {
                                    window.portPickerWorkspace = group.id
                                    window.portPickerShown = true
                                }
                                if let recent = sessionManager.recentImages[group.id] {
                                    Button(recent.items.count == 1 ? "Reopen Image" : "Reopen \(recent.items.count) Images") {
                                        MainView.show(PaneSelection(groupId: group.id, paneId: group.activePaneId), sessionManager)
                                        sessionManager.reopenImages(group.id)
                                    }
                                }
                            }
                    }
                    .onMove { source, destination in move(in: groups, from: source, to: destination) }
                } header: {
                    HostHeader(connection: connection, pages: loosePages(on: connection))
                }
            }
        }
        .listStyle(.sidebar)
        // In the row of the window's buttons, where the toolbar was
        .safeAreaInset(edge: .top, spacing: 8) {
            HStack(spacing: 0) {
                SidebarToggle()
                    .padding(.leading, window.toggleLeading)
                Spacer()
                AddHostMenu()
                    .fixedSize()
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.trailing, 8)
            .frame(height: window.titleBarHeight)
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

    /// The workspace is shown, or a page it opened: its card is lit
    private func isLit(_ id: UUID) -> Bool {
        selection.wrappedValue == .workspace(id) || sessionManager.activeWebTab?.workspaceId == id
    }

    /// Pages opened outside any workspace shown here: rings in the host's header
    private func loosePages(on connection: SavedConnection) -> [WebTab] {
        let groupIds = Set(sessionManager.sessionGroups.map(\.id))
        return sessionManager.webTabs(on: connection).filter { $0.workspaceId.map { !groupIds.contains($0) } ?? true }
    }

    /// A workspace dragged to `destination`: it goes before the next workspace there,
    /// or after the host's last one
    private func move(in groups: [SessionGroup], from source: IndexSet, to destination: Int) {
        guard let index = source.first else { return }
        let moved = groups[index].id
        let next = groups[min(destination, groups.count)...].lazy.map(\.id).first { $0 != moved }
        sessionManager.moveWorkspace(moved, before: next, among: groups.map(\.id))
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

    var body: some View {
        Button { window.toggleSidebar() } label: {
            // The whole height of the title bar row, and some either side
            Image(systemName: "sidebar.left")
                .font(.callout)
                .frame(width: 28, height: window.titleBarHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(window.sidebar == .detailOnly ? "Show Sidebar (⌃⌘S)" : "Hide Sidebar (⌃⌘S)")
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

/// A workspace as a card, spaced like macOS Weather's cities: its name, and where the
/// temperature goes how long since you last typed in it (or since its agent finished);
/// beneath, what its agent is doing and a dot per pane. Hovered, its peek shows its
/// panes and pages beside the sidebar.
private struct WorkspaceRow: View {
    @EnvironmentObject private var sessionManager: SessionManager
    let group: SessionGroup
    /// Images its panes sent with `clauntty show`, waiting to be seen
    var images = 0
    /// Its Cmd+number, while Cmd is held
    var shortcut: String?
    /// Shown: its card is lit, with no line under it
    var selected = false
    /// The pages it opened (`clauntty tab`): a ring each after the pane dots; the peek lists them
    var pages: [WebTab] = []
    /// The one of them shown, if any: the card is lit
    var pageShown: UUID?
    /// The card under it is lit: no line between them either
    var beforeLit = false

    var body: some View {
        let (title, subtitle) = group.sidebarTitles
        let lead = leadPane
        let state = lead.flatMap { sessionManager.paneStates[$0.id] }
        let detail = (lead?.status ?? .none).detail(state: state, title: title, subtitle: subtitle)
        // The status glyph in the middle on the left; the title and its time, one line;
        // beneath it the task and the pane dots
        HStack(spacing: 9) {
            StatusGlyph(status: lead?.status ?? .none)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // Context for the state, not a headline: small and quiet, as Mail's times
                    // (a minute's tick, so "4m" becomes "5m" without anything else changing)
                    TimelineView(.everyMinute) { context in
                        Text(since(state).map { $0.shortAge(now: context.date) } ?? "")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .fixedSize()
                    .opacity(shortcut == nil ? 1 : 0)
                }
                HStack(spacing: 6) {
                    // Where it is when it has nothing to say; a space at worst: every card
                    // the same height
                    Text(detail ?? state?.place ?? " ")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
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
                    if group.panes.count > 1 || !pages.isEmpty {
                        PaneDots(panes: group.panes, activeId: group.activePaneId, pages: pages, pageShown: pageShown)
                    }
                }
            }
        }
        // Over the title's end while Cmd is held
        .overlay(alignment: .topTrailing) {
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        // A page of its shown: lit as the list lights the shown workspace
        .background {
            if pageShown != nil {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.1))
                    .padding(.horizontal, -6)
            }
        }
        .contentShape(Rectangle())
        // Its panes and pages beside the sidebar, when it has more than the card says
        .peekable(.workspace(group.id), when: group.panes.count > 1 || !pages.isEmpty)
        // A hairline between cards, short of their edges; none touching the lit one
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(selected || pageShown != nil || beforeLit ? 0 : 1))
                .frame(height: 1)
                .padding(.horizontal, 4)
                .offset(y: 3)
        }
        .help(subtitle.map { "\(title) · \($0)" } ?? title)
    }

    /// The pane the card speaks for: the one that needs you most, else the one shown
    private var leadPane: TabPane? {
        let shown = group.panes.first { $0.id == group.activePaneId } ?? group.panes.first
        guard let pressing = group.panes.max(by: { $0.status.urgency < $1.status.urgency }),
              let shown else { return shown }
        return pressing.status.urgency > shown.status.urgency ? pressing : shown
    }

    /// When its agent finished, while it's done; else when you last typed in any of its panes
    private func since(_ state: RemotePaneState?) -> Date? {
        if state?.state == "done", let doneAt = state?.doneAt {
            return Date(timeIntervalSince1970: Double(doneAt) / 1000)
        }
        return group.panes.compactMap { sessionManager.lastInteraction[$0.id] }.max()
    }

}

extension Date {
    /// How long before `now`: "now", "4m", "2h", "3d"
    func shortAge(now: Date) -> String {
        let seconds = max(now.timeIntervalSince(self), 0)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
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
/// the others orange when they need you and green when done. Then, a little apart, a
/// ring per page it opened; a shown page is an outlined capsule.
private struct PaneDots: View {
    let panes: [TabPane]
    let activeId: String
    var pages: [WebTab] = []
    /// The page shown, if it's one of these: then no pane is
    var pageShown: UUID?

    var body: some View {
        HStack(spacing: 5) {
            if !panes.isEmpty {
                HStack(spacing: 3) {
                    ForEach(panes.prefix(7), id: \.id) { pane in
                        let active = pageShown == nil && pane.id == activeId
                        Capsule()
                            .fill(color(pane, active: active))
                            .frame(width: active ? 10 : 4, height: 4)
                    }
                }
            }
            if !pages.isEmpty {
                HStack(spacing: 3) {
                    ForEach(pages.prefix(5)) { page in
                        let shown = page.id == pageShown
                        Capsule()
                            .strokeBorder(Color.primary.opacity(shown ? 0.9 : 0.45), lineWidth: 1)
                            .frame(width: shown ? 10 : 5, height: 5)
                    }
                }
            }
        }
        // Switching panes: the capsule springs across, as the phone's slides
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: activeId)
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: pageShown)
    }

    private func color(_ pane: TabPane, active: Bool) -> Color {
        if active { return .primary.opacity(0.9) }
        switch pane.status {
        case .blocked, .done: return pane.status.color
        default: return .primary.opacity(0.3)
        }
    }
}

extension View {
    /// Shows `subject`'s peek beside the sidebar while the pointer is over this (and
    /// `when` holds), placed by this view's frame in the window
    func peekable(_ subject: Peek.Subject, when: Bool = true) -> some View {
        modifier(Peekable(subject: subject, enabled: when))
    }
}

private struct Peekable: ViewModifier {
    @EnvironmentObject private var window: WindowState
    let subject: Peek.Subject
    let enabled: Bool
    @State private var frame: CGRect = .zero
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.frame(in: .global), initial: true) { _, new in
                        frame = new
                        window.cardFrames[subject] = enabled ? new : nil
                        if hovering { show() }
                    }
                }
            }
            .onHover { inside in
                hovering = inside
                if inside { show() } else if window.peekTarget?.subject == subject { window.peekTarget = nil }
            }
    }

    private func show() {
        window.peekTarget = enabled ? Peek(subject: subject, frame: frame) : nil
    }
}

extension RemotePaneState {
    /// Where a pane is, for one with nothing else to say: the program in front unless
    /// it's the shell, and the folder from home ("claude · ~/Projects/clauntty")
    var place: String? {
        let folder = Self.folder(cwd)
        let shells: Set = ["bash", "zsh", "fish", "sh", "dash", "login"]
        let program = fg.flatMap { $0.isEmpty || shells.contains($0.trimmingCharacters(in: ["-"])) ? nil : $0 }
        switch (program, folder) {
        case let (program?, folder?): return "\(program) · \(folder)"
        case let (program, folder): return program ?? folder
        }
    }

    /// A folder from home: "~/Projects/clauntty"
    static func folder(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        let home = parts.first == "Users" || parts.first == "home" ? 2 : parts.first == "root" ? 1 : 0
        guard home > 0, parts.count >= home else { return path }
        return (["~"] + parts.dropFirst(home)).joined(separator: "/")
    }
}

extension PaneStatus {
    /// What a pane is doing, beside its glyph (which says its state): the task, what it's
    /// waiting on when it needs you, or a shell's program; nil when there's nothing to say
    func detail(state: RemotePaneState?, title: String, subtitle: String?) -> String? {
        // Not when it's already the title (a workspace named after its folder takes it)
        let task = state?.task.flatMap { $0.isEmpty || title.hasPrefix($0) || $0.hasPrefix(title) ? nil : $0 }
        switch self {
        case .blocked: return state?.note.flatMap { $0.isEmpty ? nil : $0 } ?? task
        case .working, .done, .idle: return task
        case .none: return subtitle ?? state?.fg
        }
    }

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
/// Remove Host). Dragged by its name onto another host's header, the host takes that
/// one's place.
private struct HostHeader: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts
    let connection: SavedConnection
    /// Its pages that no workspace here opened: a ring each, and its peek lists them
    var pages: [WebTab] = []
    @State private var dropTargeted = false

    /// A dragged host, as text only these headers take
    private static let dragPrefix = "clauntty-host:"

    var body: some View {
        HStack(spacing: 0) {
            Text(connection.name.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
            menu
            Spacer(minLength: 0)
            if !pages.isEmpty {
                PaneDots(panes: [], activeId: "", pages: pages, pageShown: sessionManager.activeWebTab?.id)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .peekable(.host(connection.id))
                    .padding(.trailing, 16)
            }
        }
        // In line with the rows' status glyphs, and clear of the first row: the sections
        // are already spaced apart
        .padding(.leading, 2)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(dropTargeted ? 0.25 : 0))
                .padding(.horizontal, -6)
                .padding(.vertical, -2)
        }
        .draggable(Self.dragPrefix + connection.id.uuidString) {
            Text(connection.name.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first, item.hasPrefix(Self.dragPrefix),
                  let id = UUID(uuidString: String(item.dropFirst(Self.dragPrefix.count))) else { return false }
            hosts.move(id, to: connection.id)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var menu: some View {
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
            // Not a chevron: the section's own folds it, on hover. Only this opens the
            // menu: pressing the name starts a drag.
            Image(systemName: "ellipsis")
                .font(.caption2.weight(.semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Opens This Mac or another host from ~/.ssh/config: the + in the sidebar's toolbar.
private struct AddHostMenu: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts
    @EnvironmentObject private var window: WindowState

    var body: some View {
        Menu {
            if hosts.canOpenThisMac {
                Button("This Mac") {
                    let connection = hosts.openThisMac()
                    Task { await MainView.openHost(connection, sessionManager) }
                }
                Divider()
            }
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
                .frame(width: 28, height: window.titleBarHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .help("Open Host")
    }
}

/// Gives the window an empty compact toolbar, so its buttons sit a little lower and
/// further in than a bare title bar's, then measures them: the window's top rows (the
/// sidebar's and each pane's title bar) are as tall as twice the buttons' middle, and
/// the sidebar toggle sits just past them.
struct WindowButtonsRoom: NSViewRepresentable {
    @EnvironmentObject private var window: WindowState

    func makeNSView(context: Context) -> RoomView { RoomView() }

    func updateNSView(_ view: RoomView, context: Context) {
        view.onMeasure = { [window] height, end in
            if window.titleBarHeight != height { window.titleBarHeight = height }
            if window.buttonsEnd != end { window.buttonsEnd = end }
        }
    }

    final class RoomView: NSView {
        var onMeasure: ((_ height: CGFloat, _ buttonsEnd: CGFloat) -> Void)?
        private var watching: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            if window.toolbar == nil { window.toolbar = NSToolbar(identifier: "clauntty.buttons-room") }
            window.toolbarStyle = .unifiedCompact
            measure()
            // AppKit places the buttons after the toolbar changes, and again on resizes
            // and full screen: measure each time they move
            if let watching { NotificationCenter.default.removeObserver(watching) }
            guard let close = window.standardWindowButton(.closeButton) else { return }
            close.postsFrameChangedNotifications = true
            watching = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: close, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.measure() }
            }
        }

        /// Twice the close button's middle from the window's top, and the zoom button's
        /// right edge
        private func measure() {
            guard let window, let close = window.standardWindowButton(.closeButton),
                  let zoom = window.standardWindowButton(.zoomButton) else { return }
            let middle = window.frame.height - close.convert(close.bounds, to: nil).midY
            guard middle > 0 else { return }
            onMeasure?((middle * 2).rounded(), zoom.convert(zoom.bounds, to: nil).maxX.rounded())
        }
    }
}
