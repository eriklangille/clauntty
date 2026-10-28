import Combine
import SwiftUI
import UIKit

/// Agent mode (Settings → Agent Mode): instead of a tab bar, one window per workspace
/// onto its live terminal. Tap a window to type into it (the pane becomes the active
/// tab: keyboard, key bar); tap another to switch, keyboard up. Swipe a window to
/// switch its panes. Fullscreen grows the window into the whole screen, the session
/// view; collapse or drag its pill down to come back. The typed-into window's pill opens
/// the tab's session menu (new pane, new tab, ports, close, its panes).
///
/// A web tab is its workspace's last pane (the one it was opened from): swipe the window
/// to it, tap the page to go fullscreen. Opening a port from a terminal (`clauntty tab`)
/// goes straight to fullscreen; coming back returns to the terminal you were typing into.
/// A web tab with no workspace open is a window of its own, after the terminals.
///
/// Every terminal keeps the phone's full size and is only scaled and cropped into its
/// window, so opening the switcher, focusing or going fullscreen never resizes a pane.
struct AgentSwitcherView: View {
    @EnvironmentObject var sessionManager: SessionManager
    let onNewTab: () -> Void
    let onVoice: () -> Void
    let onSettings: () -> Void
    let onPorts: (Session) -> Void

    /// The window typed into (its tab id)
    @State private var focused: UUID?
    @State private var fullscreen = false
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
    /// Where the layout's top is on screen: the key bar is measured from the screen bottom
    @State private var originY: CGFloat = 0
    /// Bumped whenever the keyboard shows: a pending collapse to the overview checks it
    @State private var keyboardShows = 0
    /// The terminal typed into when a web tab went fullscreen: back to it after
    @State private var webReturn: UUID?
    /// The web tab a window shows instead of its terminal (window id → web tab id)
    @State private var shownWeb: [UUID: UUID] = [:]
    /// What a vertical drag in the typed-into window does, chosen when it starts
    @State private var dragMode: DragMode?
    /// How far the finger had moved at the last scroll step
    @State private var scrolledY: CGFloat = 0
    /// When the drag chose (a flick is over quickly)
    @State private var dragStart = Date()
    /// The fastest the finger went in this drag
    @State private var peakSpeed: CGFloat = 0
    /// The window whose pill menu is open
    @State private var menuWindow: UUID?
    /// The window whose menu is closing: it stays over the others until the panel is
    /// back in its pill
    @State private var closingMenu: UUID?
    /// Over a TUI the scroll waits until the drag can't be a flick: it's mouse wheel
    /// events, which a flick's undo wouldn't take back cleanly
    @State private var holdScroll = false
    /// Fullscreen, another window just finished or needs you: every window's dot comes
    /// out of the screen's edge for `edgeTime`
    @State private var edgeOut = false
    /// Bumped each time the edge comes out: only the latest timer puts it back
    @State private var edgeShows = 0
    /// A finger on the edge keeps it out
    @State private var edgeHeld = false
    /// Landscape: typing is fullscreen, with no room for the windows around it
    @State private var landscape = false
    /// Fullscreen because typing in landscape: back to the window in portrait
    @State private var landscapeFull = false
    /// The window held in the overview to move it: it follows the finger, the windows
    /// shrink so most fit, and the others make room
    @State private var moving: UUID?
    /// The finger on screen while moving
    @State private var moveY: CGFloat = 0
    /// Where the finger holds the moving window, from its top
    @State private var moveGrab: CGFloat = 0
    /// Whether the finger's place in the moving window is known (from its first drag)
    @State private var moveGrabbed = false
    /// The windows it moves among: the terminals, or the web tabs with windows of their own
    @State private var moveList: [UUID] = []
    /// How far the overview scrolls with the windows shrunk: the edges scroll it
    @State private var moveMaxScroll: CGFloat = 0
    /// Where the moved window was let go, from the top of the view: it stays there as the
    /// windows grow back
    @State private var dropTop: CGFloat = 0
    /// The window whose images are open (`clauntty show`), zoomed from its corner
    @State private var openImages: OpenImages?
    /// The window whose images were last opened: they go once the viewer has closed
    @State private var viewedImages: UUID?
    @Namespace private var imagesZoom
    /// A finger on the status rail: the window it's over is lit
    @State private var scrubbing = false

    struct OpenImages: Identifiable {
        /// The window's tab id
        let id: UUID
    }

    enum DragMode {
        /// A quick swipe: the next or previous window
        case page
        /// A slower drag: scrolls the window's terminal (or page) under the finger
        case scroll
    }

    /// Starting faster than this (points a second), a drag in the typed-into window
    /// pages right away; slower, it scrolls back through the terminal...
    static let flickSpeed: CGFloat = 800
    /// ...unless it turns out a flick: over within `flickTime`, at its fastest quicker
    /// than `flickPeakSpeed` or on average quicker than `flickAverageSpeed`. Then the
    /// lines it scrolled go back and it pages. (A flick is still speeding up when it
    /// starts, so its start alone reads as a scroll; reading drags are slow throughout,
    /// or longer.)
    static let flickPeakSpeed: CGFloat = 900
    static let flickAverageSpeed: CGFloat = 450
    static let flickTime: TimeInterval = 0.5
    /// How long the edge's dots stay out
    static let edgeTime: TimeInterval = 10

    /// Above the first window, below the status bar
    static let topPad: CGFloat = 8
    /// Settings, voice and a new tab, above the first window: in the overview pinned to its
    /// top, and typing into the first window, the band where a window above would peek
    static let headerHeight: CGFloat = 52

    /// How much of the window above stays in view, below the status bar, to tap: its
    /// whole card
    static var peek: CGFloat { SwitcherWindow.cardHeight + spacing }
    /// Room at the top of each window for its pill
    static let pillStrip: CGFloat = 52
    /// What the terminal keeps at its bottom for the key bar
    static var barReserve: CGFloat { 78 - keyBarSaving }
    /// The key bar above the keyboard
    static var keyBarAboveKeyboard: CGFloat { 66 - keyBarSaving }
    /// The key bar is shorter in landscape
    static var keyBarSaving: CGFloat {
        KeyboardAccessoryView.screenIsCompact ? KeyboardAccessoryView.regularHeight - KeyboardAccessoryView.compactHeight : 0
    }
    static let spacing: CGFloat = 10
    /// The status rail's column, beside the windows while typing
    static let railColumn: CGFloat = 32

    @EnvironmentObject private var ghosttyApp: GhosttyApp
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var voice = VoiceAgent.shared

    /// The terminal's background, behind and around the windows
    private var background: Color {
        themeManager.theme(withId: ghosttyApp.currentThemeId)?.backgroundColor
            ?? Color(red: 40 / 255, green: 44 / 255, blue: 52 / 255)
    }

    private var isLightTheme: Bool {
        themeManager.theme(withId: ghosttyApp.currentThemeId)?.isLight == true
    }

