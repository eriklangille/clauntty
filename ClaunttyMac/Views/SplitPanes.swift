import SwiftUI

/// The tab the shown pane is in, its panes split as rtach keeps them, each under a
/// title bar with its actions (as in Rex); the window has no other. The pane you type
/// into is the active session; clicking another moves there. A zoomed pane fills the
/// tab by itself. Dragging a divider resizes the split, on the host too. Dragging a
/// pane by its title onto another puts it on the side of that pane it's dropped nearest.
struct SplitPanes: View {
    @EnvironmentObject private var window: WindowState
    @EnvironmentObject private var sessionManager: SessionManager
    let group: SessionGroup
    let views: TerminalViews
    /// The pane dragged by its title, and where the pointer is
    @State private var dragged: PaneDrag?

    var body: some View {
        let layout = group.shownLayout
        let split = layout.paneIds.count > 1
        let zoomed = window.zoomedPane == group.activePaneId && split
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            LayoutNode(layout: zoomed ? .pane(group.activePaneId) : layout, group: group, views: views,
                       split: split, zoomed: zoomed, topLeft: true,
                       paneDrag: split && !zoomed ? dragHandler(layout: layout, bounds: bounds) : nil)
                .overlay {
                    if let dragged, let from = layout.frame(of: dragged.pane, in: bounds),
                       let pane = group.panes.first(where: { $0.id == dragged.pane }) {
                        DragOverlay(pane: pane, drag: dragged, from: from, drop: layout.drop(dragged, in: bounds),
                                    headerHeight: window.titleBarHeight)
                            .transition(.opacity)
                    }
                }
        }
        .coordinateSpace(name: PaneDrag.space)
        // A drag belongs to the tab it started in
        .onChange(of: group.id) { _, _ in dragged = nil }
    }

    private func dragHandler(layout: PaneLayout, bounds: CGRect) -> PaneDragHandler {
        PaneDragHandler(dragged: dragged?.pane) { pane, point in
            dragged = PaneDrag(pane: pane, start: dragged?.pane == pane ? dragged!.start : point, point: point)
        } ended: {
            if let dragged, let drop = layout.drop(dragged, in: bounds) {
                sessionManager.movePane(groupId: group.id, pane: dragged.pane, beside: drop.pane, side: drop.side)
            }
            withAnimation(.easeOut(duration: 0.15)) { dragged = nil }
        }
    }
}

/// A pane being dragged by its title, the pointer in `SplitPanes`' space
private struct PaneDrag {
    static let space = "splitPanes"
    let pane: String
    /// Where the drag began
    let start: CGPoint
    let point: CGPoint
}

/// What a pane's title reports while it's dragged: the pane and the pointer, then that
/// it's let go
struct PaneDragHandler {
    /// The pane being dragged, whose title is lifted out of its header
    let dragged: String?
    let moved: (String, CGPoint) -> Void
    let ended: () -> Void
}

/// Where a dragged pane would go: on `side` of `pane`, taking `frame`
private struct PaneDrop: Equatable {
    let pane: String
    let side: PaneSide
    let frame: CGRect
}

private extension PaneLayout {
    /// The pane under the pointer, other than the dragged one, and the side of it the
    /// pointer is nearest: the half the dragged pane would take
    func drop(_ drag: PaneDrag, in bounds: CGRect) -> PaneDrop? {
        guard paneIds.contains(drag.pane), let hit = paneIds.lazy
            .compactMap({ id in self.frame(of: id, in: bounds).map { (pane: id, frame: $0) } })
            .first(where: { $0.pane != drag.pane && $0.frame.contains(drag.point) }) else { return nil }
        let (pane, frame) = hit
        let x = (drag.point.x - frame.minX) / max(frame.width, 1)
        let y = (drag.point.y - frame.minY) / max(frame.height, 1)
        let side = [(PaneSide.left, x), (.right, 1 - x), (.up, y), (.down, 1 - y)].min { $0.1 < $1.1 }!.0
        let half: CGRect = switch side {
        case .left: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .up: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .down: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
        return PaneDrop(pane: pane, side: side, frame: half)
    }
}

/// While a pane is dragged: the pane it leaves dimmed, the half of another it would
/// take, and its title, lifted out of its header into a chip under the pointer
private struct DragOverlay: View {
    let pane: TabPane
    let drag: PaneDrag
    let from: CGRect
    let drop: PaneDrop?
    let headerHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.3)
                .frame(width: from.width, height: from.height)
                .offset(x: from.minX, y: from.minY)
            if let drop {
                PaneOutline()
                    .frame(width: drop.frame.width, height: drop.frame.height)
                    .offset(x: drop.frame.minX, y: drop.frame.minY)
                    .animation(.easeOut(duration: 0.12), value: drop)
            }
            DragChip(pane: pane, drag: drag,
                     header: CGRect(x: from.minX, y: from.minY, width: from.width, height: headerHeight))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// A dragged pane's title: it starts as its header, where the header was, and springs
/// into a chip the size of its glyph and title, the point that was grabbed under the
/// pointer
private struct DragChip: View {
    @EnvironmentObject private var ghostty: MacGhosttyApp
    private static let height: CGFloat = 30
    private static let padding: CGFloat = 10
    let pane: TabPane
    let drag: PaneDrag
    let header: CGRect
    @State private var lifted = false
    @State private var labelWidth: CGFloat = 0

