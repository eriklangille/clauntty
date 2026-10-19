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
    /// be shown, so the session starts at the right grid.
    func view(for session: Session, size: CGSize) -> MacTerminalView {
        if let entry = views[session.id] {
            if entry.session.session === session { return entry.view }
            entry.view.removeFromSuperview()
        }
        let view = MacTerminalView(app: app, fontSize: fontSize)
        view.frame = NSRect(origin: .zero, size: size)
        wire(session, to: view)
        views[session.id] = (WeakSession(session: session), view)
        return view
    }

    /// Drop views whose sessions are gone (closed panes, ended workspaces).
    func prune(keeping ids: Set<UUID>) {
        for id in views.keys where !ids.contains(id) {
            views[id]?.view.removeFromSuperview()
            views[id] = nil
        }
    }

    private func wire(_ session: Session, to view: MacTerminalView) {
        if let grid = view.gridSize {
            session.initialTerminalSize = (rows: Int(grid.rows), columns: Int(grid.columns))
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
        view.onResize = { [weak session] columns, rows in
            session?.sendWindowChange(rows: rows, columns: columns)
        }
        // The PTY is ours again (we took it back, or the other device let go): it
        // takes this window's size, which wasn't sent while another device had it.
        session.onPtySizeChanged = { [weak session, weak view] size in
            guard let session, let size, size.yours, let grid = view?.gridSize else { return }
            session.sendWindowChange(rows: grid.rows, columns: grid.columns)
        }
    }
}

/// Shows the active session's terminal, filling the detail area.
struct TerminalContainer: NSViewRepresentable {
    let session: Session
    let views: TerminalViews

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let size = container.bounds.size == .zero ? CGSize(width: 900, height: 600) : container.bounds.size
        let view = views.view(for: session, size: size)
        guard view.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        view.window?.makeFirstResponder(view)
        // Showing a pane is using it: it takes this window's size, as on the phone
        session.claimActive()
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
        switch session.state {
        case .connected: return nil
        case .connecting: return ("Connecting…", nil)
        case .disconnected: return ("Disconnected · Click to reconnect", reconnect)
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
        .glassEffect(.regular, in: .capsule)
        .disabled(action == nil)
    }
}
