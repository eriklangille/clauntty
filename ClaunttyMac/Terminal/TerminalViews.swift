import AppKit
import GhosttyKit
import RtachClient
import SwiftUI

/// One terminal view per session, kept while the session exists, so switching
/// panes keeps each pane's screen and scrollback (the iOS app keeps its surfaces too).
@MainActor
final class TerminalViews {
    private let app: ghostty_app_t
    /// By session ID, with the session it's wired to: a pane's session keeps its
    /// stable ID when SessionManager makes it again (its host was reopened), and
    /// the new one needs its own view.
    private var views: [UUID: (session: WeakSession, view: MacTerminalView)] = [:]

    private struct WeakSession {
        weak var session: Session?
    }

    /// The containers showing each session, oldest first. When a split changes shape,
    /// SwiftUI makes a new container for a pane before it removes the old one, and both
    /// update: the newest gets the view, or the old one takes it along when it goes.
    private var containers: [UUID: [WeakContainer]] = [:]

    private struct WeakContainer {
        weak var view: NSView?
    }

    /// Points; 0 is Ghostty's default. Every pane uses it, and it's remembered.
    private(set) var fontSize: Float = UserDefaults.standard.float(forKey: "fontSize")
    private static let defaultFontSize: Float = 13

    init(app: ghostty_app_t) {
        self.app = app
    }

    /// Bigger (+1), smaller (-1), or back to the default (nil), in every pane.
    func adjustFontSize(by step: Float?) {
        let current = fontSize == 0 ? Self.defaultFontSize : fontSize
        fontSize = step.map { min(36, max(8, current + $0)) } ?? 0
        UserDefaults.standard.set(fontSize, forKey: "fontSize")
        let action = fontSize == 0 ? "reset_font_size" : "set_font_size:\(fontSize)"
        for entry in views.values { entry.view.perform(action) }
    }

    /// The session's view, made and wired to it on first use. `size` is where it'll
    /// be shown, so the session starts at the right grid; nil when that isn't known yet
    /// (the session gets its grid from the first layout).
    func view(for session: Session, size: CGSize?) -> MacTerminalView {
        if let entry = views[session.id] {
            if entry.session.session === session { return entry.view }
            entry.view.removeFromSuperview()
        }
        let view = MacTerminalView(app: app, fontSize: fontSize)
        view.frame = NSRect(origin: .zero, size: size ?? CGSize(width: 900, height: 600))
        wire(session, to: view, sized: size != nil)
        views[session.id] = (WeakSession(session: session), view)
        return view
    }

