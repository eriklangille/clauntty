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

    var body: some View {
        GeometryReader { outer in
            let fullHeight = outer.size.height
            VStack(spacing: 6) {
                if !fullscreen {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                GeometryReader { geo in
                    ScrollViewReader { scroller in
                        ScrollView {
                            VStack(spacing: fullscreen ? 0 : 12) {
                                ForEach(windows, id: \.id) { tab in
                                    if case .terminal(let session) = tab {
                                        window(for: session, tabId: tab.id, viewport: geo.size, fullHeight: fullHeight, scroller: scroller)
                                            .id(tab.id)
                                    }
                                }
                            }
                            .padding(.horizontal, fullscreen ? 0 : 10)
                            .padding(.top, fullscreen ? 0 : 4)
                            // Room to scroll the focused window to the top
                            .padding(.bottom, focused == nil ? 12 : geo.size.height)
                        }
                        .scrollDisabled(fullscreen)
                        .scrollDismissesKeyboard(.never)
                    }
                }
            }
        }
        .background(Color.agentBackground.ignoresSafeArea())
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

    private func window(for session: Session, tabId: UUID, viewport: CGSize, fullHeight: CGFloat, scroller: ScrollViewProxy) -> some View {
        let isFocused = focused == tabId
        let isFull = fullscreen && isFocused
        let info = sessionManager.panes(for: session)
        let panes = info?.panes ?? []
        let activeIndex = info?.activeIndex ?? 0
        let status = panes.indices.contains(activeIndex) ? panes[activeIndex].status : .none
        // The focused terminal avoids the keyboard like a tab; the others keep full height
        let terminalHeight = (isFocused ? viewport.height : fullHeight) - Self.pillStrip
        let windowHeight: CGFloat = {
            if isFull { return viewport.height }
            if isFocused { return min(340, viewport.height - 16) }
            return status == .blocked ? 150 : 92
        }()
        return SwitcherWindow(
            session: session,
            title: panes.indices.contains(activeIndex) ? panes[activeIndex].title : session.title,
            workspace: session.pane?.groupTitle ?? session.connectionConfig.displayName,
            panes: panes,
            activeIndex: activeIndex,
            status: status,
            isFocused: isFocused,
            isFullscreen: isFull,
            terminalSize: CGSize(width: viewport.width, height: terminalHeight),
            windowHeight: windowHeight,
            onTap: { toggleFocus(tabId, session: session, scroller: scroller) },
            onSwipe: { step in swipe(session, step: step) },
            onFullscreen: { setFullscreen(!fullscreen, tabId: tabId, scroller: scroller) }
        )
    }

    // MARK: Actions

    private func toggleFocus(_ tabId: UUID, session: Session, scroller: ScrollViewProxy) {
        if fullscreen { return }
        withAnimation(.spring(duration: 0.35, bounce: 0.12)) {
            if focused == tabId {
                focused = nil
                frozenOrder = nil
            } else {
                frozenOrder = frozenOrder ?? windows.map(\.id)
                focused = tabId
                sessionManager.switchTo(session)
            }
        }
        if focused == tabId {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                withAnimation(.spring(duration: 0.35)) { scroller.scrollTo(tabId, anchor: .top) }
            }
        }
    }

    private func setFullscreen(_ on: Bool, tabId: UUID, scroller: ScrollViewProxy) {
        withAnimation(.spring(duration: 0.42, bounce: 0.1)) {
            fullscreen = on
            scroller.scrollTo(tabId, anchor: .top)
        }
    }

    /// Show the workspace's next or previous pane in this window
    private func swipe(_ session: Session, step: Int) {
        guard let groupId = session.groupId, let info = sessionManager.panes(for: session) else { return }
        let target = info.activeIndex + step
        guard info.panes.indices.contains(target) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sessionManager.selectPane(groupId: groupId, paneId: info.panes[target].id)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            GlassCircle(systemName: "waveform", action: onVoice)
            Spacer()
            Text(summary)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            GlassCircle(systemName: "plus", action: onNewTab)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
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

/// One workspace's live terminal, scaled and cropped to its last lines, under the
/// tab bar's glass pill
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
    let isFocused: Bool
    let isFullscreen: Bool
    let terminalSize: CGSize
    let windowHeight: CGFloat
    let onTap: () -> Void
    let onSwipe: (Int) -> Void
    let onFullscreen: () -> Void

    @State private var pullDown: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / terminalSize.width
            // Fullscreen shows the whole terminal. Otherwise the window ends just below the
            // cursor (a shell's prompt, Claude's input box), or above the key bar's strip.
            let contentBottom = min(session.cursorBottom.map { $0 + 8 } ?? terminalSize.height,
                                    terminalSize.height - AgentSwitcherView.barReserve)
            let maxShift = max(0, terminalSize.height * scale - (geo.size.height - AgentSwitcherView.pillStrip))
            let hiddenBottom = isFullscreen ? 0 : min(max(0, (terminalSize.height - contentBottom) * scale), maxShift)
            ZStack(alignment: .top) {
                // Clipped by UIKit: the terminal draws with Metal, which SwiftUI's clipping
                // doesn't reach
                ClipHost {
                    TerminalView(session: session, isTabSelectorPresented: !isFocused, isVisible: true)
                        .id(session.id)
                        .frame(width: terminalSize.width, height: terminalSize.height)
                        .scaleEffect(scale, anchor: .bottom)
                        .offset(y: hiddenBottom)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                        .environmentObject(ghosttyApp)
                        .environmentObject(sessionManager)
                        .environmentObject(appState)
                }
                .allowsHitTesting(isFocused)

                // The pill's strip, over the terminal's top rows
                if !isFullscreen {
                    Color.agentBackground
                        .frame(height: AgentSwitcherView.pillStrip)
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
        }
        .frame(height: windowHeight)
        .background(Color.agentBackground)
        .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isFullscreen ? 0 : 22, style: .continuous)
                .strokeBorder(borderColor, lineWidth: status == .blocked || isFocused ? 1.5 : 1)
        )
        .overlay(alignment: .top) { header }
        .offset(y: pullDown)
    }

    private var header: some View {
        HStack(spacing: 8) {
            PanePill(title: title, workspace: workspace, status: status, panes: panes, activeIndex: activeIndex)
                .contentShape(Capsule())
                .onTapGesture(perform: onTap)
                .gesture(isFullscreen ? pullGesture : nil)
                .simultaneousGesture(swipeGesture)
            Spacer(minLength: 0)
            if isFocused {
                GlassCircle(systemName: isFullscreen ? "chevron.down" : "arrow.up.left.and.arrow.down.right",
                            size: 36, action: onFullscreen)
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

private extension Color {
    /// Behind the windows: the terminal's default background
    static let agentBackground = Color(red: 40 / 255, green: 44 / 255, blue: 52 / 255)
}

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
