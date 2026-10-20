import SwiftUI

/// The tab the shown pane is in, its panes split as rtach keeps them, each under a
/// title bar with its actions (as in Rex); the window has no other. The pane you type
/// into is the active session; clicking another moves there. A zoomed pane fills the
/// tab by itself.
struct SplitPanes: View {
    @EnvironmentObject private var window: WindowState
    let group: SessionGroup
    let views: TerminalViews

    var body: some View {
        let layout = group.shownLayout
        let zoomed = window.zoomedPane == group.activePaneId && layout.paneIds.count > 1
        LayoutNode(layout: zoomed ? .pane(group.activePaneId) : layout, group: group, views: views,
                   split: layout.paneIds.count > 1, zoomed: zoomed, topLeft: true)
    }
}

private struct LayoutNode: View {
    let layout: PaneLayout
    let group: SessionGroup
    let views: TerminalViews
    let split: Bool
    let zoomed: Bool
    /// Its title bar is under the window's buttons when the sidebar is hidden
    let topLeft: Bool

    var body: some View {
        switch layout {
        case .pane(let paneId):
            PaneTile(group: group, paneId: paneId, views: views, split: split, zoomed: zoomed, topLeft: topLeft)
        case .split(let vertical, let ratio, let first, let second):
            GeometryReader { geometry in
                let total = vertical ? geometry.size.height : geometry.size.width
                let firstSize = max(0, (total - SplitDivider.thickness) * min(max(ratio, 0.1), 0.9))
                if vertical {
                    VStack(spacing: 0) {
                        node(first, topLeft: topLeft).frame(height: firstSize)
                        SplitDivider(vertical: true)
                        node(second, topLeft: false)
                    }
                } else {
                    HStack(spacing: 0) {
                        node(first, topLeft: topLeft).frame(width: firstSize)
                        SplitDivider(vertical: false)
                        node(second, topLeft: false)
                    }
                }
            }
        }
    }

    private func node(_ layout: PaneLayout, topLeft: Bool) -> LayoutNode {
        LayoutNode(layout: layout, group: group, views: views, split: split, zoomed: zoomed, topLeft: topLeft)
    }
}

/// A line between two panes; stacked panes get a horizontal one
private struct SplitDivider: View {
    static let thickness: CGFloat = 1
    let vertical: Bool

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: vertical ? nil : Self.thickness, height: vertical ? Self.thickness : nil)
    }
}

private struct PaneTile: View {
    @EnvironmentObject private var sessionManager: SessionManager
    let group: SessionGroup
    let paneId: String
    let views: TerminalViews
    let split: Bool
    let zoomed: Bool
    let topLeft: Bool

    var body: some View {
        let focused = paneId == group.activePaneId
        let selection = PaneSelection(groupId: group.id, paneId: paneId)
        VStack(spacing: 0) {
            if let pane = group.panes.first(where: { $0.id == paneId }) {
                PaneHeader(pane: pane, selection: selection, focused: focused, split: split, zoomed: zoomed,
                           topLeft: topLeft)
            }
            if let session = sessionManager.sessions.first(where: { $0.groupId == group.id && $0.pane?.paneId == paneId }) {
                ZStack {
                    TerminalContainer(session: session, views: views, focused: focused) {
                        MainView.show(selection, sessionManager)
                    }
                    TerminalStatusOverlay(session: session) {
                        Task { try? await sessionManager.reconnect(session: session) }
                    }
                    // The title bar marks the pane you're in; this just recedes the others
                    Color.black.opacity(focused ? 0 : 0.15)
                        .allowsHitTesting(false)
                        .animation(.easeOut(duration: 0.2), value: focused)
                }
                .clipped()
            } else {
                ThemeColors.background
            }
        }
        .background(ThemeColors.background)
    }
}