    private let snap = Animation.spring(response: 0.3, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let items = windows.compactMap { tab -> (id: UUID, session: Session)? in
                if case .terminal(let session) = tab { return (tab.id, session) }
                return nil
            }
            let specs = items.enumerated().map { i, item in spec(for: item.session, tabId: item.id, index: i, size: size) }
            let webs = webTabs
            // Web tabs without a workspace window: windows of their own
            let loose = webs.filter { web in !items.contains { $0.id == web.workspaceId } }
            let webWidth = size.width - 10 - (focused != nil && !fullscreen ? Self.railColumn : 10)
            // Every window's id, terminals then loose web tabs, in layout order: the pager's
            // stops
            let ids = items.map(\.id) + loose.map(\.id)
            // Fullscreen lays the other windows out at zero height: position with that
            let laidOut = zip(items, specs).map { item, spec in fullscreen && focused != item.id ? 0 : spec.height }
                + loose.map { web in
                    if fullscreen { return focused == web.id ? size.height : 0 }
                    if moving != nil { return Self.movingHeight(width: webWidth, size: size) }
                    if focused == web.id { return max(160, barTop(size) - Self.peek - 10) }
                    return Self.webHeight(width: webWidth, size: size)
                }
            let spacing = fullscreen ? 0 : Self.spacing
            let lead = fullscreen ? 0 : Self.topPad + Self.headerHeight
            let tops = Self.tops(laidOut, spacing: spacing).map { $0 + lead }
            let focusedIndex = ids.firstIndex { $0 == focused }
            let current = fullscreen ? (focusedIndex ?? 0) : min(index, max(0, ids.count - 1))
            let contentHeight = lead + laidOut.reduce(0, +) + spacing * CGFloat(ids.count)
            // The last window stops above the key bar
            let maxScroll = max(0, contentHeight - barTop(size) + Self.spacing)
            let offset: CGFloat = {
                if focused == nil && !fullscreen {
                    // Overview: free scrolling, rubber-banded past the ends
                    let raw = scrollOffset - drag
                    let banded = raw < 0 ? raw * 0.3 : (raw > maxScroll ? maxScroll + (raw - maxScroll) * 0.3 : raw)
                    return -banded
                }
                let anchor: CGFloat = fullscreen ? 0 : Self.anchor(for: current)
                return (tops.indices.contains(current) ? anchor - tops[current] : 0) + (focused == nil ? 0 : drag)
            }()

            VStack(spacing: fullscreen ? 0 : Self.spacing) {
                // One list in every mode: a window keeps its live terminal view. Fullscreen
                // shrinks the others away rather than showing the window somewhere else,
                // which would make a new, empty terminal.
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    let hidden = fullscreen && focused != item.id
                    window(for: item.session, tabId: item.id, index: i, spec: specs[i], size: size,
                           menuRoom: menuRoom(top: tops[i] + offset, size: size),
                           menuAbove: menuAbove(top: tops[i] + offset)) { phase in
                        move(item.id, phase, among: items.map(\.id), ids: ids, tops: tops, heights: laidOut, maxScroll: maxScroll)
                    }
                        .frame(height: hidden ? 0 : specs[i].height, alignment: .top)
                        // Its open menu reaches over the windows below
                        .clipShape(WindowClip(isOff: menuLifted == item.id))
                        .modifier(Lifted(isOn: moving == item.id, offset: movedTop - tops[i]))
                        .zIndex(moving == item.id ? 2 : menuLifted == item.id ? 1 : 0)
                        .opacity(hidden ? 0 : 1)
                        .allowsHitTesting(!hidden)
                }
                ForEach(Array(loose.enumerated()), id: \.element.id) { i, web in
                    let isFull = fullscreen && focused == web.id
                    let hidden = fullscreen && !isFull
                    WebWindow(
                        webTab: web,
                        isFullscreen: isFull,
                        isFocused: focused == web.id,
                        background: background,
                        contentSize: Self.webSize(size),
                        windowWidth: isFull ? size.width : webWidth,
                        windowHeight: laidOut[items.count + i],
                        menu: menuWindow == web.id ? WindowMenu(caption: web.urlDisplayString, actions: webActions(web)) : nil,
                        isMenuOpen: menuWindow == web.id,
                        menuRoom: menuRoom(top: tops[items.count + i] + offset, size: size),
                        menuAbove: menuAbove(top: tops[items.count + i] + offset),
                        onMenu: { open in setMenu(open ? web.id : nil) },
                        onOpen: { openWeb(web) },
                        onExit: { exitWeb() },
                        canMove: canMove(web.id),
                        onMove: { phase in
                            move(web.id, phase, among: loose.map(\.id), ids: ids, tops: tops, heights: laidOut, maxScroll: maxScroll)
                        },
                        isOverview: focused == nil
                    )
                    .frame(height: hidden ? 0 : laidOut[items.count + i], alignment: .top)
                    .clipShape(WindowClip(isOff: menuLifted == web.id))
                    .modifier(Lifted(isOn: moving == web.id, offset: movedTop - tops[items.count + i]))
                    .zIndex(moving == web.id ? 2 : menuLifted == web.id ? 1 : 0)
                    .opacity(hidden ? 0 : 1)
                    .allowsHitTesting(!hidden)
                }
            }
            .padding(.top, lead)
            .overlay(alignment: .top) {
                if !fullscreen {
                    header
                        .padding(.top, Self.topPad)
                        // The windows fade out under it and the status bar
                        .background(alignment: .top) {
                            LinearGradient(stops: [.init(color: background, location: 0),
                                                   .init(color: background, location: 0.6),
                                                   .init(color: background.opacity(0), location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                                .padding(.horizontal, -10)
                                .padding(.top, -80)
                                .padding(.bottom, -16)
                                .opacity(focused == nil ? 1 : 0)
                                .allowsHitTesting(false)
                        }
                        // The overview: pinned to the top as the windows scroll under it
                        // (pulled down past the top, it comes with them)
                        .offset(y: focused == nil ? max(0, -offset) : 0)
                }
            }
            .padding(.leading, fullscreen ? 0 : 10)
            .padding(.trailing, fullscreen ? 0 : (focused != nil ? Self.railColumn : 10))
            .frame(width: size.width, alignment: .top)
            .offset(y: offset)
            .frame(width: size.width, height: size.height, alignment: .top)
            // Typing: nothing shows below the key bar's top (the next window would show
            // through the glass)
            // Typing: whatever reaches the key bar (a window mid-swipe) fades out under it
            .mask(alignment: .top) {
                let typing = focused != nil && !fullscreen
                VStack(spacing: 0) {
                    Rectangle()
                        .frame(height: typing ? max(0, barTop(size) - 28) : size.height + 400)
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: typing ? 28 : 0)
                    Spacer(minLength: 0)
                }
                // Past the sides too: in landscape a menu's dimming reaches past the
                // safe area
                .frame(width: size.width + 400)
                .offset(y: typing ? 0 : -200)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(fullscreen ? nil : pager(count: ids.count, heights: laidOut, items: items, loose: loose, maxScroll: maxScroll))
            .overlay(alignment: .trailing) {
                if focused != nil && !fullscreen {
                    // A voice session: the window the agent is looking at has its eyes
                    StatusRail(statuses: items.map { attentionStatus($0.session) }, webSlots: loose.count,
                               current: current, looking: voiceWindow(items)) { target in
                        // On the buttons, no window is lit
                        scrubbing = target >= 0
                        jump(to: target, count: ids.count)
                    } onScrubEnd: { target in
                        scrubbing = false
                        // Its top: the overview, with the buttons pinned
                        if target < 0 { return toOverview() }
                        commitFocus(target, items: items, loose: loose)
                    }
                    .frame(width: Self.railColumn)
                    // Centered beside the focused window, in the room above the key bar
                    .frame(height: barTop(size), alignment: .center)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: edgeOnLeft ? .leading : .trailing) {
                if fullscreen {
                    EdgeDots(statuses: items.map { attentionStatus($0.session) },
                             current: items.firstIndex { $0.id == focused },
                             isOut: edgeOut, onLeft: edgeOnLeft) { held in
                        edgeHeld = held
                    } onSelect: { target in
                        hideEdge()
                        if items[target].id != focused { commitFocus(target, items: items, loose: loose) }
                    }
                    // Where the rail is outside fullscreen
                    .frame(height: barTop(size), alignment: .center)
                    .frame(maxHeight: .infinity, alignment: .top)
                    // On the screen's edge, past the safe area in landscape
                    .offset(x: edgeOnLeft ? -geo.safeAreaInsets.leading : geo.safeAreaInsets.trailing)
                }
            }
            // Fullscreen, another window finished or needs you: out of the edge
            .onChange(of: Dictionary(uniqueKeysWithValues: items.map { ($0.id, attentionStatus($0.session)) })) { old, new in
                guard fullscreen else { return }
                let news = new.filter { id, status in
                    id != focused && (status == .done || status == .blocked) && old[id] != nil && old[id] != status
                }
                if !news.isEmpty { showEdge(news.values.contains(.blocked) ? .agentNeedsYou : .agentFinished) }
            }
            .onChange(of: fullscreen) { _, on in
                if !on {
                    hideEdge()
                    landscapeFull = false
                    // A selection made fullscreen: its handles can't be dragged in a window
                    for session in sessionManager.sessions { session.clearSelection?() }
                }
            }
            // Typing in landscape is fullscreen; back in portrait, the window
            .onChange(of: size.width > size.height) { _, wide in
                landscape = wide
                if wide, focused != nil, !fullscreen {
                    landscapeFull = true
                    setFullscreen(true)
                } else if !wide, landscapeFull {
                    setFullscreen(false)
                }
            }
            .onChange(of: focused) { old, new in
                // The rail goes with the typing (a scrub it ended mid-way never finishes)
                if new == nil { scrubbing = false }
                if landscape, new != nil, !fullscreen {
                    landscapeFull = true
                    setFullscreen(true)
                }
                menuWindow = nil
                // Back to the overview: keep the window where it was on screen
                if new == nil, old != nil, tops.indices.contains(current) {
                    // The first: at the top, its header in view
                    scrollOffset = current == 0 ? 0 : min(max(0, tops[current] - Self.peek), maxScroll)
                }
            }
            // A window closed: the overview stays within its ends
            .onChange(of: maxScroll) { _, limit in
                if moving != nil { moveMaxScroll = limit }
                if scrollOffset > limit { withAnimation(snap) { scrollOffset = limit } }
            }
            // Moving a window, the edges scroll the overview under it: it may pass another
            .onChange(of: scrollOffset) {
                if moving != nil { makeRoom(ids: ids, tops: tops, heights: laidOut) }
            }
            // A moved window let go: it stays where it is on screen as the windows grow back
            .onChange(of: moving) { old, new in
                guard new == nil, let old, let i = ids.firstIndex(of: old) else { return }
                withAnimation(snap) { scrollOffset = min(max(0, tops[i] - dropTop), maxScroll) }
            }
            // The window typed into closed: back to the overview (or, from a web tab, to
            // the terminal typed into before)
            .onChange(of: ids) { _, ids in
                if let menuWindow, !ids.contains(menuWindow) { self.menuWindow = nil }
                if let moving, !ids.contains(moving) { self.moving = nil }
                // A closed window's images go with it
                for window in sessionManager.imageWindows where !ids.contains(window) {
                    sessionManager.dropImages(window)
                }
                if let focused, !ids.contains(focused) {
                    if webReturn != nil { return exitWeb() }
                    withAnimation(snap) {
                        self.focused = nil
                        fullscreen = false
                    }
                }
            }
            // While typing, focus follows the tab shown: a new tab from the menu, or a pane
            // an agent opened with `rtach ws`
            // A new web tab (`clauntty tab`, which opens it in the background): show it
            .onChange(of: webs.map(\.id)) { old, new in
                // A web tab closed: its window shows its terminal again (and a fullscreen
                // one comes back)
                for (window, web) in shownWeb where !new.contains(web) {
                    if fullscreen && focused == window { exitWeb() }
                    shownWeb[window] = nil
                }
                if let id = new.first(where: { !old.contains($0) }), let web = webs.first(where: { $0.id == id }) {
                    openWeb(web)
                }
            }
            .onChange(of: sessionManager.activeTab) { _, tab in
                // A web tab shown: fullscreen
                if case .web(let id) = tab, let web = webs.first(where: { $0.id == id }) {
                    return openWeb(web)
                }
                guard focused != nil, case .terminal(let sessionId) = tab,
                      let target = items.firstIndex(where: { $0.session.id == sessionId }) else { return }
                let session = items[target].session
                if items[target].id != focused {
                    withAnimation(snap) {
                        focused = items[target].id
                        index = target
                        drag = 0
                    }
                }
                // A new pane or tab is a new terminal view: give it the keyboard
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { session.showKeyboard?() }
            }
            .onReceive(cursorChanges(items.map(\.session))) { _ in cursorTick &+= 1 }
            .onAppear {
                originY = geo.frame(in: .global).minY
                landscape = size.width > size.height
            }
            .onChange(of: geo.frame(in: .global).minY) { _, y in originY = y }
        }
        .ignoresSafeArea(.keyboard)
        // Seen images go when the viewer closes (after it zooms back into the thumbnail);
        // the viewer's Save keeps one in Photos
        .fullScreenCover(item: $openImages, onDismiss: {
            if let window = viewedImages {
                viewedImages = nil
                clearImages(window)
            }
        }) { open in
            ImageViewerView(content: Binding(
                get: { sessionManager.windowImages[open.id] },
                set: { if $0 == nil { openImages = nil } }
            ))
            // From the thumbnail, which is tagged with the images' id
            .modifier(ZoomFrom(id: sessionManager.windowImages[open.id]?.id ?? open.id, namespace: imagesZoom))
        }
        .onChange(of: openImages?.id) { _, window in
            if let window { viewedImages = window }
        }
        // A notification for a window's images was tapped
        .onChange(of: sessionManager.openImagesWindow) { _, window in
            guard let window else { return }
            sessionManager.openImagesWindow = nil
            if sessionManager.windowImages[window] != nil { openImages = OpenImages(id: window) }
        }
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
        // Light or dark as the terminal's theme is, so the text, the glass and the keyboard
        // read on it
        .preferredColorScheme(isLightTheme ? .light : .dark)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            // How far the keyboard reaches up from the bottom of the screen
            let height = UIScreen.main.bounds.height - frame.minY
            guard height > 100 else { return }
            keyboardShows &+= 1
            // With the keyboard, so the window follows the key bar up
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardHeight = height
                keyboardVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            // The keyboard collapsed: the window stays, down to the key bar (the
            // rail's buttons go to the overview). A moment later, and only if it stayed
            // down: bringing a hidden keyboard back hides and shows it in quick succession.
            let shows = keyboardShows
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard keyboardShows == shows else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    keyboardVisible = false
                }
            }
        }
        // Nothing claimed for commands yet (only the overview has been up), a review's
        // live notice is dropped by rtach: look for waiting ones while the overview shows
        .task(id: focused == nil) {
            while focused == nil && !Task.isCancelled {
                if PlatformApp.isActive { sessionManager.checkReviewsOnHosts() }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    // MARK: Layout

    /// Each window's mode and height, from the same math the window crops with
    private func spec(for session: Session, tabId: UUID, index i: Int, size: CGSize) -> WindowSpec {
        _ = cursorTick
        let isFocused = focused == tabId
        let isFull = fullscreen && isFocused
        let info = sessionManager.panes(for: session)
        let status = info.flatMap { $0.panes.indices.contains($0.activeIndex) ? $0.panes[$0.activeIndex].status : nil } ?? .none
        let isAgent = session.pane.flatMap { sessionManager.paneStates[$0.paneId] }?.hasAgent ?? false
        // One size in every mode, so focusing or the keyboard never resizes the pane (and
        // Claude never redraws): windows only crop it
        // Fullscreen is the session view: like a tab, the terminal fits the screen below
        // the pill and above the keyboard (it reserves the key bar itself), so a TUI
        // shows top to bottom. That resizes it once, as switching tabs does.
        // (The keyboard is measured from the screen's bottom; the layout stops above the
        // home indicator.)
        let keyboardTop = UIScreen.main.bounds.height - originY - keyboardHeight
        // Typing into a window resizes its terminal to fill the window, so the whole screen
        // shows (a TUI too). Fullscreen fits the room above the keyboard. The overview
        // keeps every terminal at full height, cropped.
        let width = isFull ? size.width : size.width - 10 - (focused != nil ? Self.railColumn : 10)
        // Fullscreen with the keyboard up fills the room above it, resizing as it zooms (its
        // lines reflow mid-animation). Keeping the focused window's size made it a clean
        // zoom but left empty rows above the key bar.
        let focusedWidth = size.width - 10 - Self.railColumn
        let focusedContent = barTop(size) - Self.peek - 10 - Self.pillStrip - SwitcherWindow.bottomPad
        let focusedHeight = focusedContent / (focusedWidth / size.width) + SwitcherWindow.keyBarReserve
        let terminalSize: CGSize = {
            if isFull {
                // Landscape: the whole height (the pill floats over it), down to the
                // keyboard when it's up
                if landscape, webShown(in: tabId) == nil {
                    return CGSize(width: size.width, height: keyboardVisible ? keyboardTop : size.height)
                }
                if !keyboardVisible { return CGSize(width: size.width, height: size.height - Self.pillStrip) }
                return CGSize(width: size.width, height: keyboardTop - Self.pillStrip)
            }
            if isFocused { return CGSize(width: size.width, height: focusedHeight) }
            return CGSize(width: size.width, height: size.height - Self.pillStrip)
        }()
        let mode: SwitcherWindow.Mode = {
            if isFull {
                // Down to the key bar: above the keyboard when it's up
                return .fullscreen(height: size.height)
            }
            // Down to the key bar, below the window above's peek
            // From where it settles (the first window has nothing above to peek) down to
            // the key bar, so nothing is left to show between them
            if isFocused { return .focused(maxHeight: max(160, barTop(size) - Self.anchor(for: i) - 10)) }
            return .collapsed
        }()
        let height = SwitcherWindow.height(cursor: session.cursorRow, mode: mode, isAgent: isAgent,
                                           terminalSize: terminalSize, windowWidth: width)
        return WindowSpec(mode: mode, isAgent: isAgent, status: status, terminalSize: terminalSize, width: width, height: height)
    }

    /// Where a focused window settles: below the window above's peek (the first, below
    /// the status line), so every focused window, and its terminal, has one size
    static func anchor(for index: Int) -> CGFloat { peek }

    /// Where the key bar starts: above the keyboard, or at the bottom with it collapsed
    private func barTop(_ size: CGSize) -> CGFloat {
        let screen = UIScreen.main.bounds.height - originY
        return keyboardVisible ? screen - keyboardHeight - Self.keyBarAboveKeyboard : screen - Self.collapsedBar
    }

    /// The collapsed key bar at the bottom of the screen, home indicator included
    static var collapsedBar: CGFloat { 104 - keyBarSaving }

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

    /// Overview: scrolls freely with momentum. Typing: a quick swipe moves one window
    /// to the next, the keyboard going with it; a slower drag scrolls the
    /// window's terminal, as in a tab.
    private func pager(count: Int, heights: [CGFloat], items: [(id: UUID, session: Session)], loose: [WebTab],
                       maxScroll: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Holding a pill: the finger is choosing from its menu. Holding a window:
                // moving it.
                guard menuWindow == nil, moving == nil else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if focused == nil {
                    guard abs(dy) > abs(dx) else { return }
                    drag = dy
                    return
                }
                if dragMode == nil {
                    guard abs(dy) > abs(dx) else { return }
                    // By how fast it starts
                    let quick = abs(value.velocity.height) > Self.flickSpeed
                    dragMode = quick ? .page : .scroll
                    scrolledY = 0
                    dragStart = value.time
                    peakSpeed = 0
                    holdScroll = dragMode == .scroll && focusedTakesMouse(items: items, loose: loose)
                    if dragMode == .scroll && !holdScroll { scrollFocused(nil, items: items, loose: loose) }
                }
                switch dragMode {
                case .scroll:
                    peakSpeed = max(peakSpeed, abs(value.velocity.height))
                    if holdScroll {
                        guard value.time.timeIntervalSince(dragStart) >= Self.flickTime else { break }
                        holdScroll = false
                        scrollFocused(nil, items: items, loose: loose)
                    }
                    scrollFocused(dy - scrolledY, items: items, loose: loose)
                    scrolledY = dy
                default:
                    let atEdge = (index == 0 && dy > 0) || (index >= count - 1 && dy < 0)
                    drag = atEdge ? dy * 0.3 : dy
                }
            }
            .onEnded { value in
                let dy = value.translation.height
                let projected = value.predictedEndTranslation.height
                let mode = dragMode
                dragMode = nil
                guard menuWindow == nil, moving == nil else { return }
                if focused != nil && mode == .scroll {
                    let duration = value.time.timeIntervalSince(dragStart)
                    let average = abs(dy) / max(0.05, duration)
                    let peak = max(peakSpeed, abs(value.velocity.height))
                    let flick = duration < Self.flickTime && (peak > Self.flickPeakSpeed || average > Self.flickAverageSpeed)
                    let held = holdScroll
                    holdScroll = false
                    guard flick else {
                        // A short slow drag over a TUI: its scroll, now
                        if held {
                            scrollFocused(nil, items: items, loose: loose)
                            scrollFocused(dy, items: items, loose: loose)
                        }
                        return
                    }
                    // A flick after all: put back what it scrolled, then page its way
                    scrollFocused(-scrolledY, items: items, loose: loose)
                    let current = min(index, count - 1)
                    // Down from the first: the overview, the header's above it
                    if current == 0 && dy > 0 { return toOverview() }
                    let target = min(max(0, current + (dy < 0 ? 1 : -1)), count - 1)
                    if target != current { commitFocus(target, items: items, loose: loose) }
                    return
                }
                if focused != nil && mode == nil {
                    // A tap-like drag that never chose doesn't page
                    withAnimation(snap) { drag = 0 }
                    return
                }
                if focused == nil {
                    // Carry on with the flick's momentum, then settle within the ends
                    let target = min(max(0, scrollOffset - projected), maxScroll)
                    withAnimation(.spring(response: 0.5, dampingFraction: 1)) {
                        scrollOffset = target
                        drag = 0
                    }
                    return
                }
                let current = min(index, count - 1)
                let threshold = min(120, (heights.indices.contains(current) ? heights[current] : 0) * 0.3)
                var target = current
                if dy < -threshold || projected < -200 { target = current + 1 }
                if dy > threshold || projected > 200 { target = current - 1 }
                if target < 0 {
                    drag = 0
                    return toOverview()
                }
                target = min(max(0, target), count - 1)
                if target == current {
                    withAnimation(snap) { drag = 0 }
                    return
                }
                commitFocus(target, items: items, loose: loose)
            }
    }

    /// Type into the window at `target`. A window showing a page, or a web tab's own
    /// window, puts the keyboard away instead.
    private func commitFocus(_ target: Int, items: [(id: UUID, session: Session)], loose: [WebTab]) {
        if target >= items.count, loose.indices.contains(target - items.count) {
            Haptic.navigate.play()
            withAnimation(snap) {
                focused = loose[target - items.count].id
                index = target
                drag = 0
            }
            hideKeyboard()
            return
        }
        guard items.indices.contains(target) else { return }
        let id = items[target].id
        Haptic.navigate.play()
        withAnimation(snap) {
            focused = id
            index = target
            drag = 0
        }
        sessionManager.switchTo(items[target].session)
        let session = items[target].session
        if webShown(in: id) != nil {
            hideKeyboard()
        } else {
            DispatchQueue.main.async { session.showKeyboard?() }
        }
    }

    /// Scroll the typed-into window under a slow drag: its terminal, as a one-finger drag
    /// in a tab would, or the page it shows. nil starts the drag.
    private func scrollFocused(_ dy: CGFloat?, items: [(id: UUID, session: Session)], loose: [WebTab]) {
        guard let focused else { return }
        let page = webShown(in: focused) ?? loose.first { $0.id == focused }
        if let page {
            guard let dy, let scroll = page.webView?.scrollView else { return }
            let top = -scroll.adjustedContentInset.top
            let bottom = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let y = min(max(top, scroll.contentOffset.y - dy), bottom)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
            return
        }
        items.first { $0.id == focused }?.session.scrollTerminal?(dy)
    }

    /// The typed-into window shows a TUI that takes the mouse (scrolls are wheel events)
    private func focusedTakesMouse(items: [(id: UUID, session: Session)], loose: [WebTab]) -> Bool {
        guard let focused, webShown(in: focused) == nil, !loose.contains(where: { $0.id == focused }) else { return false }
        return items.first { $0.id == focused }?.session.terminalTakesMouse?() ?? false
    }

    /// The rail tapped or scrubbed: show that window (focus follows when the finger lifts)
    private func jump(to target: Int, count: Int) {
        guard target >= 0, target < count, target != index else { return }
        Haptic.scrub.play()
        withAnimation(snap) { index = target }
    }

    // MARK: Moving

    /// Windows move in the overview, one at a time
    private func canMove(_ id: UUID) -> Bool {
        focused == nil && !fullscreen && (menuWindow == nil || menuWindow == id) && (moving == nil || moving == id)
    }

    /// The moving window's top in the layout: under the finger
    private var movedTop: CGFloat { moveY - originY + scrollOffset - moveGrab }

    /// A window held in the overview lifts and follows the finger among `list` (the
    /// terminals, or the web tabs of their own). `ids`, `tops` and `heights` are the layout.
    private func move(_ id: UUID, _ phase: WindowMove, among list: [UUID], ids: [UUID], tops: [CGFloat],
                      heights: [CGFloat], maxScroll: CGFloat) {
        switch phase {
        case .lift:
            guard canMove(id), moving == nil, let i = ids.firstIndex(of: id) else { return }
            // Its menu, open from the hold, goes as it moves
            if menuWindow == id { setMenu(nil) }
            Haptic.lift.play()
            // It stays where it is until the finger moves
            moveGrab = 0
            moveY = originY + tops[i] - scrollOffset
            moveGrabbed = false
            moveList = list
            moveMaxScroll = maxScroll
            withAnimation(snap) { moving = id }
            scrollAtEdges()
        case .drag(let y):
            guard moving == id, let i = ids.firstIndex(of: id) else { return }
            if !moveGrabbed {
                // Shrunk, the window stays under the finger: where it holds it, or its
                // bottom
                moveGrabbed = true
                moveGrab = min(max(16, y - (moveY - moveGrab)), heights[i] - 16)
            }
            moveY = y
            makeRoom(ids: ids, tops: tops, heights: heights)
        case .drop:
            guard moving == id, let i = ids.firstIndex(of: id) else { return }
            Haptic.navigate.play()
            dropTop = tops[i] - scrollOffset
            // After the other gestures the finger ends: lifting it isn't a swipe or a scroll
            DispatchQueue.main.async { withAnimation(snap) { moving = nil } }
        }
    }

    /// The moving window's middle passed the middle of the window above or below: they
    /// swap
    private func makeRoom(ids: [UUID], tops: [CGFloat], heights: [CGFloat]) {
        guard let moving, let i = ids.firstIndex(of: moving), tops.count == ids.count else { return }
        let middle = movedTop + heights[i] / 2
        let other: UUID? = {
            if i + 1 < ids.count, moveList.contains(ids[i + 1]), middle > tops[i + 1] + heights[i + 1] / 2 { return ids[i + 1] }
            if i > 0, moveList.contains(ids[i - 1]), middle < tops[i - 1] + heights[i - 1] / 2 { return ids[i - 1] }
            return nil
        }()
        guard let other else { return }
        Haptic.scrub.play()
        withAnimation(snap) { sessionManager.moveTab(id: moving, to: other) }
    }

    /// While a window moves, a finger near the top or bottom scrolls the overview, faster
    /// the closer it is
    private func scrollAtEdges() {
        Task { @MainActor in
            let zone: CGFloat = 70
            while moving != nil {
                try? await Task.sleep(for: .milliseconds(16))
                let y = moveY - originY
                let bottom = UIScreen.main.bounds.height - originY - Self.collapsedBar
                let step: CGFloat = y < zone ? -(zone - y) / zone * 14
                    : y > bottom - zone ? (y - bottom + zone) / zone * 14 : 0
                let next = min(max(0, scrollOffset + step), moveMaxScroll)
                if next != scrollOffset { scrollOffset = next }
            }
        }
    }

    // MARK: Windows

    /// Terminal tabs, in tab order: windows stay where they are whatever their agents do
    private var windows: [TabItem] { terminalTabs }

    private var terminalTabs: [TabItem] {
        sessionManager.orderedTabs().filter {
            if case .terminal = $0 { return true }
            return false
        }
    }

    /// Web tabs in tab order, after the terminals
    private var webTabs: [WebTab] {
        sessionManager.orderedTabs().compactMap {
            if case .web(let web) = $0 { return web }
            return nil
        }
    }

    /// A web window not typed into: a card, as a terminal's
    static func webHeight(width: CGFloat, size: CGSize) -> CGFloat { SwitcherWindow.cardHeight }

    /// A page's window while one is moved: a card too
    static func movingHeight(width: CGFloat, size: CGSize) -> CGFloat { SwitcherWindow.cardHeight }

    /// A page's size: the screen below the pill, in every mode (so fullscreen is a zoom)
    static func webSize(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: size.height - pillStrip)
    }