    var body: some View {
        let width = lifted ? min(header.width, labelWidth + Self.padding * 2) : header.width
        let height = lifted ? Self.height : header.height
        // Grabbed this far into the header; in the chip, as far as fits
        let grab = CGPoint(x: drag.start.x - header.minX, y: drag.start.y - header.minY)
        let anchor = lifted ? CGPoint(x: min(max(grab.x, Self.padding), width - Self.padding), y: height / 2) : grab
        let shape = RoundedRectangle(cornerRadius: lifted ? 6 : 0)
        label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Self.padding)
            .frame(width: width, height: height)
            .background {
                shape.fill(ThemeColors.background(ghostty.theme))
                shape.fill(Color.white.opacity(0.1))
                shape.strokeBorder(Color.white.opacity(lifted ? 0.15 : 0), lineWidth: 1)
            }
            .clipShape(shape)
            .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: lifted ? 16 : 0, y: lifted ? 6 : 0)
            .offset(x: drag.point.x - anchor.x, y: drag.point.y - anchor.y)
            .background {
                label.fixedSize().hidden()
                    .background(GeometryReader { geometry in
                        Color.clear.onAppear { labelWidth = geometry.size.width }
                    })
            }
            .onAppear {
                withAnimation(.spring(duration: 0.3, bounce: 0.2)) { lifted = true }
            }
    }

    private var label: some View {
        HStack(spacing: 8) {
            StatusGlyph(status: pane.status)
            Text(pane.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct LayoutNode: View {
    @EnvironmentObject private var sessionManager: SessionManager
    let layout: PaneLayout
    let group: SessionGroup
    let views: TerminalViews
    let split: Bool
    let zoomed: Bool
    /// Its title bar is under the window's buttons when the sidebar is hidden
    let topLeft: Bool
    /// Set when panes can be dragged by their titles
    let paneDrag: PaneDragHandler?
    /// The first half's share while its divider is dragged, and where the drag started
    @State private var dragged: (ratio: Double, start: Double)?

    var body: some View {
        switch layout {
        case .pane(let paneId):
            PaneTile(group: group, paneId: paneId, views: views, split: split, zoomed: zoomed, topLeft: topLeft,
                     paneDrag: paneDrag)
        case .split(let vertical, let ratio, let first, let second):
            GeometryReader { geometry in
                let total = vertical ? geometry.size.height : geometry.size.width
                let room = max(0, total - SplitDivider.thickness)
                let firstSize = room * min(max(dragged?.ratio ?? ratio, 0.1), 0.9)
                Group {
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
                // Over the panes, so the grab area reaches into them
                .overlay(alignment: .topLeading) {
                    DividerHandle(vertical: vertical) { distance in
                        // Terminals resize once, when the drag is over
                        PaneHostView.holdResizes()
                        let start = dragged?.start ?? ratio
                        dragged = (min(max(start + distance / max(room, 1), 0.1), 0.9), start)
                    } onEnd: {
                        if let dragged, let pane = first.paneIds.last, let other = second.paneIds.first {
                            sessionManager.resizeSplit(groupId: group.id, pane: pane, other: other, ratio: dragged.ratio)
                        }
                        dragged = nil
                    }
                    .frame(width: vertical ? total : DividerHandle.reach * 2,
                           height: vertical ? DividerHandle.reach * 2 : total)
                    .offset(x: vertical ? 0 : firstSize - DividerHandle.reach,
                            y: vertical ? firstSize - DividerHandle.reach : 0)
                }
            }
        }
    }

    private func node(_ layout: PaneLayout, topLeft: Bool) -> LayoutNode {
        LayoutNode(layout: layout, group: group, views: views, split: split, zoomed: zoomed, topLeft: topLeft,
                   paneDrag: paneDrag)
    }
}

/// A line between two panes; stacked panes get a horizontal one
struct SplitDivider: View {
    static let thickness: CGFloat = 1
    let vertical: Bool

    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.12))
            .frame(width: vertical ? nil : Self.thickness, height: vertical ? Self.thickness : nil)
    }
}

/// Where a divider can be grabbed: a few points either side of the line, with the
/// resize cursor. Reports how far it's been dragged (right or down), then that it's let go.
struct DividerHandle: NSViewRepresentable {
    /// Either side of the line
    static let reach: CGFloat = 3
    let vertical: Bool
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        if view.vertical != vertical {
            view.vertical = vertical
            view.window?.invalidateCursorRects(for: view)
        }
        view.onDrag = onDrag
        view.onEnd = onEnd
    }

    final class HandleView: NSView {
        var vertical = false
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: (() -> Void)?
        private var start: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: vertical ? .resizeUpDown : .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            start = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let point = event.locationInWindow
            // Window coordinates go up
            onDrag?(vertical ? start.y - point.y : point.x - start.x)
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            onEnd?()
        }
    }
}