    /// Give the session's view the keyboard, if it's on screen
    func focus(_ session: Session) {
        guard let view = views[session.id]?.view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    /// Where the session's pane is in its window, from the top left, if it's on screen
    func frameInWindow(of sessionId: UUID) -> CGRect? {
        guard let pane = views[sessionId]?.view.superview, let window = pane.window,
              let height = window.contentView?.bounds.height else { return nil }
        let rect = pane.convert(pane.bounds, to: nil)
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Show the session in `container`, unless a newer container shows it. Returns its view.
    @discardableResult
    func show(_ session: Session, in container: NSView) -> MacTerminalView {
        var list = containers[session.id, default: []].filter { $0.view != nil }
        if !list.contains(where: { $0.view === container }) { list.append(WeakContainer(view: container)) }
        containers[session.id] = list
        let view = view(for: session, size: container.bounds.size == .zero ? nil : container.bounds.size)
        place(view, of: session.id)
        return view
    }

    /// A container is going away: the view moves to the newest one left, if any.
    func remove(_ container: NSView, showing sessionId: UUID) {
        containers[sessionId] = containers[sessionId]?.filter { $0.view != nil && $0.view !== container }
        guard let view = views[sessionId]?.view else { return }
        if view.superview === container { view.removeFromSuperview() }
        place(view, of: sessionId)
    }

    private func place(_ view: MacTerminalView, of sessionId: UUID) {
        guard let container = containers[sessionId]?.last?.view, view.superview !== container else { return }
        // Removing the view that has the keyboard leaves it with the window: it keeps it
        let hadKeyboard = view.window?.firstResponder === view
        view.removeFromSuperview()
        container.addSubview(view)
        container.needsLayout = true
        if hadKeyboard {
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }
    }

    /// Drop views whose sessions are gone (closed panes, ended workspaces).
    func prune(keeping ids: Set<UUID>) {
        for id in views.keys where !ids.contains(id) {
            views[id]?.view.removeFromSuperview()
            views[id] = nil
            containers[id] = nil
        }
    }

    private func wire(_ session: Session, to view: MacTerminalView, sized: Bool) {
        // Not a placeholder's grid: attached at that, the program drew for it until the
        // pane's own size went out
        if sized, let grid = view.gridSize {
            session.initialTerminalSize = (rows: Int(grid.rows), columns: Int(grid.columns))
        }
        view.onLayout = { [weak session] columns, rows in
            session?.initialTerminalSize = (rows: Int(rows), columns: Int(columns))
        }
        // What arrived before there was a view (it connected first, or this
        // replaces an older view), then everything from now on
        let earlier = session.getScrollbackData()
        if !earlier.isEmpty { view.write(earlier) }
        session.onDataReceived = { [weak view] data in view?.write(data) }
        // Older history from rtach goes above the scrollback; scrolling near the
        // top of it asks for the next page, as on the phone
        session.onScrollbackReceived = { [weak view] data in view?.prependHistory(data) }
        view.onScrollNearTop = { [weak session] in session?.loadMoreScrollbackIfNeeded() }
        view.onInput = { [weak session] data in session?.sendData(data) }
        // Session skips this while another device has the pane
        view.onResize = { [weak session] columns, rows in
            session?.sendWindowChange(rows: rows, columns: columns)
        }
        view.onUseHere = { [weak session] in session?.claimActive() }
        // Uploaded to the host's /tmp, then their paths pasted, as the phone does
        view.onPasteImages = { [weak session, weak view] images in
            Task { @MainActor in
                var paths: [String] = []
                for image in images {
                    if let path = await session?.uploadImage(image) { paths.append(path) }
                }
                if !paths.isEmpty { view?.pasteText(paths.joined(separator: " ")) }
            }
        }
        // Another device has the pane: draw it at that device's grid. Ours again (we
        // took it back, or the other device let go): back to this pane's size, which
        // wasn't sent meanwhile. When it was drawn at the other grid, the terminal is
        // still at that grid until the next layout, which resizes it and sends the
        // pane's size (onResize); sending its grid now asked rtach for the other size.
        let apply = { [weak session, weak view] (size: RtachClient.PtySize?) in
            guard let session, let view else { return }
            let other = size.flatMap { $0.yours ? nil : (rows: $0.rows, columns: $0.cols) }
            let wasOther = view.otherDeviceGrid != nil
            view.setOtherDeviceGrid(other)
            if other == nil, size != nil, !wasOther, let grid = view.gridSize {
                session.sendWindowChange(rows: grid.rows, columns: grid.columns)
            }
        }
        session.onPtySizeChanged = apply
        if session.ptySize != nil { apply(session.ptySize) }
    }
}

/// Shows a pane's terminal. The focused one gets the keyboard; clicking another
/// one calls `onFocus`.
struct TerminalContainer: NSViewRepresentable {
    let session: Session
    let views: TerminalViews
    let focused: Bool
    let onFocus: () -> Void

    final class Coordinator {
        var wasFocused = false
        var sessionId: UUID?
        var views: TerminalViews?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        PaneHostView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        if let previous = coordinator.sessionId, previous != session.id {
            views.remove(container, showing: previous)
        }
        coordinator.sessionId = session.id
        coordinator.views = views
        let wasHere = container.subviews.first is MacTerminalView
        let view = views.show(session, in: container)
        view.onFocus = onFocus
        let added = !wasHere && view.superview === container
        // Only when it becomes the focused pane: on every update it would take the
        // keyboard back from the switcher's search field
        let takeKeyboard = focused && (added || !coordinator.wasFocused)
        context.coordinator.wasFocused = focused
        guard focused else { return }
        // Not in the window yet, maybe: once it is. Also when nothing has the keyboard
        // (the window itself does, after a split moved views around).
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window, window.firstResponder !== view else { return }
            if takeKeyboard || window.firstResponder === window || window.firstResponder == nil {
                window.makeFirstResponder(view)
            }
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        guard let sessionId = coordinator.sessionId else { return }
        coordinator.views?.remove(container, showing: sessionId)
    }
}

/// Holds a pane's terminal: filling it, or at another device's grid from the top
/// left, scaled down to fit.
final class PaneHostView: NSView {
    override var isFlipped: Bool { true }

    /// Terminals keep their size meanwhile (the sidebar is sliding), from the top left
    private static var held = false
    private static var release: Task<Void, Never>?
    private static let released = Notification.Name("PaneHostView.released")

    /// Until the panes' sizes have stopped changing: then each resizes once
    static func holdResizes() {
        held = true
        settle()
    }

    /// Released once no pane has changed size for a moment, so after the animation
    private static func settle() {
        release?.cancel()
        release = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            held = false
            NotificationCenter.default.post(name: released, object: nil)
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // A held terminal bigger than the pane mustn't draw over the next one
        clipsToBounds = true
        NotificationCenter.default.addObserver(self, selector: #selector(resizeTerminal), name: Self.released, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func resizeTerminal() {
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let terminal = subviews.first as? MacTerminalView else { return }
        if Self.held, terminal.frame.size != .zero {
            Self.settle()
            return
        }
        let fit = terminal.layout(in: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayerTransform = CATransform3DMakeScale(fit, fit, 1)
        CATransaction.commit()
    }
}

/// Over the terminal: how the connection is doing, and whether another device has the pane.
struct TerminalStatusOverlay: View {
    @ObservedObject var session: Session
    let reconnect: () -> Void

    var body: some View {
        VStack {
            Spacer()
            if let message = connectionMessage {
                pill(message.text, action: message.action)
            } else if session.inUseElsewhere {
                pill("In use on another device · Click to use here") { session.claimActive() }
            }
        }
        .padding(.bottom, 18)
        .animation(.easeOut(duration: 0.2), value: session.state)
    }

    private var connectionMessage: (text: String, action: (() -> Void)?)? {
        // An idle pane the app let go, attaching again under its last screen
        if session.isResting, session.state == .disconnected || session.state == .connecting {
            return nil
        }
        switch session.state {
        case .connected: return nil
        case .connecting: return ("Connecting…", nil)
        // A pane on screen reconnects by itself; only a failed attempt waits for a click
        case .disconnected:
            // (a click still reconnects, in case nothing is: the app in the background)
            return session.reconnectFailed ? ("Disconnected · Click to reconnect", reconnect) : ("Connecting…", reconnect)
        case .error(let message): return ("\(message) · Click to retry", reconnect)
        case .remotelyDeleted: return ("This pane has ended", nil)
        }
    }

    private func pill(_ text: String, action: (() -> Void)?) -> some View {
        Button(action: { action?() }) {
            Text(text)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glass(in: .capsule)
        .disabled(action == nil)
    }
}
