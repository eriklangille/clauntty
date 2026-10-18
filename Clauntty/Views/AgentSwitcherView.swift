import SwiftUI
import UIKit

/// Agent mode (Settings → Agent Mode): instead of a tab bar, one window per workspace
/// onto its live terminal. Tap a window to type into it (the pane becomes the active
/// tab: keyboard, key bar); tap another to switch, keyboard up. Swipe a window to
/// switch its panes. Fullscreen grows the window into the whole screen, the session
/// view; collapse or drag its pill down to come back.
///
/// Every terminal keeps the phone's full size and is only scaled and cropped into its
/// window, so opening the switcher, focusing or going fullscreen never resizes a pane.
struct AgentSwitcherView: View {
    @EnvironmentObject var sessionManager: SessionManager
    let onNewTab: () -> Void
    let onVoice: () -> Void

    /// The window typed into (its tab id)
    @State private var focused: UUID?
    @State private var fullscreen = false
    /// Window order, kept while one is focused so windows don't move under your finger
    @State private var frozenOrder: [UUID]?

    /// Room at the top of each window for its pill
    static let pillStrip: CGFloat = 52
    /// What the terminal keeps at its bottom for the key bar
    static let barReserve: CGFloat = 78

    @EnvironmentObject private var ghosttyApp: GhosttyApp
    @ObservedObject private var themeManager = ThemeManager.shared

    /// The terminal's background, behind and around the windows
    private var background: Color {
        themeManager.theme(withId: ghosttyApp.currentThemeId)?.backgroundColor
            ?? Color(red: 40 / 255, green: 44 / 255, blue: 52 / 255)
    }