    /// A workspace's web tabs, its last panes
    private func webPanes(of windowId: UUID) -> [WebTab] {
        webTabs.filter { $0.workspaceId == windowId }
    }

    /// The web tab a window shows instead of its terminal
    private func webShown(in windowId: UUID) -> WebTab? {
        guard let id = shownWeb[windowId] else { return nil }
        return webPanes(of: windowId).first { $0.id == id }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// The most pressing state among a workspace's panes
    private func attentionStatus(_ session: Session) -> PaneStatus {
        let statuses = sessionManager.panes(for: session)?.panes.map(\.status) ?? []
        for s in [PaneStatus.blocked, .done, .working, .idle] where statuses.contains(s) { return s }
        return .none
    }

    private func window(for session: Session, tabId: UUID, index i: Int, spec: WindowSpec, size: CGSize,
                        menuRoom: CGFloat, menuAbove: CGFloat, onMove: @escaping (WindowMove) -> Void) -> some View {
        let info = sessionManager.panes(for: session)
        let panes = info?.panes ?? []
        let activeIndex = info?.activeIndex ?? 0
        let webPanes = webPanes(of: tabId)
        let web = webShown(in: tabId)
        let paneSessions = session.groupId.map { group in sessionManager.sessions.filter { $0.groupId == group } } ?? [session]
        return SwitcherWindow(
            session: session,
            paneSessions: paneSessions,
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
            floatsPill: fullscreen && landscape && focused == tabId && web == nil,
            web: web,
            webPanes: webPanes.count,
            activeWeb: web.flatMap { web in webPanes.firstIndex { $0.id == web.id } },
            webSize: Self.webSize(size),
            menu: menuWindow == tabId ? windowMenu(for: session, tabId: tabId, panes: panes, activeIndex: activeIndex) : nil,
            isMenuOpen: menuWindow == tabId,
            menuRoom: menuRoom,
            menuAbove: menuAbove,
            onMenu: { open in
                setMenu(open ? tabId : nil)
                if open { Task { await sessionManager.refreshWorkspaces(for: session.connectionConfig) } }
            },
            onTap: { tapped(tabId, index: i, session: session) },
            onSwipe: { step in swipe(tabId, session: session, step: step) },
            onFullscreen: {
                // A page opened from elsewhere goes back there; one swiped to in this
                // window stays in it
                if let web, !fullscreen { openWeb(web) } else if web != nil, webReturn != nil { exitWeb() } else { setFullscreen(!fullscreen) }
            },
            canMove: canMove(tabId),
            onMove: onMove,
            images: sessionManager.windowImages[tabId],
            imagesZoom: imagesZoom,
            onImages: { openImages = OpenImages(id: tabId) },
            onClearImages: { clearImages(tabId) },
            reviews: session.groupId.map { sessionManager.reviews(in: $0) } ?? [],
            onReview: { sessionManager.openReview($0) },
            voice: voiceLooks(at: paneSessions) ? voice.phase : nil,
            isScrubbed: scrubbing && index == i,
            isOverview: focused == nil
        )
    }

    /// The voice agent is looking at one of these panes
    private func voiceLooks(at sessions: [Session]) -> Bool {
        guard voice.isActive, let id = voice.lookingAt else { return false }
        return sessions.contains { $0.id == id }
    }

    /// The window the voice agent is looking at, by its place
    private func voiceWindow(_ items: [(id: UUID, session: Session)]) -> Int? {
        guard voice.isActive, let id = voice.lookingAt,
              let looked = sessionManager.sessions.first(where: { $0.id == id }) else { return nil }
        return items.firstIndex { $0.session.id == id || (looked.groupId != nil && $0.session.groupId == looked.groupId) }
    }

    /// Clear a window's images: swiped away from its corner, or seen in the viewer
    private func clearImages(_ windowId: UUID) {
        if openImages?.id == windowId { openImages = nil }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { sessionManager.windowImages[windowId] = nil }
    }

    // MARK: Actions

    /// Tap a window to type into it (the focused one's pill opens its menu instead). A
    /// window showing a page opens it fullscreen.
    private func tapped(_ tabId: UUID, index i: Int, session: Session) {
        if fullscreen { return }
        if let web = webShown(in: tabId) { return openWeb(web) }
        if focused == tabId { return }
        withAnimation(snap) {
            focused = tabId
            index = i
            drag = 0
        }
        sessionManager.switchTo(session)
        // Typing into it: the keyboard comes up even if it was hidden with the key bar
        DispatchQueue.main.async { session.showKeyboard?() }
    }

    /// Show a web tab fullscreen: in its workspace's window, or its own. Remembers the
    /// terminal typed into, to come back to.
    private func openWeb(_ web: WebTab) {
        let owner = web.workspaceId.flatMap { id in terminalTabs.contains { $0.id == id } ? id : nil }
        let window = owner ?? web.id
        let showing = fullscreen && focused == window && (owner == nil || shownWeb[window] == web.id)
        if !showing {
            // Typing into a terminal: come back to it
            if let focused, terminalTabs.contains(where: { $0.id == focused }), webShown(in: focused) == nil {
                webReturn = focused
            }
            Haptic.navigate.play()
            withAnimation(.spring(duration: 0.42, bounce: 0.1)) {
                if let owner { shownWeb[owner] = web.id }
                focused = window
                fullscreen = true
                drag = 0
            }
        }
        if sessionManager.activeTab != .web(web.id) {
            sessionManager.switchTo(web)
        }
    }

    /// Leave a fullscreen web tab: back to the terminal typed into before (its terminal
    /// pane, keyboard up), or to the overview
    private func exitWeb() {
        let terminals = windows
        let back = webReturn.flatMap { id in terminals.firstIndex { $0.id == id } }
        webReturn = nil
        withAnimation(.spring(duration: 0.42, bounce: 0.1)) {
            fullscreen = false
            if let back {
                shownWeb[terminals[back].id] = nil
                focused = terminals[back].id
                index = back
            } else {
                focused = nil
            }
        }
        if let back, case .terminal(let session) = terminals[back] {
            sessionManager.switchTo(session)
            DispatchQueue.main.async { session.showKeyboard?() }
        }
    }

    /// A page's actions in its pill's menu: navigation, and close
    private func webActions(_ web: WebTab) -> [WindowMenu.Item] {
        [
            .init(id: "back", title: "Back", icon: "chevron.backward", isDisabled: !web.canGoBack) { web.goBack() },
            .init(id: "forward", title: "Forward", icon: "chevron.forward", isDisabled: !web.canGoForward) { web.goForward() },
            .init(id: "reload", title: "Reload", icon: "arrow.clockwise") { web.reload() },
            .init(id: "close", title: "Close", icon: "xmark", isDestructive: true) { sessionManager.closeWebTab(web) },
        ]
    }

    /// Open a window's pill menu (nil closes it)
    private func setMenu(_ windowId: UUID?) {
        if windowId == nil { closingMenu = menuWindow }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            menuWindow = windowId
        } completion: {
            if menuWindow == nil { closingMenu = nil }
        }
    }