private struct PaneTile: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var ghostty: MacGhosttyApp
    let group: SessionGroup
    let paneId: String
    let views: TerminalViews
    let split: Bool
    let zoomed: Bool
    let topLeft: Bool
    let paneDrag: PaneDragHandler?

    var body: some View {
        let focused = paneId == group.activePaneId
        let selection = PaneSelection(groupId: group.id, paneId: paneId)
        VStack(spacing: 0) {
            if let pane = group.panes.first(where: { $0.id == paneId }) {
                PaneHeader(pane: pane, selection: selection, focused: focused, split: split, zoomed: zoomed,
                           topLeft: topLeft, paneDrag: paneDrag)
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
                ThemeColors.background(ghostty.theme)
            }
        }
        .background(ThemeColors.background(ghostty.theme))
    }
}

/// Over each pane: what's running in it, and its actions. The window has no title
/// bar, so these are it: dragging one moves the window. In a split, dragging its title
/// moves the pane instead.
struct PaneHeader: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var window: WindowState
    static let padding: CGFloat = 10
    let pane: TabPane
    let selection: PaneSelection
    let focused: Bool
    /// One of several panes: dimmed when it's not the focused one, and it can zoom
    let split: Bool
    let zoomed: Bool
    let topLeft: Bool
    var paneDrag: PaneDragHandler?
    @State private var hovering = false

    var body: some View {
        // The pane's width, the row from its left: a pane too narrow for all of it cuts off
        // the buttons on the right. Sized by its contents, the row ran off both ends, and
        // the sidebar toggle went under the window's buttons.
        Color.clear
            .frame(height: window.titleBarHeight)
            // Dragged, it's lifted out into a chip under the pointer
            .overlay(alignment: .leading) { row.opacity(paneDrag?.dragged == pane.id ? 0 : 1) }
            .clipped()
            .background {
                ZStack {
                    focused || !split ? Color.white.opacity(0.07) : Color.white.opacity(0.02)
                    WindowDragArea { MainView.show(selection, sessionManager) }
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
    }

    private var row: some View {
        let active = focused || !split
        return HStack(spacing: 8) {
            if topLeft && window.sidebar == .detailOnly {
                SidebarToggle()
                    .padding(.leading, window.toggleLeading - Self.padding)
            }
            Group {
                StatusGlyph(status: pane.status)
                Text(pane.title)
                    .font(.callout.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Clicks go through to the drag area behind, or to the pane's grab
            .allowsHitTesting(false)
            .background {
                if let paneDrag {
                    PaneGrab(onClick: { MainView.show(selection, sessionManager) }) { point in
                        paneDrag.moved(selection.paneId, point)
                    } onEnd: {
                        paneDrag.ended()
                    }
                }
            }
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
            .foregroundStyle(.secondary)
            // The focused pane's, or one under the pointer: in place, so the title stays put
            .opacity(active || hovering ? 1 : 0)
            .allowsHitTesting(active || hovering)
            .animation(.easeOut(duration: 0.12), value: active || hovering)
        }
        .padding(.horizontal, Self.padding)
        .frame(height: window.titleBarHeight)
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        TitleBarButton(symbol: symbol, help: help, action: action)
    }

    /// Split this pane, not the one you were in
    private func splitPane(_ action: PaneAction) {
        MainView.show(selection, sessionManager)
        Task { await sessionManager.performPaneAction(action, groupId: selection.groupId) }
    }
}

/// A pane title bar's button, and a review's
struct TitleBarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Over a review in its workspace (`clauntty review`): a pane's title bar, with the
/// review's title and what it compares, full width or beside the panes, and close
struct ReviewHeader: View {
    @EnvironmentObject private var window: WindowState
    let review: Review
    let full: Bool
    /// The window's top left corner: the sidebar's toggle goes here when it's hidden
    let topLeft: Bool
    let toggle: () -> Void
    let close: () -> Void

    var body: some View {
        Color.clear
            .frame(height: window.titleBarHeight)
            .overlay(alignment: .leading) { row }
            .clipped()
            .background {
                ZStack {
                    Color.white.opacity(0.07)
                    WindowDragArea {}
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                    .allowsHitTesting(false)
            }
    }

    private var row: some View {
        HStack(spacing: 8) {
            if topLeft && window.sidebar == .detailOnly {
                SidebarToggle()
                    .padding(.leading, window.toggleLeading - PaneHeader.padding)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(review.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                Text(review.range)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Clicks go through to the drag area behind
            .allowsHitTesting(false)
            Spacer(minLength: 8)
            Group {
                TitleBarButton(symbol: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               help: full ? "Show the Panes Beside It" : "Full Width", action: toggle)
                TitleBarButton(symbol: "xmark", help: "Close Review (it waits on the host)", action: close)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, PaneHeader.padding)
        .frame(height: window.titleBarHeight)
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
        let now = Date()
        for session in shown {
            session.lastShownAt = now
        }
        scheduleIdleRelease()

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
                Self.doubleClicked(window)
                return
            }
            onClick?()
            window.performDrag(with: event)
        }

        /// What System Settings says a double click on a title bar does
        static func doubleClicked(_ window: NSWindow) {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        }
    }
}

/// A pane's title in a split: dragging it moves the pane (reporting the pointer in
/// `SplitPanes`' space, then that it's let go). A click calls `onClick`, a double click
/// does what a title bar's does.
private struct PaneGrab: View {
    let onClick: () -> Void
    let onDrag: (CGPoint) -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let origin = geometry.frame(in: .named(PaneDrag.space)).origin
            GrabArea(onClick: onClick, onDrag: { onDrag(CGPoint(x: origin.x + $0.x, y: origin.y + $0.y)) },
                     onEnd: onEnd)
        }
    }

    private struct GrabArea: NSViewRepresentable {
        let onClick: () -> Void
        let onDrag: (CGPoint) -> Void
        let onEnd: () -> Void

        func makeNSView(context: Context) -> GrabView { GrabView() }

        func updateNSView(_ view: GrabView, context: Context) {
            view.onClick = onClick
            view.onDrag = onDrag
            view.onEnd = onEnd
        }

        static func dismantleNSView(_ view: GrabView, coordinator: ()) {
            view.letWindowMove()
        }
    }

    final class GrabView: NSView {
        /// How far the pointer goes before a press is a drag
        private static let slop: CGFloat = 3
        var onClick: (() -> Void)?
        var onDrag: ((CGPoint) -> Void)?
        var onEnd: (() -> Void)?
        private var pressed = false
        private var inside = false
        /// The window held still while the pointer is here
        private weak var heldWindow: NSWindow?

        // Points from the top left, as SwiftUI's
        override var isFlipped: Bool { true }

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        // The pane titles are in the title bar's strip, where the toolbar moves the window on
        // a press before this view hears of it: it can't move while the pointer is here.
        override func mouseEntered(with event: NSEvent) {
            inside = true
            guard let window, window.isMovable else { return }
            window.isMovable = false
            heldWindow = window
        }

        override func mouseExited(with event: NSEvent) {
            inside = false
            if !pressed { letWindowMove() }
        }

        func letWindowMove() {
            heldWindow?.isMovable = true
            heldWindow = nil
        }

        // The press is followed here until it's let go, taking the events off the queue:
        // left to AppKit, the title bar's strip took over a real drag partway, and the
        // release never came (the drop target stayed on screen).
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                WindowDragArea.DragView.doubleClicked(window)
                return
            }
            onClick?()
            let start = convert(event.locationInWindow, from: nil)
            var dragging = false
            pressed = true
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
                let point = convert(next.locationInWindow, from: nil)
                if !dragging {
                    guard hypot(point.x - start.x, point.y - start.y) > Self.slop else { continue }
                    dragging = true
                    NSCursor.closedHand.push()
                }
                onDrag?(point)
            }
            pressed = false
            if !inside { letWindowMove() }
            guard dragging else { return }
            NSCursor.pop()
            onEnd?()
        }
    }
}
