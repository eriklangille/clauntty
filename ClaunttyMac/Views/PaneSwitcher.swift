import SwiftUI

/// The window's own state: the switcher (Cmd+K) and a zoomed pane.
@MainActor
final class WindowState: ObservableObject {
    @Published var switcherShown = false
    /// Open Port: shown, and for which workspace (nil: the one shown)
    @Published var portPickerShown = false
    var portPickerWorkspace: UUID?
    /// A pane shown alone in its split (Cmd+Shift+Return); the host's layout is unchanged
    @Published var zoomedPane: String?
    /// The sidebar, shown or not; change it with `toggleSidebar()`
    @Published var sidebar: NavigationSplitViewVisibility = .all
    /// Cmd held down on its own: the sidebar shows each workspace's Cmd+number
    @Published private(set) var commandHeld = false
    /// The sidebar card (or host's pages) the pointer is over. Its peek shows beside the
    /// sidebar while the pointer is on it or on the peek.
    @Published var peekTarget: Peek? { didSet { if let peekTarget, peekTarget != peek { peek = peekTarget } } }
    /// The last one, which the peek shows while the pointer is over the peek itself
    @Published private(set) var peek: Peek?
    @Published var peekHovered = false
    /// The window's top rows (the sidebar's, each pane's title bar): as tall as twice
    /// the window buttons' middle, measured by `WindowButtonsRoom`
    @Published var titleBarHeight: CGFloat = 38
    /// The window buttons' right edge, from the window's left
    @Published var buttonsEnd: CGFloat = 78
    /// The sidebar toggle's place, just past the window's buttons: in the sidebar's top
    /// row, or the top-left pane's title bar when the sidebar is hidden
    var toggleLeading: CGFloat { buttonsEnd + 14 }
    /// The pane whose row in the peek is under the pointer: outlined on the terminal side
    @Published var peekPane: PaneSelection?
    /// The terminal side of the window, in global coordinates, for that outline
    @Published var detailFrame: CGRect = .zero
    /// Not over the switcher or Open Port
    var peekShown: Bool { (peekTarget != nil || peekHovered) && !switcherShown && !portPickerShown }
    /// Each sidebar card's frame in the window (kept by `peekable`): Cmd+number shows a
    /// card's peek without the pointer on it
    var cardFrames: [Peek.Subject: CGRect] = [:]
    /// The workspace whose peek Cmd+number showed: it stays while Cmd is held, and
    /// Cmd+arrows move through its panes and pages
    @Published private(set) var keyPeek: UUID?
    /// Shows the pane or page `offset` from the shown one in a workspace (set by the
    /// main view)
    var movePane: ((_ groupId: UUID, _ offset: Int) -> Void)?

    private var keyMonitor: Any?
    private var arrowMonitor: Any?

    init() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.keyEvent(event)
            return event
        }
        // Cmd+arrows while a Cmd+number peek is up: its panes, not the terminal's
        arrowMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let group = self.keyPeek, event.modifierFlags.contains(.command) else { return event }
            let offset: Int
            switch event.keyCode {
            case 123, 126: offset = -1  // left, up
            case 124, 125: offset = 1   // right, down
            default: return event
            }
            self.movePane?(group, offset)
            return nil
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hideShortcuts()
                self?.endKeyPeek()
            }
        }
    }

    /// A workspace's peek beside its card while Cmd is held, its shown pane outlined.
    /// Only from the keyboard: picked from the menu with the mouse, no Cmd will let go.
    func showKeyPeek(_ groupId: UUID, paneId: String) {
        guard NSApp.currentEvent?.modifierFlags.contains(.command) == true,
              let frame = cardFrames[.workspace(groupId)] else { return }
        keyPeek = groupId
        peekTarget = Peek(subject: .workspace(groupId), frame: frame)
        peekPane = PaneSelection(groupId: groupId, paneId: paneId)
    }

    private func endKeyPeek() {
        guard let group = keyPeek else { return }
        keyPeek = nil
        if peekTarget?.subject == .workspace(group) { peekTarget = nil }
        peekPane = nil
    }

    /// Shown as Cmd goes down, so you can press one number after another while holding
    /// it; another modifier with it (a Cmd+Shift shortcut) hides them. Cmd let go ends a
    /// Cmd+number peek.
    private func keyEvent(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.contains(.command) { endKeyPeek() }
        guard flags == .command else { return hideShortcuts() }
        if !commandHeld { commandHeld = true }
    }

    private func hideShortcuts() {
        if commandHeld { commandHeld = false }
    }

    /// Terminals keep their size while the sidebar slides and resize once at the end:
    /// a TUI redraws badly at every step in between
    func toggleSidebar() {
        PaneHostView.holdResizes()
        withAnimation { sidebar = sidebar == .detailOnly ? .all : .detailOnly }
    }
}

/// Cmd+K: type part of a pane, workspace or host name, Enter goes there. Arrows
/// move, Esc closes.
struct PaneSwitcher: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts
    @EnvironmentObject private var window: WindowState
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var fieldFocused: Bool

    private struct Item: Identifiable {
        let id: PaneSelection
        let title: String
        /// Workspace, and host when there's more than one
        let place: String
        let status: PaneStatus
        let isShown: Bool
    }

    /// Every pane in sidebar order, those matching every word of the query
    private var items: [Item] {
        let words = query.lowercased().split(separator: " ")
        let shownPane = sessionManager.activeSession?.pane?.paneId
        return PaneCommands.groups(sessionManager, hosts).flatMap { group -> [Item] in
            let host = hosts.opened.count > 1 ? hosts.opened.first { $0.id == group.connectionId }?.name : nil
            let place = [group.panes.count > 1 ? group.title : nil, host].compactMap { $0 }.joined(separator: " · ")
            return group.panes.map { pane in
                Item(id: PaneSelection(groupId: group.id, paneId: pane.id),
                     title: group.panes.count > 1 ? pane.title : group.title,
                     place: place, status: pane.status, isShown: pane.id == shownPane)
            }
        }
        .filter { item in
            let text = "\(item.title) \(item.place)".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            TextField("Go to pane", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .focused($fieldFocused)
                .onSubmit { choose(items) }
                .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                .onKeyPress(.escape) { window.switcherShown = false; return .handled }
            Divider()
            if items.isEmpty {
                Text("No panes match")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, highlighted: index == selected)
                                    .onTapGesture {
                                        selected = index
                                        choose(items)
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selected) { _, index in
                        if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                    }
                }
            }
        }
        .frame(width: 520)
        .glass(in: .rect(cornerRadius: 14))
        // After the terminal has let go of the keyboard
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    private func row(_ item: Item, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            StatusGlyph(status: item.status)
                .frame(width: 18)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if !item.place.isEmpty {
                Text(item.place)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            // The status is the glyph's
            if item.isShown {
                Text("Shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(highlighted ? Color.accentColor.opacity(0.35) : .clear, in: .rect(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func move(_ offset: Int, in items: [Item]) {
        guard !items.isEmpty else { return }
        selected = (selected + offset + items.count) % items.count
    }

    private func choose(_ items: [Item]) {
        guard items.indices.contains(selected) else { return }
        window.switcherShown = false
        MainView.show(items[selected].id, sessionManager)
    }
}