    /// The window drawn over the others, unclipped: its menu is open or closing
    private var menuLifted: UUID? { menuWindow ?? closingMenu }

    /// How far a window's open menu can reach down from its top: to the key bar while
    /// typing (fullscreen, while the keyboard's up), else the screen's bottom
    /// The overview: how far a card's menu can reach up from its top, below the header
    private func menuAbove(top: CGFloat) -> CGFloat {
        top - Self.topPad - Self.headerHeight
    }

    private func menuRoom(top: CGFloat, size: CGSize) -> CGFloat {
        let bottom: CGFloat = {
            guard focused != nil else { return size.height - 12 }
            if !fullscreen { return barTop(size) - 28 }
            return keyboardVisible ? barTop(size) - 8 : size.height - 12
        }()
        return bottom - top
    }

    private func setFullscreen(_ on: Bool) {
        // Landscape has no room to type into a window: out of fullscreen is the overview
        let toOverview = !on && landscape
        withAnimation(.spring(duration: 0.42, bounce: 0.1)) {
            fullscreen = on
            if toOverview { focused = nil }
        }
        if toOverview { hideKeyboard() }
    }

    /// In landscape with the Dynamic Island on the right, the edge's dots come out of the
    /// left
    private var edgeOnLeft: Bool {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation == .landscapeLeft
    }

