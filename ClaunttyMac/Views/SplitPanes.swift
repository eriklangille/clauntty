import SwiftUI

/// The tab the shown pane is in, its panes split as rtach keeps them. The pane you
/// type into is the active session; the others are dimmed, and clicking one moves
/// there.
struct SplitPanes: View {
    let group: SessionGroup
    let views: TerminalViews

    var body: some View {
        LayoutNode(layout: group.shownLayout, group: group, views: views)
    }
}

private struct LayoutNode: View {
    let layout: PaneLayout
    let group: SessionGroup
    let views: TerminalViews

    var body: some View {
        switch layout {
        case .pane(let paneId):
            PaneTile(group: group, paneId: paneId, views: views)
        case .split(let vertical, let ratio, let first, let second):
            GeometryReader { geometry in
                let total = vertical ? geometry.size.height : geometry.size.width
                let firstSize = max(0, (total - SplitDivider.thickness) * min(max(ratio, 0.1), 0.9))
                if vertical {
                    VStack(spacing: 0) {
                        LayoutNode(layout: first, group: group, views: views).frame(height: firstSize)
                        SplitDivider(vertical: true)
                        LayoutNode(layout: second, group: group, views: views)
                    }
                } else {
                    HStack(spacing: 0) {
                        LayoutNode(layout: first, group: group, views: views).frame(width: firstSize)
                        SplitDivider(vertical: false)
                        LayoutNode(layout: second, group: group, views: views)
                    }
                }
            }
        }
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

    var body: some View {
        if let session = sessionManager.sessions.first(where: { $0.groupId == group.id && $0.pane?.paneId == paneId }) {
            let focused = paneId == group.activePaneId
            ZStack {
                TerminalContainer(session: session, views: views, focused: focused) {
                    MainView.show(PaneSelection(groupId: group.id, paneId: paneId), sessionManager)
                }
                TerminalStatusOverlay(session: session) {
                    Task { try? await sessionManager.reconnect(session: session) }
                }
                if !focused {
                    Color.black.opacity(0.3)
                        .allowsHitTesting(false)
                }
            }
            .background(ThemeColors.background)
            .clipped()
        } else {
            ThemeColors.background
        }
    }
}

extension SessionGroup {
    /// The layout of the tab its active pane is in; just that pane until the host lists it
    var shownLayout: PaneLayout {
        layouts.first { $0.paneIds.contains(activePaneId) } ?? .pane(activePaneId)
    }
}

extension SessionManager {
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