    var body: some View {
        GeometryReader { outer in
            let fullHeight = outer.size.height
            VStack(spacing: 0) {
                GeometryReader { geo in
                    ScrollViewReader { scroller in
                        ScrollView {
                            // One list in every mode: a window keeps its live terminal view.
                            // Fullscreen shrinks the others away rather than showing the
                            // window somewhere else, which would make a new, empty terminal.
                            VStack(spacing: fullscreen ? 0 : 10) {
                                ForEach(windows, id: \.id) { tab in
                                    if case .terminal(let session) = tab {
                                        let hidden = fullscreen && focused != tab.id
                                        window(for: session, tabId: tab.id, viewport: geo.size, fullHeight: fullHeight, scroller: scroller)
                                            .frame(height: hidden ? 0 : nil, alignment: .top)
                                            .clipped()
                                            .opacity(hidden ? 0 : 1)
                                            .allowsHitTesting(!hidden)
                                            .id(tab.id)
                                    }
                                }
                                if !fullscreen {
                                    controls
                                }
                            }
                            .padding(.horizontal, fullscreen ? 0 : 10)
                            .padding(.top, fullscreen ? 0 : 2)
                            // Room to scroll a focused window to the top, clear of the key bar
                            .padding(.bottom, fullscreen ? 0 : (focused == nil ? 12 : geo.size.height))
                        }
                        .scrollDisabled(fullscreen)
                        .scrollDismissesKeyboard(.never)
                        .onChange(of: fullscreen) { _, on in
                            if on, let id = focused { scroller.scrollTo(id, anchor: .top) }
                        }
                    }
                }
            }
        }
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: Windows

    /// Terminal tabs, the ones that need you first (frozen while you type)
    private var windows: [TabItem] {
        let tabs = sessionManager.orderedTabs().filter {
            if case .terminal = $0 { return true }
            return false
        }
        if let order = frozenOrder {
            return tabs.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        }
        return tabs.enumerated().sorted { a, b in
            let ra = needsYou(a.element) ? 0 : 1
            let rb = needsYou(b.element) ? 0 : 1
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    private func needsYou(_ tab: TabItem) -> Bool {
        guard case .terminal(let session) = tab, let info = sessionManager.panes(for: session) else { return false }
        return info.panes.contains { $0.status == .blocked }
    }

    private func window(for session: Session, tabId: UUID, viewport: CGSize, fullHeight: CGFloat, scroller: ScrollViewProxy?) -> some View {
        let isFocused = focused == tabId
        let isFull = fullscreen && isFocused
        let info = sessionManager.panes(for: session)
        let panes = info?.panes ?? []
        let activeIndex = info?.activeIndex ?? 0
        let status = panes.indices.contains(activeIndex) ? panes[activeIndex].status : .none
        let isAgent = session.pane.flatMap { sessionManager.paneStates[$0.paneId] }?.hasAgent ?? false
        // One size in every mode, so focusing or the keyboard never resizes the pane (and
        // Claude never redraws): windows only crop it
        let terminalHeight = fullHeight - Self.pillStrip
        let mode: SwitcherWindow.Mode = {
            if isFull { return .fullscreen(height: viewport.height) }
            // Most of the room above the key bar, so the other windows stay in view below
            // while you type
            if isFocused { return .focused(maxHeight: max(180, (viewport.height - Self.barReserve) * 0.6)) }
            return status == .blocked ? .blocked : .collapsed
        }()
        return SwitcherWindow(
            session: session,
            title: panes.indices.contains(activeIndex) ? panes[activeIndex].title : session.title,
            workspace: session.pane?.groupTitle ?? session.connectionConfig.displayName,
            panes: panes,
            activeIndex: activeIndex,
            status: status,
            isAgent: isAgent,
            mode: mode,
            background: background,
            terminalSize: CGSize(width: viewport.width, height: terminalHeight),
            windowWidth: isFull ? viewport.width : viewport.width - 20,
            onTap: { toggleFocus(tabId, session: session, scroller: scroller) },
            onSwipe: { step in swipe(session, step: step) },
            onFullscreen: { setFullscreen(!fullscreen) }
        )
    }

    // MARK: Actions

    private func toggleFocus(_ tabId: UUID, session: Session, scroller: ScrollViewProxy?) {
        if fullscreen { return }
        withAnimation(.spring(duration: 0.38, bounce: 0.1)) {
            if focused == tabId {
                focused = nil
                frozenOrder = nil
            } else {
                frozenOrder = frozenOrder ?? windows.map(\.id)
                focused = tabId
                // Grow and move to the top in one motion
                scroller?.scrollTo(tabId, anchor: .top)
            }
        }
        if focused == tabId {
            sessionManager.switchTo(session)
        }
    }

    private func setFullscreen(_ on: Bool) {
        withAnimation(.spring(duration: 0.42, bounce: 0.1)) { fullscreen = on }
    }

    /// Show the workspace's next or previous pane in this window
    private func swipe(_ session: Session, step: Int) {
        guard let groupId = session.groupId, let info = sessionManager.panes(for: session) else { return }
        let target = info.activeIndex + step
        guard info.panes.indices.contains(target) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sessionManager.selectPane(groupId: groupId, paneId: info.panes[target].id)
    }

    // MARK: Controls

    /// Voice and a new workspace, after the windows
    private var controls: some View {
        HStack(spacing: 14) {
            GlassCircle(systemName: "waveform", size: 44, action: onVoice)
            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            GlassCircle(systemName: "plus", size: 44, action: onNewTab)
        }
        .padding(.top, 6)
    }

    private var summary: String {
        let panes = sessionManager.sessionGroups.flatMap(\.panes)
        let blocked = panes.filter { $0.status == .blocked }.count
        let working = panes.filter { $0.status == .working }.count
        var parts: [String] = []
        if blocked > 0 { parts.append("\(blocked) needs you") }
        if working > 0 { parts.append("\(working) working") }
        return parts.isEmpty ? "" : parts.joined(separator: " · ")
    }
}

// MARK: - Window

/// One workspace's live terminal, scaled and cropped to whole rows, under the tab bar's
/// glass pill
private struct SwitcherWindow: View {
    @EnvironmentObject var ghosttyApp: GhosttyApp
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: Session
    let title: String
    let workspace: String
    let panes: [TabPane]
    let activeIndex: Int
    let status: PaneStatus
    /// An agent (Claude) runs in the pane: crops skip its input box
    let isAgent: Bool
    let mode: Mode
    let background: Color
    let terminalSize: CGSize
    let windowWidth: CGFloat
    let onTap: () -> Void
    let onSwipe: (Int) -> Void
    let onFullscreen: () -> Void

    enum Mode: Equatable {
        /// The last couple of lines: what the agent said, or the shell's prompt
        case collapsed
        /// More lines, for a prompt that needs an answer
        case blocked
        /// Typed into: as many lines as fit
        case focused(maxHeight: CGFloat)
        /// The session view
        case fullscreen(height: CGFloat)
    }

    @State private var pullDown: CGFloat = 0

    private static let bottomPad: CGFloat = 8

    private var isFocused: Bool {
        switch mode {
        case .focused, .fullscreen: return true
        default: return false
        }
    }

    private var isFullscreen: Bool {
        if case .fullscreen = mode { return true }
        return false
    }

    private var scale: CGFloat { windowWidth / terminalSize.width }

    /// Where the window's terminal ends (in the terminal's points) and how many rows it
    /// shows, always whole rows from the cursor's
    private var crop: (bottom: CGFloat, rows: Int, cell: CGFloat) {
        let usable = terminalSize.height - AgentSwitcherView.barReserve
        guard let cursor = session.cursorRow else {
            let cell: CGFloat = 17
            return (usable, mode == .blocked ? 7 : 2, cell)
        }
        let cell = cursor.height
        // The last whole row above the key bar's strip
        let lastRow = cursor.top + max(1, floor((usable - cursor.top) / cell)) * cell
        // Claude draws inline: its input row, the box's bottom edge and a footer line,
        // wherever the box is
        let agentBottom = min(lastRow, cursor.top + 3 * cell)
        let promptLine = cursor.top + cell
        switch mode {
        case .collapsed:
            // An agent: the lines above its input box and the blank row Claude leaves
            // before it. A shell: up to its prompt.
            return (isAgent ? cursor.top - 2 * cell : promptLine, 2, cell)
        case .blocked:
            return (isAgent ? agentBottom : lastRow, 7, cell)
        case .focused(let maxHeight), .fullscreen(let maxHeight):
            // Down to the input (Claude's box and footer, or the prompt), as many rows
            // above it as fit: with the keyboard up the rest of the terminal is under it
            let bottom = isAgent ? agentBottom : promptLine
            let fit = Int((maxHeight - AgentSwitcherView.pillStrip - Self.bottomPad) / (cell * scale))
            return (bottom, max(2, min(fit, Int(bottom / cell))), cell)
        }
    }

    private var windowHeight: CGFloat {
        if case .fullscreen(let height) = mode { return height }
        let c = crop
        return AgentSwitcherView.pillStrip + CGFloat(c.rows) * c.cell * scale + Self.bottomPad
    }

    var body: some View {
        let c = crop
        // Where the terminal's top row goes: the crop's bottom at the window's bottom pad,
        // or right under the pill when everything fits (a short session)
        let height = windowHeight
        let top = min(height - Self.bottomPad - c.bottom * scale, AgentSwitcherView.pillStrip)
        let shift = top - (height - terminalSize.height * scale)
        ZStack(alignment: .top) {
            // Clipped by UIKit: the terminal draws with Metal, which SwiftUI's clipping
            // doesn't reach
            ClipHost {
                TerminalView(session: session, isTabSelectorPresented: !isFocused, isVisible: true)
                    .id(session.id)
                    .frame(width: terminalSize.width, height: terminalSize.height)
                    .scaleEffect(scale, anchor: .bottom)
                    .offset(y: shift)
                    .frame(width: windowWidth, height: windowHeight, alignment: .bottom)
                    .environmentObject(ghosttyApp)
                    .environmentObject(sessionManager)
                    .environmentObject(appState)
            }
            .allowsHitTesting(isFocused)

            // The pill's strip over the rows above the crop, and the bottom pad over the
            // rows below it
            if !isFullscreen {
                background
                    .frame(height: AgentSwitcherView.pillStrip)
                    .allowsHitTesting(false)
                background
                    .frame(height: Self.bottomPad)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }

            if !isFocused {
                // Taps and swipes go to the window, not the terminal
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
                    .gesture(swipeGesture)
            }
        }
        .frame(width: windowWidth, height: windowHeight)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isFullscreen ? 0 : 22, style: .continuous)
                .strokeBorder(borderColor, lineWidth: status == .blocked || isFocused ? 1.5 : 1)
        )
        .overlay(alignment: .top) { header }
        .offset(y: pullDown)
        .animation(.spring(duration: 0.35, bounce: 0.12), value: mode)
    }

    private var header: some View {
        HStack(spacing: 8) {
            PanePill(title: title, workspace: workspace, status: status, panes: panes, activeIndex: activeIndex)
                .contentShape(Capsule())
                .onTapGesture { if !isFullscreen { onTap() } }
                .gesture(isFullscreen ? pullGesture : nil)
                .simultaneousGesture(swipeGesture)
            Spacer(minLength: 0)
            if isFocused {
                Button(action: onFullscreen) {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .glass(in: Circle())
                        // A bigger target than it looks
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-6)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(height: AgentSwitcherView.pillStrip, alignment: .top)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height), abs(dx) > 40 else { return }
                onSwipe(dx < 0 ? 1 : -1)
            }
    }

    /// Fullscreen: drag the pill down to go back to the switcher
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in pullDown = max(0, value.translation.height) * 0.6 }
            .onEnded { value in
                let exit = value.translation.height > 80
                withAnimation(.spring(duration: 0.35)) { pullDown = 0 }
                if exit { onFullscreen() }
            }
    }

    private var borderColor: Color {
        if isFullscreen { return .clear }
        if status == .blocked { return Color(uiColor: PaneStatus.blocked.tint).opacity(0.55) }
        return Color.white.opacity(isFocused ? 0.35 : 0.08)
    }
}