    /// The edge's dots out, with `haptic`, then back in after `edgeTime` (once let go)
    private func showEdge(_ haptic: Haptic) {
        haptic.play()
        edgeShows &+= 1
        let shows = edgeShows
        withAnimation(.spring(duration: 0.45, bounce: 0.3)) { edgeOut = true }
        func later() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.edgeTime) {
                guard edgeShows == shows, edgeOut else { return }
                if edgeHeld { return later() }
                hideEdge()
            }
        }
        later()
    }

    private func hideEdge() {
        edgeHeld = false
        guard edgeOut else { return }
        withAnimation(.spring(duration: 0.35, bounce: 0)) { edgeOut = false }
    }

    /// Show the workspace's next or previous pane in this window: its terminals, then its
    /// web tabs
    private func swipe(_ windowId: UUID, session: Session, step: Int) {
        // The end of a move, not a swipe
        guard moving == nil else { return }
        let info = sessionManager.panes(for: session)
        let terminals = max(1, info?.panes.count ?? 0)
        let webs = webPanes(of: windowId)
        let shown = webShown(in: windowId).flatMap { web in webs.firstIndex { $0.id == web.id } }
        let position = shown.map { terminals + $0 } ?? (info?.activeIndex ?? 0)
        showPane(position + step, in: windowId, session: session)
    }

    /// Show one of the workspace's panes in its window, counting its terminals, then its
    /// web tabs
    private func showPane(_ target: Int, in windowId: UUID, session: Session) {
        let info = sessionManager.panes(for: session)
        let terminals = max(1, info?.panes.count ?? 0)
        let webs = webPanes(of: windowId)
        guard target >= 0, target < terminals + webs.count else { return }
        Haptic.navigate.play()
        if target >= terminals {
            withAnimation(snap) { shownWeb[windowId] = webs[target - terminals].id }
            if focused == windowId { hideKeyboard() }
            return
        }
        withAnimation(snap) { shownWeb[windowId] = nil }
        if let groupId = session.groupId, let info, info.panes.indices.contains(target), target != info.activeIndex {
            // The new pane is the active tab: focus follows with the keyboard
            sessionManager.selectPane(groupId: groupId, paneId: info.panes[target].id)
        } else if case .web = sessionManager.activeTab {
            // Back from a page made fullscreen, which made it the active tab: the terminal
            // is again, and the keyboard follows (`onChange(of: activeTab)`)
            sessionManager.switchTo(session)
        } else if focused == windowId {
            // Back from a page to the terminal it was over
            DispatchQueue.main.async { session.showKeyboard?() }
        }
    }

    // MARK: Header

    /// Settings and voice at the left, a new tab at the right, above the first window
    private var header: some View {
        HStack(spacing: 0) {
            HeaderPill(onSettings: onSettings, onVoice: onVoice)
            Spacer(minLength: 0)
            GlassCircle(systemName: "plus", size: 40, action: onNewTab)
                .accessibilityLabel("New Tab")
        }
        .frame(height: 40)
    }

    /// From typing to the overview, where the header is
    private func toOverview() {
        withAnimation(snap) { focused = nil }
        hideKeyboard()
    }

    /// A terminal window's pill menu: the session's actions (a page's, showing one), then
    /// its panes, one section per tab, its web tabs last
    private func windowMenu(for session: Session, tabId: UUID, panes: [TabPane], activeIndex: Int) -> WindowMenu {
        let workspace = panes.isEmpty ? nil : session.groupId
        let webs = webPanes(of: tabId)
        let shown = webShown(in: tabId)
        var actions: [WindowMenu.Item] = []
        if let shown {
            actions = webActions(shown)
        } else {
            if let workspace {
                actions.append(.init(id: "split", title: "New Pane", icon: "rectangle.split.2x1") {
                    Task { await sessionManager.performPaneAction(.split, groupId: workspace) }
                })
                actions.append(.init(id: "new", title: "New Tab", icon: "plus") {
                    Task { await sessionManager.performPaneAction(.newWorkspace, groupId: workspace) }
                })
            } else {
                actions.append(.init(id: "new", title: "New Tab", icon: "plus", perform: onNewTab))
            }
            actions.append(.init(id: "ports", title: "Ports", icon: "globe") { onPorts(session) })
            // Images closed in this window, to see again
            if sessionManager.recentImages[tabId] != nil {
                actions.append(.init(id: "images", title: "Images", icon: "photo.on.rectangle") {
                    sessionManager.reopenImages(tabId)
                    sessionManager.openImagesWindow = tabId
                })
            }
            actions.append(.init(id: "close", title: "Close", icon: "xmark", isDestructive: true) {
                // Ends the pane shown; its window goes (or shows the next pane) right away
                sessionManager.closeTab(session)
            })
        }
        let terminals = panes.isEmpty ? [TabPane(id: "session", title: session.title, status: .none, group: 0)] : panes
        var sections: [[WindowMenu.Item]] = []
        var start = 0
        for end in terminals.indices where end == terminals.count - 1 || terminals[end + 1].group != terminals[end].group {
            sections.append((start...end).map { index in
                let pane = terminals[index]
                return .init(id: "pane:\(pane.id)", title: pane.title,
                             subtitle: pane.status.label.isEmpty ? nil : pane.status.label,
                             icon: pane.status.symbolName, tint: Color(uiColor: pane.status.tint),
                             isOn: shown == nil && index == activeIndex) {
                    showPane(index, in: tabId, session: session)
                }
            })
            start = end + 1
        }
        if !webs.isEmpty {
            sections.append(webs.enumerated().map { i, web in
                // The title is the port until the page loads
                .init(id: "web:\(web.id)", title: web.title,
                      subtitle: web.pageTitle?.isEmpty == false ? ":\(String(web.remotePort.port))" : nil,
                      icon: "globe", isOn: shown?.id == web.id) {
                    showPane(terminals.count + i, in: tabId, session: session)
                }
            })
        }
        return WindowMenu(caption: shown?.urlDisplayString, actions: actions, sections: sections)
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
    /// Every session of the workspace's panes shown this run, the current one included:
    /// each keeps its terminal (hidden and paused when not shown), so swiping back to a
    /// pane finds its screen and history as they were
    let paneSessions: [Session]
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
    /// Fullscreen in landscape: the terminal has the whole height, the pill and the
    /// button float over its top right
    var floatsPill = false
    /// The web tab shown instead of the terminal (swiped to: the workspace's last panes)
    let web: WebTab?
    /// How many web tabs the workspace has, after its terminal panes
    let webPanes: Int
    let activeWeb: Int?
    /// The page's size (it keeps one, so fullscreen is a zoom)
    let webSize: CGSize
    /// The pill's menu, while it's open: the session's (or the page's) actions and panes
    let menu: WindowMenu?
    let isMenuOpen: Bool
    /// How far the menu can reach down from the window's top
    let menuRoom: CGFloat
    /// And up from it: a card's, in the overview
    var menuAbove: CGFloat = 0
    let onMenu: (Bool) -> Void
    let onTap: () -> Void
    let onSwipe: (Int) -> Void
    let onFullscreen: () -> Void
    /// In the overview: held, its menu opens below it; dragged on, it moves
    let canMove: Bool
    let onMove: (WindowMove) -> Void
    /// Images `clauntty show` sent from this window's panes, in its corner
    let images: ImageViewerContent?
    let imagesZoom: Namespace.ID
    let onImages: () -> Void
    let onClearImages: () -> Void
    /// Reviews from its panes' agents not on screen: a tile opens the first
    let reviews: [Review]
    let onReview: (Review) -> Void
    /// The voice agent is looking here, and what it's doing: its eyes and border
    var voice: VoiceAgent.Phase? = nil
    /// The finger scrubbing the status rail is on this window: its border lit
    var isScrubbed = false
    /// Nothing typed into: every card's border is clear to see. Typing, the others' fade
    /// behind the one typed into.
    var isOverview = false

    enum Mode: Equatable {
        /// A card: the workspace's glyph, title and time, what it's doing and its panes.
        /// The terminal stays under it, live but hidden, so opening it is only a layout.
        case collapsed
        /// Typed into: as many lines as fit
        case focused(maxHeight: CGFloat)
        /// The session view
        case fullscreen(height: CGFloat)
    }

    @State private var pullDown: CGFloat = 0
    /// The finger down is a hold: on the phone a hold under a second or so ends as a tap
    /// too, which closed the menu it had just opened
    @State private var held = false
    @State private var menuOpenedAt = Date.distantPast

    static let bottomPad: CGFloat = 8
    /// A collapsed window: two lines, so many fit
    static let cardHeight: CGFloat = 62
    /// What the terminal keeps at its bottom for the key bar while the keyboard is up
    static var keyBarReserve: CGFloat { 74 - AgentSwitcherView.keyBarSaving }

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

    private var isCard: Bool { mode == .collapsed }

    /// A page's card, beneath its title: its port (when the title is the page's own) and
    /// the workspace it's in
    private func pageLine(_ web: WebTab, workspace: String) -> String {
        let port = web.pageTitle?.isEmpty == false ? ":\(String(web.remotePort.port))" : nil
        return [port, workspace].compactMap { $0 }.joined(separator: " · ")
    }

    /// The collapsed window, as the Mac's sidebar card: the glyph in the middle on the
    /// left; the title and its time; beneath, what it's doing (or where it is) and the
    /// pane dots. Showing a page: the page's title and port.
    private var card: some View {
        let group = sessionManager.sessionGroup(for: session)
        let titles = group?.sidebarTitles ?? (title: title, subtitle: nil)
        let lead = group?.leadPane
        let state = lead.flatMap { sessionManager.paneStates[$0.id] }
        // Connecting, the glyph spins and the line says what it always does; only an
        // error or an ended session takes the line
        let detail = (isConnecting ? nil : notice?.text)
            ?? session.notRespondingMessage?.title
            ?? (lead?.status ?? status).detail(state: state, title: titles.title, subtitle: titles.subtitle)
            ?? state?.place
        return HStack(spacing: 12) {
            ZStack {
                if let web {
                    WebGlyph(webTab: web)
                } else if voice != nil {
                    VoiceEyes(status: lead?.status ?? status, size: 12, gaze: CGSize(width: 0, height: 1))
                        .teleportingEyes()
                } else {
                    StatusGlyph(status: lead?.status ?? status, isConnecting: isConnecting)
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(web.map(\.title) ?? titles.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    // Its agent's title took the workspace's name: the name after it, as in
                    // the pill
                    if web == nil, let name = group?.nameAfterTitle {
                        Text(name)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    // Context, not a headline: small and quiet (a minute's tick)
                    if web == nil {
                        TimelineView(.everyMinute) { context in
                            Text(sessionManager.since(state: state, typedIn: panes.map(\.id))
                                .map { $0.shortAge(now: context.date) } ?? "")
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        .fixedSize()
                    }
                }
                HStack(spacing: 8) {
                    // A space at worst: every card the same height
                    Text(web.map { pageLine($0, workspace: titles.title) } ?? detail ?? " ")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if max(1, panes.count) + webPanes > 1 {
                        PaneDots(panes: panes, activeIndex: activeIndex, webPanes: webPanes, activeWeb: activeWeb)
                    }
                }
            }
        }
        .padding(.leading, 16)
        // Clear of the images' thumbnail and the review's tile
        .padding(.trailing, 16 + CGFloat(tiles) * (ImagesThumbnail.size + 8))
        .frame(width: windowWidth, height: Self.cardHeight)
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
            return (usable, 2, 17)
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
            // Not shown (the card covers it): where the focused crop will be
            return (isAgent ? agentBottom : promptLine, 2, cell)
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
        // Typing: exactly down to the key bar, the terminal's crop anchored at its bottom
        if case .focused(let maxHeight) = mode { return maxHeight }
        return cardHeight
    }

    var body: some View {
        let c = crop
        let height = windowHeight
        // Where the scaled terminal's top-left corner goes
        let placement: (scale: CGFloat, x: CGFloat, y: CGFloat) = {
            switch mode {
            case .fullscreen:
                return (1, 0, floatsPill ? 0 : AgentSwitcherView.pillStrip)
            case .focused:
                // The whole terminal (above the strip it keeps for the key bar), fit into
                // the window under the pill and centered
                let rows = terminalSize.height - Self.keyBarReserve
                let s = min(windowWidth / terminalSize.width,
                            (height - AgentSwitcherView.pillStrip - Self.bottomPad) / rows)
                return (s, (windowWidth - terminalSize.width * s) / 2, AgentSwitcherView.pillStrip)
            default:
                // The crop's bottom at the window's bottom pad, or right under the pill
                // when everything fits (a short session)
                return (scale, 0, min(height - Self.bottomPad - c.bottom * scale, AgentSwitcherView.pillStrip))
            }
        }()
        ZStack(alignment: .top) {
            // Clipped by UIKit: the terminal draws with Metal, which SwiftUI's clipping
            // doesn't reach
            ClipHost(passesTouches: !isFullscreen, contentSize: terminalSize, scale: placement.scale,
                     origin: CGPoint(x: placement.x, y: placement.y)) {
                // One list, so a pane's terminal keeps its identity as it's shown and hidden
                ZStack(alignment: .topLeading) {
                    ForEach(paneSessions.contains { $0.id == session.id } ? paneSessions : paneSessions + [session]) { pane in
                        let shown = pane.id == session.id
                        TerminalView(session: pane, isTabSelectorPresented: !shown || !isFocused, isVisible: shown)
                            .id(pane.id)
                            .frame(width: terminalSize.width, height: terminalSize.height)
                            .opacity(shown ? 1 : 0)
                            .allowsHitTesting(shown)
                    }
                }
                .environmentObject(ghosttyApp)
                .environmentObject(sessionManager)
                .environmentObject(appState)
            }
            // Showing a page, the terminal stays (live, keeping its place) under it; a card
            // keeps both under it
            .opacity(web == nil && !isCard ? 1 : 0)
            if let web {
                ClipHost(passesTouches: !isFullscreen, contentSize: webSize,
                         scale: isFullscreen ? 1 : windowWidth / webSize.width,
                         origin: CGPoint(x: 0, y: AgentSwitcherView.pillStrip)) {
                    WebTabView(webTab: web)
                        .id(web.id)
                        .frame(width: webSize.width, height: webSize.height)
                        .environmentObject(sessionManager)
                }
                .opacity(isCard ? 0 : 1)
                .transition(.opacity)
                .task(id: web.id) { await sessionManager.reconnectIfClosed(web) }
            }
            if web == nil, !isFullscreen, !isCard, let notice, let icon = notice.icon {
                // Covers the empty terminal (its own overlays are centered in the whole
                // terminal, cropped away here)
                HStack(spacing: 8) {
                    Image(systemName: icon).foregroundStyle(notice.tint)
                    Text(notice.text).foregroundStyle(.secondary)
                }
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, AgentSwitcherView.pillStrip)
                .background(background)
                .allowsHitTesting(false)
            }
            // Outside fullscreen touches pass through the terminal (in UIKit: SwiftUI's
            // allowsHitTesting, toggled on the view holding the keyboard, made it drop the
            // keyboard for a moment), so the overlay takes them and a swipe anywhere pages

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

            // Connecting, the terminal stays: a note at the bottom says so
            if web == nil, !isCard, isConnecting, let notice {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.secondary)
                    Text(notice.text).foregroundStyle(.secondary)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glass(in: Capsule())
                .padding(.bottom, isFullscreen ? AgentSwitcherView.barReserve + 8 : 16)
                // Fullscreen, the window goes on under the keyboard: above the terminal's end
                .frame(height: isFullscreen ? placement.y + terminalSize.height : height, alignment: .bottom)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // The program isn't drawing, so the terminal is blank: say why, and that it's on
            // the host, in the same place
            if web == nil, !isCard, notice == nil, let stuck = session.notRespondingMessage {
                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(stuck.title)
                    }
                    .font(.system(size: 13, weight: .medium))
                    Text(stuck.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, isFullscreen ? AgentSwitcherView.barReserve + 8 : 16)
                .frame(height: isFullscreen ? placement.y + terminalSize.height : height, alignment: .bottom)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // Always there, so opening fades it out with the window's growth
            card
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(isCard ? 1 : 0)
                .allowsHitTesting(false)

            if !isFullscreen {
                // Taps and sideways swipes go to the window, not the terminal; vertical
                // drags page the switcher
                Color.clear
                    .contentShape(Rectangle())
                    // Typing into it, a tap goes to the terminal as in a tab: a click for a
                    // TUI, else paste (a page goes fullscreen)
                    .onTapGesture { location in
                        guard !held else { return }
                        // The card's menu open: the tap that ends the hold, or one to close it
                        if hasCardMenu, isMenuOpen {
                            if Date().timeIntervalSince(menuOpenedAt) > 1 { onMenu(false) }
                            return
                        }
                        guard isFocused, web == nil else { return onTap() }
                        session.tapTerminal?(terminalPoint(location, placement))
                    }
                    // Held: the menu with Paste, as in a tab
                    .gesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onChanged { value in
                                if case .second(true, _) = value { held = true }
                            }
                            .onEnded { value in
                                // Past the tap it can end as
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { held = false }
                                guard isFocused, web == nil, case .second(true, let drag?) = value else { return }
                                session.holdTerminal?(terminalPoint(drag.startLocation, placement))
                            },
                        including: isFocused && web == nil ? .all : .subviews
                    )
                    .simultaneousGesture(swipeGesture)
                    .modifier(MoveHold(isOn: canMove, onHold: { onMenu(true) }, onMove: onMove))
            }
        }
        .frame(width: windowWidth, height: windowHeight)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isFullscreen ? 0 : 22, style: .continuous)
                .strokeBorder(borderColor, lineWidth: status == .blocked || isFocused || isScrubbed ? 1.5 : 1)
                .animation(.easeInOut(duration: 0.5), value: voice != nil)
        )
        .overlay { CardEdge().opacity(hasCardEdge ? 1 : 0) }
        .overlay(alignment: .top) { header }
        .modifier(CardMenuHost(isOn: hasCardMenu && isMenuOpen, menu: menu, width: windowWidth, height: windowHeight,
                               room: menuRoom - windowHeight, above: menuAbove, onClose: { onMenu(false) }))
        .onChange(of: isMenuOpen) { _, open in if open { menuOpenedAt = Date() } }
        .offset(y: pullDown)
    }

    /// The overview's cards: held, their menu opens under them, as an app icon's
    private var hasCardMenu: Bool { isCard && isOverview }

    private var header: some View {
        // Top-aligned: the images' thumbnail is taller than the pill
        HStack(alignment: .top, spacing: 8) {
            // Floating, both at the right, the pill in the corner (its menu grows left)
            if floatsPill {
                Spacer(minLength: 0)
                thumbnail
                fullscreenButton
                pill
            } else {
                pill
                Spacer(minLength: 0)
                thumbnail
                fullscreenButton
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, isCard ? (Self.cardHeight - ImagesThumbnail.size) / 2 : 8)
        .frame(height: AgentSwitcherView.pillStrip, alignment: .top)
    }

    private var pill: some View {
        // Typing into it, the pill is the tab: a tap opens its menu. Any window's opens
        // when held.
        // On a card it's there to hold (its menu) but unseen until the menu opens
        PillMenu(isOpen: isMenuOpen && !hasCardMenu, menu: menu, tapOpens: isFocused, maxWidth: windowWidth - 16,
                 room: menuRoom - 8, trailing: floatsPill, hidesClosed: isCard, holds: !hasCardMenu,
                 onOpen: { onMenu(true) }, onClose: { onMenu(false) },
                 onTap: { if !isFullscreen { onTap() } }) {
            PanePill(title: title, workspace: workspace, status: status, panes: panes, activeIndex: activeIndex,
                     web: web, webPanes: webPanes, activeWeb: activeWeb, glass: false, eyes: voice != nil && !isCard)
                .opacity(isCard && !(isMenuOpen && !hasCardMenu) ? 0 : 1)
        }
        .gesture(isFullscreen ? pullGesture : nil)
        .simultaneousGesture(isFullscreen ? nil : swipeGesture)
        // An overview card's is unseen: a hold on it is the card's (long titles reach
        // across most of it)
        .allowsHitTesting(!hasCardMenu)
    }

    @ViewBuilder private var thumbnail: some View {
        if let review = reviews.first, !isMenuOpen {
            ReviewTile(count: reviews.count) { onReview(review) }
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
        if let images, !images.items.isEmpty, !isMenuOpen {
            ImagesThumbnail(content: images, zoom: imagesZoom, onOpen: onImages, onClear: onClearImages)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }

    /// The images' thumbnail and the review's tile, in the header's corner
    private var tiles: Int {
        (reviews.isEmpty ? 0 : 1) + (images?.items.isEmpty == false ? 1 : 0)
    }

    @ViewBuilder private var fullscreenButton: some View {
        if isFocused && !isMenuOpen {
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

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !isMenuOpen else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy), abs(dx) > 40 {
                    onSwipe(dx < 0 ? 1 : -1)
                }
            }
    }

    /// Fullscreen: drag the pill down to go back to the switcher, or sideways to switch
    /// panes
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isMenuOpen else { return }
                let sideways = abs(value.translation.width) > abs(value.translation.height)
                pullDown = sideways ? 0 : max(0, value.translation.height) * 0.6
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                withAnimation(.spring(duration: 0.35)) { pullDown = 0 }
                guard !isMenuOpen else { return }
                if abs(dx) > abs(dy) {
                    if abs(dx) > 40 { onSwipe(dx < 0 ? 1 : -1) }
                } else if dy > 80 {
                    onFullscreen()
                }
            }
    }

    /// A point in the window, in the terminal's points as it's placed
    private func terminalPoint(_ location: CGPoint, _ placement: (scale: CGFloat, x: CGFloat, y: CGFloat)) -> CGPoint {
        CGPoint(x: (location.x - placement.x) / placement.scale, y: (location.y - placement.y) / placement.scale)
    }

        /// Why the terminal has nothing to show yet, or no more
    private var notice: (icon: String?, tint: Color, text: String)? {
        switch session.state {
        case .error: return ("exclamationmark.triangle.fill", .red, "Couldn't connect")
        case .remotelyDeleted: return ("xmark.circle.fill", .orange, "Session ended")
        // An idle pane the app let go keeps its screen while it attaches again
        case .connecting: return session.isResting && session.hasOutput ? nil : (nil, .secondary, "Connecting")
        case .connected, .disconnected:
            if session.isResuming { return (nil, .secondary, "Resuming") }
            return session.hasOutput ? nil : (nil, .secondary, "Connecting")
        }
    }

    /// Connecting or resuming: the notices without an icon
    private var isConnecting: Bool { notice.map { $0.icon == nil } ?? false }

    private var borderColor: Color {
        if isFullscreen { return .clear }
        // Where the scrub would land, whiter than the window typed into
        if isScrubbed { return Color.primary.opacity(0.6) }
        if status == .blocked { return Color(uiColor: PaneStatus.blocked.tint).opacity(0.55) }
        // The voice agent's eyes are here: a little whiter
        if voice != nil { return Color.primary.opacity(isFocused ? 0.5 : 0.22) }
        // The overview's cards: their edge instead
        return Color.primary.opacity(isFocused ? 0.35 : isOverview ? 0 : 0.08)
    }

    /// The overview's lit edge: a card without a border of its own
    private var hasCardEdge: Bool {
        isOverview && !isFullscreen && !isScrubbed && status != .blocked && voice == nil
    }
}

