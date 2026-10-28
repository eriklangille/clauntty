import SwiftUI

/// A pane in the sidebar: which workspace (group) and which pane in it.
struct PaneSelection: Hashable {
    let groupId: UUID
    let paneId: String
}

/// The window: hosts, their workspaces and panes in the sidebar, and the pane
/// you're on filling the rest.
struct MainView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts
    @EnvironmentObject private var window: WindowState
    @EnvironmentObject private var ghostty: MacGhosttyApp
    let views: TerminalViews
    /// The review over its workspace's panes rather than beside them
    @State private var reviewFull = false
    /// How much of a workspace a review takes, beside its panes
    @AppStorage("reviewShare") private var reviewShare = 0.6
    @State private var reviewDragStart: CGFloat?

    var body: some View {
        NavigationSplitView(columnVisibility: $window.sidebar) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                // Where the terminal side is, up into the title bar as the panes are
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.frame(in: .global), initial: true) { _, frame in
                            window.detailFrame = frame
                        }
                    }
                    .ignoresSafeArea(.container, edges: .top)
                }
        }
        .navigationTitle(title)
        // The window's buttons placed and measured, for the top rows
        .background(WindowButtonsRoom())
        .overlay(alignment: .top) {
            if window.portPickerShown, let group = portPickerGroup {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001)
                        .onTapGesture { window.portPickerShown = false }
                    PortPicker(group: group)
                        .padding(.top, 70)
                }
            }
        }
        .overlay(alignment: .top) {
            if window.switcherShown {
                ZStack(alignment: .top) {
                    // A click anywhere else closes it
                    Color.black.opacity(0.001)
                        .onTapGesture { window.switcherShown = false }
                    PaneSwitcher()
                        .padding(.top, 70)
                }
            }
        }
        // The pane under the pointer in the peek, outlined where it is
        .overlay { PeekPaneOutline().ignoresSafeArea() }
        // The sidebar card under the pointer: its panes and pages, beside the sidebar
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if window.peekShown, let peek = window.peek {
                    let origin = geometry.frame(in: .global).origin
                    WorkspacePeek(peek: peek)
                        .offset(x: peek.frame.maxX - origin.x - 2,
                                y: max(8, peek.frame.minY - origin.y - 8))
                }
            }
            .ignoresSafeArea()
        }
        .overlay {
            ImageViewer(content: $sessionManager.imageViewer) { views.frameInWindow(of: $0) }
                .ignoresSafeArea()
        }
        // Closed: typing goes back to the pane you're in
        .onChange(of: window.switcherShown) { _, shown in
            if !shown { refocus() }
        }
        .onChange(of: window.portPickerShown) { _, shown in
            if !shown { refocus() }
        }
        // Cmd+arrows in a Cmd+number peek: the workspace's next or previous pane, or
        // page, in the peek's order (its panes, then its pages)
        .onAppear {
            window.movePane = { [weak sessionManager, weak window] groupId, offset in
                guard let sessionManager, let window,
                      let group = sessionManager.sessionGroups.first(where: { $0.id == groupId }) else { return }
                let pages = sessionManager.webTabs.filter { $0.workspaceId == groupId }
                let count = group.panes.count + pages.count
                guard count > 0 else { return }
                let current = pages.firstIndex { $0.id == sessionManager.activeWebTab?.id }.map { group.panes.count + $0 }
                    ?? group.panes.firstIndex { $0.id == group.activePaneId } ?? 0
                let next = (current + offset + count) % count
                if next < group.panes.count {
                    let selection = PaneSelection(groupId: groupId, paneId: group.panes[next].id)
                    MainView.show(selection, sessionManager)
                    window.peekPane = selection
                } else {
                    sessionManager.switchTo(pages[next - group.panes.count])
                    window.peekPane = nil
                }
            }
        }
        .onChange(of: sessionManager.shownImages == nil) { _, closed in
            if closed { refocus() }
        }
        // An ended workspace's images go with it
        .onChange(of: sessionManager.sessionGroups.map(\.id)) { _, ids in
            for workspace in sessionManager.imageWindows where !ids.contains(workspace) {
                sessionManager.dropImages(workspace)
            }
        }
        .onChange(of: sessionManager.sessions.map(\.id)) { _, ids in
            views.prune(keeping: Set(ids))
        }
        // A closed page's web view goes with it
        .onChange(of: sessionManager.webTabs.map(\.id)) { _, ids in
            WebViews.prune(keeping: Set(ids))
        }
        // Another pane, or a split from the host: every pane in the tab runs
        .onChange(of: sessionManager.activeSessionId) { _, _ in sessionManager.showSplitPanes() }
        .onChange(of: shownLayout) { _, _ in sessionManager.showSplitPanes() }
        .onChange(of: sessionManager.sessionStateVersion) { _, _ in sessionManager.refreshLayoutIfMissing() }
        .alert("Clauntty", isPresented: workspaceMessageShown) {
            Button("OK") { sessionManager.workspaceMessage = nil }
        } message: {
            Text(sessionManager.workspaceMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let webTab = sessionManager.activeWebTab {
            WebPane(webTab: webTab)
                .ignoresSafeArea(.container, edges: .top)
        } else if let session = sessionManager.activeSession, let group = sessionManager.sessionGroup(for: session) {
            workspace(group)
                // Images its panes sent: over this workspace only, so the sidebar stays
                // and another workspace's don't interrupt. A new one each workspace.
                .overlay {
                    ImageViewer(content: $sessionManager.windowImages[group.id],
                                paneFrame: { views.frameInWindow(of: $0) },
                                send: { marked, original in sendMarkup(marked, replacing: original, in: group) })
                        .ignoresSafeArea(.container, edges: .top)
                        .id(group.id)
                }
        } else if hosts.opened.isEmpty {
            HostPicker()
        } else {
            Text("Pick a pane")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A workspace's panes, and the review its agent asked for (`clauntty review`) beside
    /// them, so the agent's chat stays in view; or over them, full width. Full width keeps
    /// the panes at their size underneath, so switching doesn't resize the terminals
    private func workspace(_ group: SessionGroup) -> some View {
        let review = sessionManager.shownReview(in: group.id)
        return GeometryReader { geometry in
            let total = geometry.size.width
            let side = reviewWidth(in: total)
            ZStack(alignment: .topTrailing) {
                // Up into the title bar's place: the pane title bars are the window's
                SplitPanes(group: group, views: views)
                    .background(ThemeColors.background(ghostty.theme))
                    .ignoresSafeArea(.container, edges: .top)
                    .frame(width: review == nil ? total : max(0, total - side - SplitDivider.thickness))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let review {
                    HStack(spacing: 0) {
                        SplitDivider(vertical: false).opacity(reviewFull ? 0 : 1)
                        VStack(spacing: 0) {
                            // Up in the title bar's place, as the panes' title bars are
                            ReviewHeader(review: review, full: reviewFull, topLeft: reviewFull) {
                                PaneHostView.holdResizes()
                                reviewFull.toggle()
                            } close: {
                                sessionManager.hideReview(review)
                            }
                            .background(ThemeColors.background(ghostty.theme))
                            ReviewHost(review: review, theme: ghostty.theme, sessionManager: sessionManager, topBar: false) {
                                sessionManager.hideReview(review)
                            }
                            .id(review.id)
                        }
                        .ignoresSafeArea(.container, edges: .top)
                    }
                    .frame(width: reviewFull ? total : side + SplitDivider.thickness)
                    .transition(.opacity)
                    .overlay(alignment: .topLeading) {
                        if !reviewFull {
                            DividerHandle(vertical: false) { distance in
                                // Terminals resize once, when the drag is over
                                PaneHostView.holdResizes()
                                let start = reviewDragStart ?? side
                                reviewDragStart = start
                                reviewShare = Double((start - distance) / max(total, 1))
                            } onEnd: {
                                reviewDragStart = nil
                            }
                            .frame(width: DividerHandle.reach * 2)
                            .offset(x: -DividerHandle.reach)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    /// The review's share of the workspace, leaving the panes and the review room to work:
    /// its file list and at least 500 points of code
    private func reviewWidth(in total: CGFloat) -> CGFloat {
        let wanted = total * CGFloat(reviewShare)
        return max(min(wanted, total - 320), min(730, total * 0.7))
    }

    /// Markup's Send to Claude: the marked-up image takes the original's place (so
    /// reopening brings it back, the original with it), the viewer closes, and it's
    /// pasted into the pane that sent the image, as Cmd+V would, for the user to add words
    private func sendMarkup(_ marked: NSImage, replacing original: ImageViewerContent.Item, in group: SessionGroup) {
        let item = ImageViewerContent.Item(name: original.name, image: marked)
        if let png = marked.platformPNGData() { WaitingImages.store(png, item: item.id, workspace: group.id) }
        let source = sessionManager.windowImages[group.id]?.source
        if var content = sessionManager.windowImages[group.id], let index = content.items.firstIndex(where: { $0.id == original.id }) {
            content.items[index] = item
            sessionManager.windowImages[group.id] = content
        }
        sessionManager.windowImages[group.id] = nil

        let target = source.flatMap { id in sessionManager.sessions.first { $0.id == id && $0.groupId == group.id } }
            ?? sessionManager.activeSession
        guard let target else { return }
        if let pane = target.pane?.paneId, sessionManager.activeSessionId != target.id {
            MainView.show(PaneSelection(groupId: group.id, paneId: pane), sessionManager)
        }
        views.pasteImage(marked, into: target)
        DispatchQueue.main.async { views.focus(target) }
    }

    private func refocus() {
        guard let session = sessionManager.activeSession else { return }
        DispatchQueue.main.async { views.focus(session) }
    }

    /// Open Port's workspace: the one asked for, else the one shown (or the page's)
    private var portPickerGroup: SessionGroup? {
        let id = window.portPickerWorkspace ?? sessionManager.activeSession?.groupId ?? sessionManager.activeWebTab?.workspaceId
        return sessionManager.sessionGroups.first { $0.id == id }
    }

    private var shownLayout: PaneLayout? {
        sessionManager.activeSession.flatMap { sessionManager.sessionGroup(for: $0) }?.shownLayout
    }

    private var title: String {
        if let webTab = sessionManager.activeWebTab { return webTab.title }
        guard let session = sessionManager.activeSession, let group = sessionManager.sessionGroup(for: session) else {
            return "Clauntty"
        }
        // As in the sidebar; panes in a split have their own title bars
        return group.sidebarTitles.title
    }

    private var workspaceMessageShown: Binding<Bool> {
        Binding(get: { sessionManager.workspaceMessage != nil },
                set: { if !$0 { sessionManager.workspaceMessage = nil } })
    }
}

/// The theme's background, behind the terminal and as it resizes.
@MainActor
enum ThemeColors {
    /// Behind the terminals, so a pane being laid out doesn't flash another color
    static func background(_ theme: Theme?) -> Color {
        theme?.backgroundColor ?? .black
    }
}

/// This Mac and the hosts from ~/.ssh/config, to open one.
struct HostPicker: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts

    var body: some View {
        VStack(spacing: 14) {
            Text("Open a host")
                .font(.title2.weight(.semibold))
            if hosts.addable.isEmpty && !hosts.canOpenThisMac {
                Text("No hosts in ~/.ssh/config")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        if hosts.canOpenThisMac {
                            row("This Mac", detail: "Terminals here, no SSH", symbol: "desktopcomputer") {
                                hosts.openThisMac()
                            }
                        }
                        ForEach(hosts.addable) { host in
                            row(host.alias, detail: "\(host.user)@\(host.hostName)\(host.port == 22 ? "" : ":\(host.port)")",
                                symbol: "server.rack") {
                                hosts.open(host)
                            }
                        }
                    }
                    .frame(maxWidth: 360)
                }
                .frame(maxHeight: 420)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ name: String, detail: String, symbol: String,
                     open: @escaping () -> SavedConnection) -> some View {
        Button {
            let connection = open()
            Task { await MainView.openHost(connection, sessionManager) }
        } label: {
            HStack {
                Image(systemName: symbol)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glass(in: .rect(cornerRadius: 10))
    }
}

extension SessionManager {
    /// The workspace on screen, unless a page is
    var shownWorkspaceId: UUID? {
        guard activeWebTab == nil, let session = activeSession else { return nil }
        return sessionGroup(for: session)?.id
    }

    /// The images open in the window: the shown workspace's, else ones that came with
    /// no workspace to go to
    var shownImages: ImageViewerContent? {
        shownWorkspaceId.flatMap { windowImages[$0] } ?? imageViewer
    }
}

extension MainView {
    /// List a host's workspaces; with none, start one in the home folder.
    static func openHost(_ connection: SavedConnection, _ sessionManager: SessionManager) async {
        await sessionManager.refreshWorkspaces(for: connection)
        let groups = sessionManager.orderedGroups(on: connection)
        if let group = groups.first, let session = sessionManager.currentSession(of: group) {
            sessionManager.switchTo(session)
        } else if groups.isEmpty {
            await sessionManager.newWorkspace(on: connection, folder: "~")
        }
    }

    /// Close a pane after asking: whatever runs in it ends, on every device.
    static func closePane(_ selection: PaneSelection, title: String, _ sessionManager: SessionManager) {
        show(selection, sessionManager)
        let alert = NSAlert()
        alert.messageText = "Close “\(title)”?"
        alert.informativeText = "Whatever runs in it ends, on every device."
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // It's the workspace's pane again in case something moved it while asking
        show(selection, sessionManager)
        Task { await sessionManager.performPaneAction(.close, groupId: selection.groupId) }
    }

    /// Show a pane: make it its workspace's pane, then switch to it.
    static func show(_ selection: PaneSelection, _ sessionManager: SessionManager) {
        sessionManager.selectPane(groupId: selection.groupId, paneId: selection.paneId)
        guard let group = sessionManager.sessionGroups.first(where: { $0.id == selection.groupId }),
              let session = sessionManager.currentSession(of: group) else { return }
        if sessionManager.activeSession?.id != session.id {
            sessionManager.switchTo(session)
        }
    }
}

extension View {
    /// Liquid glass on macOS 26, the blurred material before it
    @ViewBuilder
    func glass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            // Solid: a material over a white page goes light grey under light text
            background(Color(nsColor: .windowBackgroundColor), in: shape)
        }
    }
}
