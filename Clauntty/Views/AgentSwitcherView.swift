import Combine
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
    /// The window the pager is settled on: one swipe moves one window, like short videos
    @State private var index = 0
    /// The finger's pull while paging
    @State private var drag: CGFloat = 0
    /// The keyboard's height, kept when it hides: a focused window is sized for it, so the
    /// keyboard coming and going never resizes anything
    @State private var keyboardHeight: CGFloat = 336
    @State private var keyboardVisible = false
    /// Bumped when a window's cursor moves (its crop and height follow it)
    @State private var cursorTick = 0

    /// How much of the window above stays in view, below the status bar, to tap
    static let peek: CGFloat = 44
    /// Room at the top of each window for its pill
    static let pillStrip: CGFloat = 52
    /// What the terminal keeps at its bottom for the key bar
    static let barReserve: CGFloat = 78
    /// The key bar above the keyboard
    static let keyBarAboveKeyboard: CGFloat = 74
    static let spacing: CGFloat = 10

    @EnvironmentObject private var ghosttyApp: GhosttyApp
    @ObservedObject private var themeManager = ThemeManager.shared

    /// The terminal's background, behind and around the windows
    private var background: Color {
        themeManager.theme(withId: ghosttyApp.currentThemeId)?.backgroundColor
            ?? Color(red: 40 / 255, green: 44 / 255, blue: 52 / 255)
    }

    private let snap = Animation.spring(response: 0.3, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let items = windows.compactMap { tab -> (id: UUID, session: Session)? in
                if case .terminal(let session) = tab { return (tab.id, session) }
                return nil
            }
            let specs = items.map { spec(for: $0.session, tabId: $0.id, size: size) }
            // Fullscreen lays the other windows out at zero height: position with that
            let laidOut = zip(items, specs).map { item, spec in fullscreen && focused != item.id ? 0 : spec.height }
            let tops = Self.tops(laidOut, spacing: fullscreen ? 0 : Self.spacing)
            let focusedIndex = items.firstIndex { $0.id == focused }
            let current = fullscreen ? (focusedIndex ?? 0) : min(index, max(0, items.count - 1))
            let anchor: CGFloat = fullscreen ? 0 : (current == 0 ? 4 : Self.peek)
            let offset = (tops.indices.contains(current) ? anchor - tops[current] : 0) + drag

            VStack(spacing: fullscreen ? 0 : Self.spacing) {
                // One list in every mode: a window keeps its live terminal view. Fullscreen
                // shrinks the others away rather than showing the window somewhere else,
                // which would make a new, empty terminal.
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    let hidden = fullscreen && focused != item.id
                    window(for: item.session, tabId: item.id, index: i, spec: specs[i], size: size)
                        .frame(height: hidden ? 0 : specs[i].height, alignment: .top)
                        .clipped()
                        .opacity(hidden ? 0 : 1)
                        .allowsHitTesting(!hidden)
                }
                if !fullscreen {
                    controls
                }
            }
            .padding(.horizontal, fullscreen ? 0 : 10)
            .frame(width: size.width, alignment: .top)
            .offset(y: offset)
            .frame(width: size.width, height: size.height, alignment: .top)
            .contentShape(Rectangle())
            .simultaneousGesture(fullscreen ? nil : pager(count: items.count, heights: specs.map(\.height), items: items))
            .onReceive(cursorChanges(items.map(\.session))) { _ in cursorTick &+= 1 }
        }
        .ignoresSafeArea(.keyboard)
        // The window above slides under the status bar: fade it there, so only its last
        // lines show below
        .overlay(alignment: .top) {
            if !fullscreen {
                GeometryReader { g in
                    LinearGradient(stops: [
                        .init(color: background, location: 0),
                        .init(color: background, location: 0.7),
                        .init(color: background.opacity(0), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: g.safeAreaInsets.top + 10)
                    .offset(y: -g.safeAreaInsets.top)
                }
                .allowsHitTesting(false)
            }
        }
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            if let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect, frame.height > 100 {
                keyboardHeight = frame.height
            }
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }

    // MARK: Layout

    /// Each window's mode and height, from the same math the window crops with
    private func spec(for session: Session, tabId: UUID, size: CGSize) -> WindowSpec {
        _ = cursorTick
        let isFocused = focused == tabId
        let isFull = fullscreen && isFocused
        let info = sessionManager.panes(for: session)
        let status = info.flatMap { $0.panes.indices.contains($0.activeIndex) ? $0.panes[$0.activeIndex].status : nil } ?? .none
        let isAgent = session.pane.flatMap { sessionManager.paneStates[$0.paneId] }?.hasAgent ?? false
        // One size in every mode, so focusing or the keyboard never resizes the pane (and
        // Claude never redraws): windows only crop it
        let terminalSize = CGSize(width: size.width, height: size.height - Self.pillStrip)
        let keyboardSpace = keyboardHeight + Self.keyBarAboveKeyboard
        let mode: SwitcherWindow.Mode = {
            if isFull {
                // Down to the key bar: above the keyboard when it's up
                return .fullscreen(height: size.height - (keyboardVisible ? keyboardSpace : Self.barReserve))
            }
            // The room above the keyboard, below the window above's peek
            if isFocused { return .focused(maxHeight: max(160, size.height - Self.peek - keyboardSpace - 8)) }
            return status == .blocked ? .blocked : .collapsed
        }()
        let width = isFull ? size.width : size.width - 20
        let height = SwitcherWindow.height(cursor: session.cursorRow, mode: mode, isAgent: isAgent,
                                           terminalSize: terminalSize, windowWidth: width)
        return WindowSpec(mode: mode, isAgent: isAgent, status: status, terminalSize: terminalSize, width: width, height: height)
    }

    struct WindowSpec {
        let mode: SwitcherWindow.Mode
        let isAgent: Bool
        let status: PaneStatus
        let terminalSize: CGSize
        let width: CGFloat
        let height: CGFloat
    }

    static func tops(_ heights: [CGFloat], spacing: CGFloat) -> [CGFloat] {
        var y: CGFloat = 0
        return heights.map { h in
            defer { y += h + spacing }
            return y
        }
    }

    private func cursorChanges(_ sessions: [Session]) -> AnyPublisher<Void, Never> {
        // dropFirst: a @Published emits its value on subscribing, and this subscribes on
        // every render
        Publishers.MergeMany(sessions.map { $0.$cursorRow.dropFirst().removeDuplicates().map { _ in () }.eraseToAnyPublisher() })
            .eraseToAnyPublisher()
    }

    // MARK: Paging

    /// One swipe, one window: follows the finger, then springs to the next or previous
    private func pager(count: Int, heights: [CGFloat], items: [(id: UUID, session: Session)]) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dy) > abs(dx) else { return }
                let atEdge = (index == 0 && dy > 0) || (index >= count - 1 && dy < 0)
                drag = atEdge ? dy * 0.3 : dy
            }
            .onEnded { value in
                let dy = value.translation.height
                let projected = value.predictedEndTranslation.height
                let current = min(index, max(0, count - 1))
                let threshold = min(120, (heights.indices.contains(current) ? heights[current] : 120) * 0.3)
                var target = current
                if dy < -threshold || projected < -200 { target = current + 1 }
                if dy > threshold || projected > 200 { target = current - 1 }
                target = min(max(0, target), max(0, count - 1))
                let moved = target != current
                withAnimation(snap) {
                    index = target
                    drag = 0
                    // Typing: the keyboard goes with the swipe
                    if moved, focused != nil, items.indices.contains(target) {
                        focused = items[target].id
                    }
                }
                if moved {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if focused != nil, items.indices.contains(target) {
                        sessionManager.switchTo(items[target].session)
                    }
                }
            }
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

    private func window(for session: Session, tabId: UUID, index i: Int, spec: WindowSpec, size: CGSize) -> some View {
        let info = sessionManager.panes(for: session)
        let panes = info?.panes ?? []
        let activeIndex = info?.activeIndex ?? 0
        return SwitcherWindow(
            session: session,
            title: panes.indices.contains(activeIndex) ? panes[activeIndex].title : session.title,
            workspace: session.pane?.groupTitle ?? session.connectionConfig.displayName,
            panes: panes,
            activeIndex: activeIndex,
            status: spec.status,
            isAgent: spec.isAgent,
            mode: spec.mode,
            background: background,
            terminalSize: spec.terminalSize,
            windowWidth: spec.width,
            windowHeight: spec.height,
            onTap: { tapped(tabId, index: i, session: session) },
            onSwipe: { step in swipe(session, step: step) },
            onFullscreen: { setFullscreen(!fullscreen) }
        )
    }

    // MARK: Actions

    /// Tap a window to type into it; tap the focused one's pill to put it down
    private func tapped(_ tabId: UUID, index i: Int, session: Session) {
        if fullscreen { return }
        withAnimation(snap) {
            if focused == tabId {
                focused = nil
                frozenOrder = nil
            } else {
                frozenOrder = frozenOrder ?? windows.map(\.id)
                focused = tabId
                index = i
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
struct SwitcherWindow: View {
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
    /// From the switcher, which lays the windows out with the same math
    let windowHeight: CGFloat
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

    static let bottomPad: CGFloat = 8

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

    private var crop: (bottom: CGFloat, rows: Int, cell: CGFloat) {
        Self.crop(cursor: session.cursorRow, mode: mode, isAgent: isAgent, terminalSize: terminalSize, windowWidth: windowWidth)
    }

    /// Where the window's terminal ends (in the terminal's points) and how many rows it
    /// shows, always whole rows from the cursor's
    static func crop(cursor: Session.CursorRow?, mode: Mode, isAgent: Bool, terminalSize: CGSize, windowWidth: CGFloat)
        -> (bottom: CGFloat, rows: Int, cell: CGFloat) {
        let scale = windowWidth / terminalSize.width
        let usable = terminalSize.height - AgentSwitcherView.barReserve
        guard let cursor else {
            return (usable, mode == .blocked ? 7 : 2, 17)
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
            let fit = Int((maxHeight - AgentSwitcherView.pillStrip - bottomPad) / (cell * scale))
            return (bottom, max(2, min(fit, Int(bottom / cell))), cell)
        }
    }

    static func height(cursor: Session.CursorRow?, mode: Mode, isAgent: Bool, terminalSize: CGSize, windowWidth: CGFloat) -> CGFloat {
        if case .fullscreen(let height) = mode { return height }
        let c = crop(cursor: cursor, mode: mode, isAgent: isAgent, terminalSize: terminalSize, windowWidth: windowWidth)
        let scale = windowWidth / terminalSize.width
        return AgentSwitcherView.pillStrip + CGFloat(c.rows) * c.cell * scale + bottomPad
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
            // Fullscreen it's the terminal; in the switcher a swipe anywhere pages
            .allowsHitTesting(isFullscreen)

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

            if !isFullscreen {
                // Taps and sideways swipes go to the window, not the terminal; vertical
                // drags page the switcher
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { if !isFocused { onTap() } }
                    .simultaneousGesture(swipeGesture)
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
                .simultaneousGesture(isFullscreen ? nil : swipeGesture)
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
                let dy = value.translation.height
                if abs(dx) > abs(dy), abs(dx) > 40 {
                    onSwipe(dx < 0 ? 1 : -1)
                }
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