// MARK: - Web window

/// A web tab: the live page under a pill (globe, page title, port), scaled into the window.
/// Tap it to go fullscreen; the page keeps one size, so that's a zoom.
struct WebWindow: View {
    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject var webTab: WebTab
    let isFullscreen: Bool
    /// Paged to while typing: the pill opens its menu
    let isFocused: Bool
    let background: Color
    /// The page's size: the screen below the pill
    let contentSize: CGSize
    let windowWidth: CGFloat
    let windowHeight: CGFloat
    /// The pill's menu, while it's open
    let menu: WindowMenu?
    let isMenuOpen: Bool
    let menuRoom: CGFloat
    var menuAbove: CGFloat = 0
    let onMenu: (Bool) -> Void
    let onOpen: () -> Void
    let onExit: () -> Void
    let canMove: Bool
    let onMove: (WindowMove) -> Void
    /// Nothing typed into: its border clear to see, as the cards'
    var isOverview = false

    @State private var pullDown: CGFloat = 0
    @State private var menuOpenedAt = Date.distantPast

    /// In the overview, held, its menu opens under it, as a terminal card's
    private var hasCardMenu: Bool { isOverview && !isFullscreen }

    var body: some View {
        ZStack(alignment: .top) {
            ClipHost(passesTouches: !isFullscreen, contentSize: contentSize,
                     scale: isFullscreen ? 1 : windowWidth / contentSize.width,
                     origin: CGPoint(x: 0, y: AgentSwitcherView.pillStrip)) {
                WebTabView(webTab: webTab)
                    .id(webTab.id)
                    .frame(width: contentSize.width, height: contentSize.height)
                    .environmentObject(sessionManager)
            }
            if !isFullscreen {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if hasCardMenu, isMenuOpen {
                            if Date().timeIntervalSince(menuOpenedAt) > 1 { onMenu(false) }
                            return
                        }
                        onOpen()
                    }
                    .modifier(MoveHold(isOn: canMove, onHold: { onMenu(true) }, onMove: onMove))
            }
        }
        .frame(width: windowWidth, height: windowHeight)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: isFullscreen ? 0 : 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isFullscreen ? 0 : 22, style: .continuous)
                .strokeBorder(isFullscreen ? Color.clear : Color.primary.opacity(isOverview ? 0 : 0.08), lineWidth: 1)
        )
        .overlay { CardEdge().opacity(isOverview ? 1 : 0) }
        .overlay(alignment: .top) { header }
        .modifier(CardMenuHost(isOn: hasCardMenu && isMenuOpen, menu: menu, width: windowWidth, height: windowHeight,
                               room: menuRoom - windowHeight, above: menuAbove, onClose: { onMenu(false) }))
        .onChange(of: isMenuOpen) { _, open in if open { menuOpenedAt = Date() } }
        .offset(y: pullDown)
        // A restored tab reconnects when it's shown (in tabs, when switched to): here
        // it's on screen
        .task(id: webTab.id) { await sessionManager.reconnectIfClosed(webTab) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            PillMenu(isOpen: isMenuOpen && !hasCardMenu, menu: menu, tapOpens: isFocused, maxWidth: windowWidth - 16,
                     room: menuRoom - 8, holds: !hasCardMenu,
                     onOpen: { onMenu(true) }, onClose: { onMenu(false) }, onTap: onOpen) {
                HStack(spacing: 7) {
                    WebPillLabel(webTab: webTab)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .gesture(isFullscreen ? pullGesture : nil)
            // In the overview a hold on it is the card's
            .allowsHitTesting(!hasCardMenu)
            Spacer(minLength: 0)
            if isFullscreen && !isMenuOpen {
                Button(action: onExit) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .glass(in: Circle())
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

    /// Drag the pill down to come back
    private var pullGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isMenuOpen else { return }
                pullDown = max(0, value.translation.height) * 0.6
            }
            .onEnded { value in
                let exit = !isMenuOpen && value.translation.height > 80
                withAnimation(.spring(duration: 0.35)) { pullDown = 0 }
                if exit { onExit() }
            }
    }
}

/// A review from one of the window's agents (`clauntty review`) that came while its pane
/// wasn't on screen, or was closed for now: tap to open it
private struct ReviewTile: View {
    let count: Int
    let onOpen: () -> Void

    var body: some View {
        Image(systemName: "text.bubble")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: ImagesThumbnail.size, height: ImagesThumbnail.size)
            .background(Color.black.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(.white))
                        .offset(x: 6, y: -6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityLabel(count == 1 ? "A review to read" : "\(count) reviews to read")
            .accessibilityAddTraits(.isButton)
    }
}

/// A window's images from `clauntty show`: the newest, with how many there are. Tap to
/// open them, swipe it sideways to clear them.
private struct ImagesThumbnail: View {
    let content: ImageViewerContent
    let zoom: Namespace.ID
    let onOpen: () -> Void
    let onClear: () -> Void

    @State private var slide: CGFloat = 0

    static let size: CGFloat = 44

    var body: some View {
        ZStack {
            if let image = content.items.last?.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.3), lineWidth: 1)
        )
        .modifier(ZoomSource(id: content.id, namespace: zoom))
        .overlay(alignment: .topTrailing) {
            if content.items.count > 1 {
                Text("\(content.items.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(.white))
                    .offset(x: 6, y: -6)
            }
        }
        .contentShape(Rectangle())
        .offset(x: slide)
        .opacity(1 - min(abs(slide) / 120, 0.8))
        .onTapGesture(perform: onOpen)
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    slide = value.translation.width
                }
                .onEnded { value in
                    if abs(value.translation.width) > 60 || abs(value.predictedEndTranslation.width) > 160 {
                        onClear()
                    } else {
                        withAnimation(.spring(duration: 0.3)) { slide = 0 }
                    }
                }
        )
    }
}