/// Over each pane: what's running in it, and its actions. The window has no title
/// bar, so these are it: dragging one moves the window.
struct PaneHeader: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var window: WindowState
    /// The window's title bar height, so the window's buttons sit in the top one
    static let height: CGFloat = 28
    private static let padding: CGFloat = 10
    let pane: TabPane
    let selection: PaneSelection
    let focused: Bool
    /// One of several panes: dimmed when it's not the focused one, and it can zoom
    let split: Bool
    let zoomed: Bool
    let topLeft: Bool

    var body: some View {
        let active = focused || !split
        HStack(spacing: 8) {
            if topLeft && window.sidebar == .detailOnly {
                SidebarToggle()
                    .padding(.leading, SidebarToggle.leading - Self.padding)
            }
            Group {
                StatusGlyph(status: pane.status)
                Text(pane.title)
                    .font(.callout.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Clicks go through to the drag area behind
            .allowsHitTesting(false)
            Spacer(minLength: 8)
            Group {
                button("rectangle.split.2x1", help: "Split Right (⌘D)") { splitPane(.split) }
                button("rectangle.split.1x2", help: "Split Down (⇧⌘D)") { splitPane(.splitDown) }
                if split {
                    button(zoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                           help: zoomed ? "Show All Panes (⇧⌘↩)" : "Zoom Pane (⇧⌘↩)") {
                        MainView.show(selection, sessionManager)
                        window.zoomedPane = zoomed ? nil : selection.paneId
                    }
                }
                button("xmark", help: "Close Pane (⇧⌘W)") {
                    MainView.closePane(selection, title: pane.title, sessionManager)
                }
            }
            .foregroundStyle(active ? .secondary : .tertiary)
        }
        .padding(.horizontal, Self.padding)
        .frame(height: Self.height)
        .background {
            ZStack {
                active ? Color.white.opacity(0.07) : Color.white.opacity(0.02)
                WindowDragArea { MainView.show(selection, sessionManager) }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                .allowsHitTesting(false)
        }
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Split this pane, not the one you were in
    private func splitPane(_ action: PaneAction) {
        MainView.show(selection, sessionManager)
        Task { await sessionManager.performPaneAction(action, groupId: selection.groupId) }
    }
}

extension SessionGroup {
    /// The layout of the tab its active pane is in; just that pane until the host lists it
    var shownLayout: PaneLayout {
        layouts.first { $0.paneIds.contains(activePaneId) } ?? .pane(activePaneId)
    }
}

extension SessionManager {
    /// The shown tab's split layout comes from listing the host's workspaces. If that
    /// failed (no network yet at launch, Local Network not allowed yet), list them again
    /// once its pane has connected, or the tab shows just that pane.
    func refreshLayoutIfMissing() {
        guard let active = activeSession, active.state == .connected,
              let group = sessionGroup(for: active), group.layouts.isEmpty else { return }
        Task { await refreshWorkspaces(for: active.connectionConfig) }
    }

    /// Every pane in the shown tab streams, not just the active one, and while you're
    /// at the Mac they take this window's size. Panes that left the screen pause, as a
    /// tab you leave on the phone does.
    func showSplitPanes() {
        guard let active = activeSession, let group = sessionGroup(for: active) else { return }
        let shown = group.shownLayout.paneIds.compactMap {
            paneSession(for: group, paneId: $0, config: active.connectionConfig)
        }
        let shownIds = Set(shown.map(\.id))
        for session in sessions where shownTogether.contains(session.id) && !shownIds.contains(session.id) {
            session.pauseOutput()
        }
        shownTogether = shownIds

        for session in shown where session.id != active.id {
            if session.state == .disconnected || (session.state == .connected && !session.hasAttachedChannel) {
                Task { try? await reconnect(session: session) }
            } else {
                session.resumeOutput()
            }
        }
        // A pane opened from the phone shows here too, but the phone keeps its size
        guard NSApplication.shared.isActive else { return }
        for session in shown where session.id != active.id {
            session.claimActive()
        }
        // Last, so commands from the host (`clauntty show`) go to the pane you're in
        active.claimActive()
    }
}

/// Where a title bar would be: dragging moves the window, a click calls `onClick`, a
/// double click does what System Settings says a title bar's does (zoom by default).
struct WindowDragArea: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.onClick = onClick
    }

    final class DragView: NSView {
        var onClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": window.miniaturize(nil)
                case "None": break
                default: window.zoom(nil)
                }
                return
            }
            onClick?()
            window.performDrag(with: event)
        }
    }
}
