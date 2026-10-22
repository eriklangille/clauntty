import SwiftUI

/// A sidebar card under the pointer, and where it is in the window
struct Peek: Equatable {
    enum Subject: Hashable {
        case workspace(UUID)
        /// A host's pages that no workspace here opened
        case host(UUID)
    }
    let subject: Subject
    let frame: CGRect
}

/// Beside the sidebar, for the card under the pointer. For a workspace, a row per pane
/// (status glyph, title, time, task), then the pages it opened. Hovering a row outlines
/// where that pane is on the terminal side (`peekPane`); a click shows it. A
/// transparent strip joins it to the card, so the pointer keeps it open on the way over.
struct WorkspacePeek: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts
    @EnvironmentObject private var window: WindowState
    let peek: Peek
    static let bridge: CGFloat = 22
    static let width: CGFloat = 340
    /// The panel's edge to its contents, all round
    static let inset: CGFloat = 10
    /// A row's edge to its glyph, and the map's to its edge: one column
    static let rowInset: CGFloat = 8

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear
                .frame(width: Self.bridge, height: peek.frame.height)
                .contentShape(Rectangle())
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(Self.inset)
            .frame(width: Self.width, alignment: .leading)
            // Solid: a material over a white page goes light grey under light text
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        }
        .onHover { window.peekHovered = $0 }
        .onDisappear { window.peekPane = nil }
    }

    @ViewBuilder
    private var content: some View {
        switch peek.subject {
        case .workspace(let id):
            if let group = sessionManager.sessionGroups.first(where: { $0.id == id }) {
                VStack(spacing: 0) {
                    ForEach(group.panes, id: \.id) { PaneRow(group: group, pane: $0) }
                }
                pages(sessionManager.webTabs.filter { $0.workspaceId == id }, divided: true)
            }
        case .host(let id):
            if let connection = hosts.opened.first(where: { $0.id == id }) {
                let groupIds = Set(sessionManager.sessionGroups.map(\.id))
                pages(sessionManager.webTabs(on: connection).filter { $0.workspaceId.map { !groupIds.contains($0) } ?? true }, divided: false)
            }
        }
    }

    @ViewBuilder
    private func pages(_ pages: [WebTab], divided: Bool) -> some View {
        if !pages.isEmpty {
            if divided {
                Divider().padding(.horizontal, Self.rowInset)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(pages) { PageRow(page: $0) }
            }
        }
    }
}

/// One pane: its status, title, what it's doing, and how long since you typed in it
/// (or its agent finished). Click to show it.
private struct PaneRow: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var window: WindowState
    let group: SessionGroup
    let pane: TabPane

    var body: some View {
        let state = sessionManager.paneStates[pane.id]
        let shown = pane.id == group.activePaneId
        // A shell's title is its folder: the program then, with the folder beneath
        let folderTitle = pane.title.isEmpty || pane.title == "~" || pane.title.hasPrefix("/")
        let title = folderTitle ? (state?.fg ?? "shell") : pane.title
        // The status glyph in the middle on the left; the title, and beneath it the task
        HStack(spacing: 8) {
            StatusGlyph(status: pane.status, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 12, weight: shown ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    TimelineView(.everyMinute) { context in
                        Text(sessionManager.since(state: state, typedIn: [pane.id]).map { $0.shortAge(now: context.date) } ?? "")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if let detail = pane.status.detail(state: state, title: title,
                                                   subtitle: folderTitle ? (pane.title.isEmpty ? "~" : pane.title) : state?.fg) ?? state?.place {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, WorkspacePeek.rowInset)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(window.peekPane?.paneId == pane.id ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { inside in
            let selection = PaneSelection(groupId: group.id, paneId: pane.id)
            if inside { window.peekPane = selection } else if window.peekPane == selection { window.peekPane = nil }
        }
        .onTapGesture { MainView.show(PaneSelection(groupId: group.id, paneId: pane.id), sessionManager) }
    }
}

/// A page: its title and port. Click to show it; its menu closes it.
private struct PageRow: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @ObservedObject var page: WebTab
    @State private var hovering = false

    var body: some View {
        let port = ":\(String(page.remotePort.port))"
        let shown = sessionManager.activeWebTab?.id == page.id
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
            // Untitled until it has loaded once: its address then
            Text(page.title == port ? "localhost\(port)" : page.title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if page.title != port {
                Text(port)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, WorkspacePeek.rowInset)
        .frame(height: 26)
        .background(Color.primary.opacity(shown ? 0.12 : hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { sessionManager.switchTo(page) }
        .contextMenu {
            Button("Close Page") { sessionManager.closeWebTab(page) }
        }
    }
}

/// Where the hovered row's pane is on the terminal side: an outline over its place in
/// its tab's split (where it would be, for a workspace not on screen)
struct PeekPaneOutline: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var window: WindowState

    var body: some View {
        GeometryReader { geometry in
            if window.peekShown, let target = window.peekPane,
               let group = sessionManager.sessionGroups.first(where: { $0.id == target.groupId }),
               let pane = group.panes.first(where: { $0.id == target.paneId }) {
                let layout = pane.group < group.layouts.count ? group.layouts[pane.group] : .pane(pane.id)
                let origin = geometry.frame(in: .global).origin
                if let frame = layout.frame(of: pane.id, in: window.detailFrame) {
                    // On the pane's own edges
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .strokeBorder(Color.white.opacity(0.7), lineWidth: 2)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX - origin.x, y: frame.minY - origin.y)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

extension PaneLayout {
    /// Where a pane is in `rect`, split as `SplitPanes` splits it: a 1pt divider, each
    /// first half its ratio (0.1 to 0.9) of the rest
    func frame(of paneId: String, in rect: CGRect) -> CGRect? {
        switch self {
        case .pane(let id):
            return id == paneId ? rect : nil
        case .split(let vertical, let ratio, let first, let second):
            let total = vertical ? rect.height : rect.width
            let firstSize = max(0, total - 1) * min(max(ratio, 0.1), 0.9)
            let (a, b): (CGRect, CGRect) = vertical
                ? (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstSize),
                   CGRect(x: rect.minX, y: rect.minY + firstSize + 1, width: rect.width, height: rect.height - firstSize - 1))
                : (CGRect(x: rect.minX, y: rect.minY, width: firstSize, height: rect.height),
                   CGRect(x: rect.minX + firstSize + 1, y: rect.minY, width: rect.width - firstSize - 1, height: rect.height))
            return first.frame(of: paneId, in: a) ?? second.frame(of: paneId, in: b)
        }
    }
}