/// The viewer zooms out of a window's thumbnail and back into it (iOS 18)
private struct ZoomSource: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

private struct ZoomFrom: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}

/// A window held in the overview: lifted, moved by the finger, let go
enum WindowMove {
    /// Held long enough (where the finger is comes with the first drag)
    case lift
    /// The finger at `y` on screen
    case drag(y: CGFloat)
    case drop
}

/// Hold a window for its menu (`onHold`); drag on from there to move it. Reports where the
/// finger is on screen. (A drag tracking the finger from its touch, beside the hold, kept
/// the hold from ever starting.)
private struct MoveHold: ViewModifier {
    let isOn: Bool
    let onHold: () -> Void
    let onMove: (WindowMove) -> Void

    @State private var opened = false
    @State private var lifted = false
    /// Back to false when the finger lifts or the touch is cancelled
    @GestureState private var held = false

    /// How far the finger goes, held, before the window moves instead
    private static let slop: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .gesture(
                LongPressGesture(minimumDuration: 0.4)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .updating($held) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    }
                    .onChanged { value in
                        guard case .second(true, let drag) = value else { return }
                        if !opened {
                            opened = true
                            Haptic.lift.play()
                            onHold()
                        }
                        guard let drag else { return }
                        if !lifted {
                            guard hypot(drag.translation.width, drag.translation.height) > Self.slop else { return }
                            lifted = true
                            onMove(.lift)
                        }
                        onMove(.drag(y: drag.location.y))
                    },
                including: isOn ? .all : .subviews
            )
            .onChange(of: held) { _, held in
                guard !held else { return }
                opened = false
                guard lifted else { return }
                lifted = false
                onMove(.drop)
            }
    }
}

/// The moving window: over the others, a little bigger, following the finger
private struct Lifted: ViewModifier {
    let isOn: Bool
    let offset: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(isOn ? 1.03 : 1)
            .shadow(color: .black.opacity(isOn ? 0.5 : 0), radius: 18, y: 8)
            .offset(y: isOn ? offset : 0)
    }
}

/// Hosts SwiftUI content in a UIKit view that clips to its bounds, and can let touches
/// pass through it. The content keeps its own size; UIKit scales and places it, with the
/// switcher's animation: a hosting view centers content that doesn't fit it, so sizing
/// it to the window made the terminal jump while the window animated.
private struct ClipHost<Content: View>: UIViewRepresentable {
    var passesTouches = false
    let contentSize: CGSize
    let scale: CGFloat
    /// Where the scaled content's top-left corner goes
    let origin: CGPoint
    @ViewBuilder let content: () -> Content

    final class Container: UIView {
        var passesTouches = false
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            passesTouches ? nil : super.hitTest(point, with: event)
        }
    }

    func makeUIView(context: Context) -> Container {
        let container = Container()
        container.passesTouches = passesTouches
        container.clipsToBounds = true
        container.backgroundColor = .clear
        let host = UIHostingController(rootView: content())
        // Laid out by the switcher: no keyboard avoidance or safe area insets, which
        // would shift the terminal when the window reaches under the keyboard
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        // Placed by its top-left corner
        host.view.layer.anchorPoint = .zero
        host.view.bounds = CGRect(origin: .zero, size: contentSize)
        place(host.view)
        container.addSubview(host.view)
        context.coordinator.host = host
        return container
    }

    func updateUIView(_ uiView: Container, context: Context) {
        uiView.passesTouches = passesTouches
        guard let host = context.coordinator.host else { return }
        host.rootView = content()
        if host.view.bounds.size != contentSize {
            host.view.bounds = CGRect(origin: .zero, size: contentSize)
        }
        if #available(iOS 18.0, *), let animation = context.transaction.animation {
            UIView.animate(animation) { place(host.view) }
        } else {
            place(host.view)
        }
    }

    private func place(_ view: UIView) {
        view.center = origin
        view.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var host: UIHostingController<Content>?
    }
}

/// A page's glyph (loading, or a globe), its title, then its port (the title is the port
/// until the page loads)
private struct WebPillLabel: View {
    @ObservedObject var webTab: WebTab

