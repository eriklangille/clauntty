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
    /// The overview's scroll position (nothing focused): it scrolls freely
    @State private var scrollOffset: CGFloat = 0

    /// The overview's status line above the windows
    static let headerHeight: CGFloat = 30
    /// The controls row after the windows
    static let controlsHeight: CGFloat = 56

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
            let spacing = fullscreen ? 0 : Self.spacing
            let lead = fullscreen ? 0 : Self.headerHeight + spacing
            let tops = Self.tops(laidOut, spacing: spacing).map { $0 + lead }
            let focusedIndex = items.firstIndex { $0.id == focused }
            let current = fullscreen ? (focusedIndex ?? 0) : min(index, max(0, items.count - 1))
            let contentHeight = lead + laidOut.reduce(0, +) + spacing * CGFloat(max(0, items.count - 1))
                + (fullscreen ? 0 : spacing + Self.controlsHeight)
            let maxScroll = max(0, contentHeight - size.height + 20)
            let offset: CGFloat = {
                if focused == nil && !fullscreen {
                    // Overview: free scrolling, rubber-banded past the ends
                    let raw = scrollOffset - drag
                    let banded = raw < 0 ? raw * 0.3 : (raw > maxScroll ? maxScroll + (raw - maxScroll) * 0.3 : raw)
                    return -banded
                }
                let anchor: CGFloat = fullscreen ? 0 : (current == 0 ? 4 : Self.peek)
                return (tops.indices.contains(current) ? anchor - tops[current] : 0) + (focused == nil ? 0 : drag)
            }()

            VStack(spacing: fullscreen ? 0 : Self.spacing) {
                if !fullscreen {
                    header
                        .frame(height: Self.headerHeight)
                }
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
                        .frame(height: Self.controlsHeight)
                }
            }
            .padding(.horizontal, fullscreen ? 0 : 10)
            .frame(width: size.width, alignment: .top)
            .offset(y: offset)
            .frame(width: size.width, height: size.height, alignment: .top)
            .contentShape(Rectangle())
            .simultaneousGesture(fullscreen ? nil : pager(count: items.count, heights: specs.map(\.height), items: items, maxScroll: maxScroll))
            .overlay(alignment: .trailing) {
                if focused != nil && !fullscreen {
                    StatusRail(statuses: items.map { attentionStatus($0.session) }, current: current) { target in
                        jump(to: target, items: items)
                    } onScrubEnd: { target in
                        commitFocus(target, items: items)
                    }
                    .padding(.trailing, 2)
                    // Centered in the room above the keyboard
                    .frame(height: size.height - keyboardHeight - Self.keyBarAboveKeyboard, alignment: .center)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .onChange(of: focused) { old, new in
                // Back to the overview: keep the window where it was on screen
                if new == nil, old != nil, tops.indices.contains(current) {
                    let anchor: CGFloat = current == 0 ? 4 : Self.peek
                    scrollOffset = min(max(0, tops[current] - anchor), maxScroll)
                }
            }
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
            // The keyboard put away: back to the overview
            if focused != nil && !fullscreen {
                withAnimation(snap) {
                    focused = nil
                    frozenOrder = nil
                }
            }
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
        let keyboardSpace = keyboardHeight + Self.keyBarAboveKeyboard
        // Fullscreen is the session view: like a tab, the terminal fits the screen below
        // the pill and above the keyboard (it reserves the key bar itself), so a TUI
        // shows top to bottom. That resizes it once, as switching tabs does.
        let terminalSize = isFull
            ? CGSize(width: size.width, height: size.height - Self.pillStrip - (keyboardVisible ? keyboardHeight : 0))
            : CGSize(width: size.width, height: size.height - Self.pillStrip)
        let mode: SwitcherWindow.Mode = {
            if isFull {
                // Down to the key bar: above the keyboard when it's up
                return .fullscreen(height: size.height)
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

    /// Overview: scrolls freely with momentum. Typing: one swipe, one window, through the
    /// attention order; the keyboard goes with it.
    private func pager(count: Int, heights: [CGFloat], items: [(id: UUID, session: Session)], maxScroll: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dy) > abs(dx) else { return }
                if focused == nil {
                    drag = dy
                } else {
                    let atEdge = (index == 0 && dy > 0) || (index >= count - 1 && dy < 0)
                    drag = atEdge ? dy * 0.3 : dy
                }
            }
            .onEnded { value in
                let dy = value.translation.height
                let projected = value.predictedEndTranslation.height
                if focused == nil {
                    // Carry on with the flick's momentum, then settle within the ends
                    let target = min(max(0, scrollOffset - projected), maxScroll)
                    withAnimation(.spring(response: 0.5, dampingFraction: 1)) {
                        scrollOffset = target
                        drag = 0
                    }
                    return
                }
                let current = min(index, max(0, count - 1))
                let threshold = min(120, (heights.indices.contains(current) ? heights[current] : 120) * 0.3)
                var target = current
                if dy < -threshold || projected < -200 { target = current + 1 }
                if dy > threshold || projected > 200 { target = current - 1 }
                target = min(max(0, target), max(0, count - 1))
                if target == current {
                    withAnimation(snap) { drag = 0 }
                    return
                }
                commitFocus(target, items: items)
            }
    }

    /// Type into the window at `target`, then put the queue back in attention order
    /// (the focused window stays put on screen; the others settle around it)
    private func commitFocus(_ target: Int, items: [(id: UUID, session: Session)]) {
        guard items.indices.contains(target) else { return }
        let id = items[target].id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(snap) {
            focused = id
            index = target
            drag = 0
        }
        sessionManager.switchTo(items[target].session)
        // Answered agents drop down the queue; the next one needing you comes next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let order = attentionOrder()
            guard order != frozenOrder, let newIndex = order.firstIndex(of: id) else { return }
            withAnimation(snap) {
                frozenOrder = order
                index = newIndex
            }
        }
    }

    /// The rail tapped or scrubbed: show that window (focus follows when the finger lifts)
    private func jump(to target: Int, items: [(id: UUID, session: Session)]) {
        guard items.indices.contains(target), target != index else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(snap) { index = target }
    }

    // MARK: Windows

    /// Terminal tabs in attention order (frozen while you type)
    private var windows: [TabItem] {
        let tabs = terminalTabs
        let order = frozenOrder ?? attentionOrder()
        return tabs.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    private var terminalTabs: [TabItem] {
        sessionManager.orderedTabs().filter {
            if case .terminal = $0 { return true }
            return false
        }
    }

    /// Needs you, then finished and unseen, then the rest in tab order
    private func attentionOrder() -> [UUID] {
        terminalTabs.enumerated().sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element.id)
    }

    private func rank(_ tab: TabItem) -> Int {
        guard case .terminal(let session) = tab else { return 4 }
        // Only what needs you moves up. A window that starts or stops working (the one
        // you just typed into, say) keeps its place.
        switch attentionStatus(session) {
        case .blocked: return 0
        case .done: return 1
        default: return 2
        }
    }

    /// The most pressing state among a workspace's panes
    private func attentionStatus(_ session: Session) -> PaneStatus {
        let statuses = sessionManager.panes(for: session)?.panes.map(\.status) ?? []
        for s in [PaneStatus.blocked, .done, .working, .idle] where statuses.contains(s) { return s }
        return .none
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
                drag = 0
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

    // MARK: Header and controls

    /// What needs you, or that nothing does
    private var header: some View {
        let panes = sessionManager.sessionGroups.flatMap(\.panes)
        let blocked = panes.filter { $0.status == .blocked }.count
        let done = panes.filter { $0.status == .done }.count
        return HStack(spacing: 6) {
            if blocked == 0 && done == 0 {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(uiColor: PaneStatus.done.tint))
                Text("All caught up")
            } else {
                if blocked > 0 {
                    Circle().fill(Color(uiColor: PaneStatus.blocked.tint)).frame(width: 7, height: 7)
                    Text(blocked == 1 ? "1 needs you" : "\(blocked) need you")
                }
                if done > 0 {
                    Circle().fill(Color(uiColor: PaneStatus.done.tint)).frame(width: 7, height: 7)
                        .padding(.leading, blocked > 0 ? 6 : 0)
                    Text("\(done) done")
                }
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    /// Voice and a new workspace, after the windows
    private var controls: some View {
        HStack(spacing: 14) {
            GlassCircle(systemName: "waveform", size: 44, action: onVoice)
            GlassCircle(systemName: "plus", size: 44, action: onNewTab)
        }
        .padding(.top, 6)
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
        // Fullscreen: the whole terminal, right under the pill
        let top = isFullscreen ? AgentSwitcherView.pillStrip : min(height - Self.bottomPad - c.bottom * scale, AgentSwitcherView.pillStrip)
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
                    // Typing into it, a tap pastes, as in a tab
                    .onTapGesture { if isFocused { session.presentPasteMenu?() } else { onTap() } }
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
        // Laid out by the switcher: no keyboard avoidance or safe area insets, which
        // would shift the terminal when the window reaches under the keyboard
        host.safeAreaRegions = []
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

/// While typing: one dot per window, in queue order, colored like the tab glyphs. Tap a
/// dot to go there; drag along the rail to scrub.
private struct StatusRail: View {
    let statuses: [PaneStatus]
    let current: Int
    let onSelect: (Int) -> Void
    let onScrubEnd: (Int) -> Void

    private static let pitch: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { i, status in
                ZStack {
                    if i == current {
                        Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                    }
                    if status == .none || status == .idle {
                        Circle().fill(Color.white.opacity(0.35)).frame(width: 6, height: 6)
                    } else {
                        StatusGlyph(status: status).frame(width: 8, height: 8)
                    }
                }
                .frame(width: 24, height: Self.pitch)
            }
        }
        .padding(.vertical, 8)
        .glass(in: Capsule())
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in onSelect(slot(at: value.location.y)) }
                .onEnded { value in onScrubEnd(slot(at: value.location.y)) }
        )
    }

    private func slot(at y: CGFloat) -> Int {
        min(max(0, Int((y - 8) / Self.pitch)), statuses.count - 1)
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