/// Hosts SwiftUI content in a UIKit view that clips to its bounds
private struct ClipHost<Content: View>: UIViewRepresentable {
    @ViewBuilder let content: () -> Content

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.backgroundColor = .clear
        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.host = host
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.host?.rootView = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: UIHostingController<Content>?
    }
}

/// The collapsed tab bubble: the pane's glyph and title, the workspace, the pane dots
private struct PanePill: View {
    let title: String
    let workspace: String
    let status: PaneStatus
    let panes: [TabPane]
    let activeIndex: Int

    var body: some View {
        HStack(spacing: 7) {
            StatusGlyph(status: status)
                .frame(width: 9, height: 9)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if workspace != title {
                Text(workspace)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if panes.count > 1 {
                HStack(spacing: 3) {
                    ForEach(Array(panes.enumerated()), id: \.offset) { index, pane in
                        Capsule()
                            .fill(dotColor(pane, active: index == activeIndex))
                            .frame(width: index == activeIndex ? 8 : 4, height: 4)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glass(in: Capsule())
    }

    /// Like the tab bar: other panes that need you or finished show their color
    private func dotColor(_ pane: TabPane, active: Bool) -> Color {
        if active { return Color.white.opacity(0.9) }
        switch pane.status {
        case .blocked, .done: return Color(uiColor: pane.status.tint)
        default: return Color.white.opacity(0.3)
        }
    }
}

/// The tab bar's own animated glyph
private struct StatusGlyph: UIViewRepresentable {
    let status: PaneStatus

    func makeUIView(context: Context) -> PaneStatusIndicator { PaneStatusIndicator() }
    func updateUIView(_ view: PaneStatusIndicator, context: Context) { view.status = status }
}

private struct GlassCircle: View {
    let systemName: String
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.37, weight: .semibold))
                .frame(width: size, height: size)
                .glass(in: Circle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Style

private extension View {
    /// Liquid glass where the system has it, a material otherwise
    @ViewBuilder
    func glass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
        }
    }
}