    var body: some View {
        WebGlyph(webTab: webTab)
        Text(webTab.title)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
        if webTab.pageTitle?.isEmpty == false {
            Text(":\(String(webTab.remotePort.port))")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// The collapsed tab bubble: the pane's glyph and title, the workspace, the pane dots
/// (its web tabs last, as globes). Showing a web tab, the page's title.
private struct PanePill: View {
    let title: String
    let workspace: String
    let status: PaneStatus
    let panes: [TabPane]
    let activeIndex: Int
    var web: WebTab? = nil
    var webPanes = 0
    var activeWeb: Int? = nil
    /// Off when its menu draws the glass
    var glass = true
    /// The voice agent is looking here: its eyes in place of the glyph
    var eyes = false

    var body: some View {
        HStack(spacing: 7) {
            if let web {
                WebPillLabel(webTab: web)
            } else {
                // The eyes teleport here from the window they left
                ZStack {
                    if eyes {
                        VoiceEyes(status: status, size: 12, gaze: CGSize(width: 0, height: 1))
                            .teleportingEyes()
                    } else {
                        StatusGlyph(status: status)
                            .frame(width: 9, height: 9)
                            .transition(.opacity)
                    }
                }
                .animation(.easeIn(duration: 0.12), value: eyes)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if workspace != title {
                    Text(workspace)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if max(1, panes.count) + webPanes > 1 {
                PaneDots(panes: panes, activeIndex: activeIndex, webPanes: webPanes, activeWeb: activeWeb)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(PillGlass(isOn: glass))
    }
}

/// One dot per pane, the shown one a short capsule, others orange when they need you and
/// green when done; then, a little apart, a ring per page (the shown one wider), as on
/// the Mac
private struct PaneDots: View {
    let panes: [TabPane]
    let activeIndex: Int
    var webPanes = 0
    var activeWeb: Int? = nil

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 3) {
                ForEach(Array(panes.enumerated()), id: \.offset) { index, pane in
                    let active = activeWeb == nil && index == activeIndex
                    Capsule()
                        .fill(color(pane, active: active))
                        .frame(width: active ? 8 : 4, height: 4)
                }
                if panes.isEmpty {
                    Capsule()
                        .fill(Color.primary.opacity(activeWeb == nil ? 0.9 : 0.3))
                        .frame(width: activeWeb == nil ? 8 : 4, height: 4)
                }
            }
            if webPanes > 0 {
                HStack(spacing: 3) {
                    ForEach(0..<webPanes, id: \.self) { index in
                        let shown = activeWeb == index
                        Capsule()
                            .strokeBorder(Color.primary.opacity(shown ? 0.9 : 0.45), lineWidth: 1)
                            .frame(width: shown ? 9 : 5, height: 5)
                    }
                }
            }
        }
    }

    /// Like the tab bar: other panes that need you or finished show their color
    private func color(_ pane: TabPane, active: Bool) -> Color {
        if active { return Color.primary.opacity(0.9) }
        switch pane.status {
        case .blocked, .done: return Color(uiColor: pane.status.tint)
        default: return Color.primary.opacity(0.3)
        }
    }
}

/// A page's glyph: loading, or a globe
private struct WebGlyph: View {
    @ObservedObject var webTab: WebTab

    var body: some View {
        if webTab.isLoading {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// While typing: the header's buttons (the overview), then one dot per window, in order,
/// colored like the tab glyphs. Tap a dot to go there; drag along the rail to scrub. The
/// buttons' slot is -1, ringed while the finger's on it.
private struct StatusRail: View {
    let statuses: [PaneStatus]
    /// Web tabs with windows of their own, after the terminals
    var webSlots = 0
    let current: Int
    /// The window the voice agent is looking at: its eyes in place of the dot
    var looking: Int? = nil
    let onSelect: (Int) -> Void
    let onScrubEnd: (Int) -> Void

    /// The finger's on the buttons
    @State private var onTop = false

    private static let pitch: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if onTop {
                    Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                }
                Image(systemName: "ellipsis")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.6))
            }
            .frame(width: 24, height: Self.pitch)
            ForEach(Array(statuses.enumerated()), id: \.offset) { i, status in
                ZStack {
                    if i == current && !onTop {
                        Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                    }
                    if i == looking {
                        VoiceEyes(status: status, size: 8, gaze: CGSize(width: -1, height: 0))
                            .teleportingEyes()
                    }
                    Group {
                        if status == .none || status == .idle {
                            Circle().fill(Color.primary.opacity(0.35)).frame(width: 6, height: 6)
                        } else {
                            StatusGlyph(status: status).frame(width: 8, height: 8)
                        }
                    }
                    .opacity(i == looking ? 0 : 1)
                }
                .frame(width: 24, height: Self.pitch)
            }
            ForEach(0..<webSlots, id: \.self) { i in
                ZStack {
                    if current == statuses.count + i && !onTop {
                        Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5)
                            .frame(width: 14, height: 14)
                    }
                    Image(systemName: "globe")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.primary.opacity(0.6))
                }
                .frame(width: 24, height: Self.pitch)
            }
        }
        // The voice agent's eyes teleport from window to window
        .animation(.easeIn(duration: 0.12), value: looking)
        .padding(.vertical, 8)
        .glass(in: Capsule())
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let slot = slot(at: value.location.y)
                    if (slot < 0) != onTop {
                        if slot < 0 { Haptic.scrub.play() }
                        onTop = slot < 0
                    }
                    onSelect(slot)
                }
                .onEnded { value in
                    let slot = slot(at: value.location.y)
                    // On the buttons, the ring stays as the rail goes
                    if slot >= 0 { onTop = false }
                    onScrubEnd(slot)
                }
        )
    }

    private func slot(at y: CGFloat) -> Int {
        min(max(-1, Int(floor((y - 8) / Self.pitch)) - 1), statuses.count + webSlots - 1)
    }
}

/// Fullscreen: every window's dot, in order, on a black bump out of the screen's edge, as
/// the volume's comes out of the side. Out for a moment when another window finishes or
/// needs you. Tap a dot or slide to one to go there.
private struct EdgeDots: View {
    let statuses: [PaneStatus]
    let current: Int?
    let isOut: Bool
    /// Out of the left edge instead (mirrored)
    var onLeft = false
    let onHold: (Bool) -> Void
    let onSelect: (Int) -> Void

    /// The dot under the finger
    @State private var highlighted: Int?

    private static let reach: CGFloat = 10
    private static let pitch: CGFloat = 11
    /// The curve from the screen's edge out to the bump, at each end
    private static let neck: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(statuses.enumerated()), id: \.offset) { i, status in
                // Still dots: the window's color, the current one (or the one under the
                // finger) white
                Circle()
                    .fill(color(status, isCurrent: i == (highlighted ?? current)))
                    .frame(width: 5, height: 5)
                    .frame(width: Self.reach, height: Self.pitch)
            }
        }
        .padding(.vertical, 2)
        .opacity(isOut ? 1 : 0)
        .offset(x: isOut ? 0 : Self.reach)
        .padding(.vertical, Self.neck)
        .background {
            BezelBump(reach: isOut ? Self.reach : 0, neck: Self.neck).fill(Color.black)
        }
        .contentShape(Rectangle().inset(by: -8))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if highlighted == nil { onHold(true) }
                    let dot = slot(at: value.location.y)
                    if dot != highlighted {
                        if highlighted != nil { Haptic.scrub.play() }
                        highlighted = dot
                    }
                }
                .onEnded { value in
                    highlighted = nil
                    onHold(false)
                    onSelect(slot(at: value.location.y))
                }
        )
        .allowsHitTesting(isOut)
        .scaleEffect(x: onLeft ? -1 : 1)
    }

    private func color(_ status: PaneStatus, isCurrent: Bool) -> Color {
        if isCurrent { return .primary }
        switch status {
        case .blocked, .done, .working: return Color(uiColor: status.tint)
        default: return Color.primary.opacity(0.35)
        }
    }

    private func slot(at y: CGFloat) -> Int {
        min(max(0, Int((y - Self.neck - 2) / Self.pitch)), max(0, statuses.count - 1))
    }
}

/// Black out of the screen's right edge, `reach` wide, meeting the edge in a curve at
/// each end, so it reads as the phone's bezel bulging in
private struct BezelBump: Shape {
    var reach: CGFloat
    let neck: CGFloat

    var animatableData: CGFloat {
        get { reach }
        set { reach = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // In: nothing (not even the sliver past the edge, which shows inside a
        // landscape safe area)
        guard reach > 0.5 else { return path }
        let edge = rect.maxX
        let side = edge - reach
        // Past the edge a little, so nothing shows between it and the bezel
        path.move(to: CGPoint(x: edge + 2, y: rect.minY))
        path.addLine(to: CGPoint(x: edge, y: rect.minY))
        path.addCurve(to: CGPoint(x: side, y: rect.minY + neck),
                      control1: CGPoint(x: edge, y: rect.minY + neck * 0.6),
                      control2: CGPoint(x: side, y: rect.minY + neck * 0.35))
        path.addLine(to: CGPoint(x: side, y: rect.maxY - neck))
        path.addCurve(to: CGPoint(x: edge, y: rect.maxY),
                      control1: CGPoint(x: side, y: rect.maxY - neck * 0.35),
                      control2: CGPoint(x: edge, y: rect.maxY - neck * 0.6))
        path.addLine(to: CGPoint(x: edge + 2, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The tab bar's own animated glyph
private struct StatusGlyph: UIViewRepresentable {
    let status: PaneStatus
    var isConnecting = false

    func makeUIView(context: Context) -> PaneStatusIndicator { PaneStatusIndicator() }
    func updateUIView(_ view: PaneStatusIndicator, context: Context) {
        view.status = status
        view.isConnecting = isConnecting
    }
}

/// Settings and voice (during a session, its eyes: the conversation and End) in one pill:
/// the agent view's top, and the first screen's
struct HeaderPill: View {
    @ObservedObject private var voice = VoiceAgent.shared
    let onSettings: () -> Void
    let onVoice: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
            button(action: onVoice) {
                if voice.isActive {
                    VoiceEyes(status: voice.phase == .thinking || voice.phase == .connecting ? .working : .none,
                              size: 16, color: .primary, speaking: voice.phase == .speaking)
                } else {
                    Image(systemName: "waveform")
                }
            }
            .accessibilityLabel(voice.isActive ? "Voice session" : "Voice")
        }
        .padding(.horizontal, 4)
        .glass(in: Capsule())
    }

    private func button<Label: View>(action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct GlassCircle: View {
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

/// An overview card's edge, as the header's glass buttons have: a rim lit at the top and
/// bottom, and a soft glow inside it
struct CardEdge: View {
    var cornerRadius: CGFloat = 22

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.strokeBorder(Color.primary.opacity(0.05), lineWidth: 3)
                .blur(radius: 2.5)
                .clipShape(shape)
            shape.strokeBorder(
                LinearGradient(stops: [.init(color: .primary.opacity(0.24), location: 0),
                                       .init(color: .primary.opacity(0.1), location: 0.5),
                                       .init(color: .primary.opacity(0.18), location: 1)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// A window's bounds, or no clip while its menu reaches out of it. It doesn't animate: a
/// spring between the two overshot into the window, cutting off its edges.
private struct WindowClip: Shape {
    let isOff: Bool

    func path(in rect: CGRect) -> Path {
        Path(isOff ? rect.insetBy(dx: -4000, dy: -4000) : rect)
    }
}

private struct PillGlass: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn { content.glass(in: Capsule()) } else { content }
    }
}

extension UIColor {
    /// Behind the glass, which shows what's under it: the keyboard's grey, so the key bar
    /// sits on the keyboard as part of it, and the pills and buttons match it over any theme
    /// (clear, they took the theme's color). The agent view, and its keyboard, are light on
    /// a light theme and dark otherwise; the light keyboard is a little blue.
    static let glassBacking = UIColor { traits in
        traits.userInterfaceStyle == .light ? UIColor(red: 0.845, green: 0.85, blue: 0.875, alpha: 0.8) : UIColor(white: 0.11, alpha: 0.8)
    }

    /// The key bar's edge, crisp as the keyboard's (its backing covers the glass's own)
    static let glassRim = UIColor { traits in
        traits.userInterfaceStyle == .light ? UIColor(white: 0, alpha: 0.08) : UIColor(white: 1, alpha: 0.1)
    }

    /// Inside SwiftUI's glass, under what it holds: its color then doesn't depend on what's
    /// behind (the glass adapts to that, darker over white), only its edge is the glass's
    static let glassFill = UIColor { traits in
        traits.userInterfaceStyle == .light ? UIColor(red: 0.886, green: 0.89, blue: 0.91, alpha: 0.92) : UIColor(red: 0.133, green: 0.137, blue: 0.149, alpha: 0.92)
    }
}

extension View {
    /// Liquid glass where the system has it, a material otherwise, in the keyboard's grey
    @ViewBuilder
    func glass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.background(shape.fill(Color(uiColor: .glassFill)))
                .glassEffect(.regular, in: shape)
        } else {
            self.background(shape.fill(.ultraThinMaterial))
        }
    }
}
