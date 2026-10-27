import Foundation
import NIOCore
import NIOSSH
import os.log
import RtachClient

/// Represents a single terminal session (one tab)
/// Each session has its own SSH channel and terminal surface
@MainActor
class Session: ObservableObject, Identifiable {
    // MARK: - Identity

    let id: UUID
    var connectionConfig: SavedConnection
    let createdAt: Date

    /// Set for a session showing one pane of a SessionGroup. Every pane of the group
    /// shares this id, which is what the tab bar keys its one tab on.
    let groupId: UUID?

    /// The group pane this session shows
    var pane: PaneRef?

    // MARK: - State

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
        case remotelyDeleted  // Session was killed externally (shell exit, another client killed it)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.connecting, .connecting),
                 (.connected, .connected),
                 (.remotelyDeleted, .remotelyDeleted):
                return true
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    /// Callback invoked when state changes (for SessionManager to update UI)
    var onStateChange: (() -> Void)?

    @Published var state: State = .disconnected {
        didSet {
            onStateChange?()
        }
    }

    /// String description of state for hashing purposes
    var stateDescription: String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .error(let msg): return "error:\(msg)"
        case .remotelyDeleted: return "remotelyDeleted"
        }
    }

    /// Reason why the session was remotely deleted (for UI display)
    var remoteClosureReason: String?

    /// Font size for this session (nil = use global default)
    var fontSize: Float?

    /// Dynamic title set by terminal escape sequences (OSC 0/1/2)
    @Published var dynamicTitle: String? {
        didSet {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): dynamicTitle set to '\(self.dynamicTitle ?? "nil")'")

            // Persist the title for session restoration
            if let title = dynamicTitle, let sessionId = rtachSessionId {
                let key = Self.titleStorageKey(connectionId: connectionConfig.id, rtachSessionId: sessionId)
                UserDefaults.standard.set(title, forKey: key)

                // If this is a Claude session (has ✳️), remember that permanently
                if title.contains("\u{2733}") {
                    markAsClaudeSession()
                }
            }

            // Check for pending notification when title is set
            checkPendingNotification()
        }
    }

    /// Whether this session has ever been identified as Claude (persisted)
    private var _isClaudeSession: Bool = false

    /// Display title for tab - prefer dynamic title if set
    var title: String {
        // A group's tab is named after the group, whichever pane it shows
        if let label = pane?.groupTitle, !label.isEmpty {
            return label
        }
        if let dynamic = dynamicTitle, !dynamic.isEmpty {
            return dynamic
        }
        if !connectionConfig.name.isEmpty {
            return connectionConfig.name
        }
        return "\(connectionConfig.username)@\(connectionConfig.host)"
    }

    /// Connection string like "ubuntu@devbox.example.com" for expanded tab view
    var connectionString: String {
        "\(connectionConfig.username)@\(connectionConfig.host)"
    }

    /// Whether this appears to be a Claude Code session (detected by ✳️ in title)
    var isClaudeSession: Bool {
        // If we have a title, always check it directly (handles user exiting Claude)
        if let title = dynamicTitle {
            return title.contains("\u{2733}")  // ✳️ eight-spoked asterisk
        }
        // No title yet - use persisted flag (bridges gap during session restore)
        return _isClaudeSession
    }

    /// Whether we have a pending notification waiting for title to be set
    private var pendingNotificationCheck: Bool = false

    /// Mark this session as a Claude session (persisted)
    private func markAsClaudeSession() {
        guard !_isClaudeSession else { return }
        _isClaudeSession = true
        if let sessionId = rtachSessionId {
            let key = Self.claudeSessionKey(connectionId: connectionConfig.id, rtachSessionId: sessionId)
            UserDefaults.standard.set(true, forKey: key)
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): marked as Claude session")
        }
    }

    /// Restore Claude session flag from UserDefaults
    private func restoreClaudeSessionFlag(rtachSessionId: String) {
        let key = Self.claudeSessionKey(connectionId: connectionConfig.id, rtachSessionId: rtachSessionId)
        _isClaudeSession = UserDefaults.standard.bool(forKey: key)
        if _isClaudeSession {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): restored Claude session flag")
        }
    }

    /// Storage key for Claude session flag
    private static func claudeSessionKey(connectionId: UUID, rtachSessionId: String) -> String {
        return "session_claude_\(connectionId.uuidString)_\(rtachSessionId)"
    }

    /// Check if we should send a notification (called when title is set)
    /// Note: We don't check isWaitingForInput here because more data may have arrived
    /// after the inactivity timeout. The pending flag itself means we were waiting.
    private func checkPendingNotification() {
        guard pendingNotificationCheck else { return }

        pendingNotificationCheck = false
        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): checking pending notification, isClaudeSession=\(self.isClaudeSession)")

        #if os(iOS)
        if NotificationManager.shared.shouldNotify(for: self) {
            Task {
                await NotificationManager.shared.scheduleInputReady(session: self)
            }
        }
        #endif
    }

    // MARK: - Input Detection
    // When rtach is running (framed mode), idle detection is handled server-side.
    // rtach sends idle notifications after 2s of no PTY output.
    // Local timer-based detection is only used for non-rtach connections.

    /// Whether the terminal is waiting for user input
    /// Set by: rtach idle notification (framed mode) or local inactivity timer (raw mode)
    @Published private(set) var isWaitingForInput: Bool = false {
        didSet {
            onStateChange?()
        }
    }

    /// Timer for detecting inactivity after output stops (only used when rtach is not running)
    private var inactivityTimer: Timer?

    /// How long to wait after output stops before considering terminal idle (seconds)
    /// Only used for non-rtach connections; rtach uses 2s server-side threshold
    private let inactivityThreshold: TimeInterval = 1.5

    // MARK: - SSH Channel

    /// The SSH child channel for this session
    private(set) var sshChannel: Channel?

    /// Channel handler for data flow
    private(set) var channelHandler: SSHChannelHandler?

    /// Whether this session currently has an attached, writable SSH channel
    var hasAttachedChannel: Bool {
        sshChannel != nil && channelHandler != nil
    }

    /// When this pane was last on screen; the app keeps the most recent ones attached
    var lastShownAt: Date?

    /// The last reconnect failed: it waits for the user (a click to try again). Until
    /// then a disconnected pane on screen is about to connect.
    @Published var reconnectFailed = false

    /// The app let this idle pane's channel go (`rest()`); its terminal is as it was.
    /// Showing it attaches again without a "Connecting" notice.
    @Published var isResting = false

    /// Reference to parent connection (for sending data)
    weak var parentConnection: SSHConnection?

    /// The host's SSH connection this pane's channel is on (shared with its other panes;
    /// SessionManager.hostConnections owns it)
    var sshConnection: SSHConnection?

    // MARK: - Terminal Size

    /// Initial terminal size to use when connecting (rows, columns)
    /// Set this before connecting for correct initial PTY size
    var initialTerminalSize: (rows: Int, columns: Int) = (30, 60)

    /// The size to open a channel at: the one last sent, else the first one the view had.
    /// A reattach at a stale size made the program redraw once more for nothing.
    var attachSize: (rows: Int, columns: Int) {
        lastWindowSize.map { (Int($0.rows), Int($0.columns)) } ?? initialTerminalSize
    }

    // MARK: - Power Management

    /// Whether output streaming is paused (tab is inactive/backgrounded)
    private(set) var isPaused: Bool = false

    /// Whether this session's tab is currently active/foreground
    private(set) var isActive: Bool = false

    /// Whether we're pre-fetching after idle (need to re-pause after receiving data)
    private var isPrefetchingOnIdle: Bool = false

    /// When the last idle pre-fetch started. rtach sends SIGWINCH on every resume, so a
    /// pre-fetch makes full-screen programs repaint, and the repaint ends in another idle
    /// 2 s later. Pre-fetching on that one too looped every ~2.5 s for as long as the tab
    /// stayed in the background (a Herdr attach redraws ~4 KB each time).
    private var lastPrefetchAt: Date?
    private let prefetchCooldown: TimeInterval = 10

    /// Whether we want to pause but are waiting for framed mode to be established
    private var pendingPause: Bool = false

    /// Whether we want to claim active but are waiting for framed mode
    private var pendingActiveClaim: Bool = false
    /// The waiting claim is for commands only (a full one replaces it)
    private var pendingClaimCommandsOnly: Bool = false

    // MARK: - rtach Session

    /// The rtach session ID to use when connecting (nil = create new session)
    var rtachSessionId: String? {
        didSet {
            // Restore the saved title when resuming a session
            if let sessionId = rtachSessionId {
                restoreSavedTitle(rtachSessionId: sessionId)
            }
        }
    }

    /// Whether this session is currently using rtach protocol framing.
    private(set) var usesRtach: Bool = false

    /// Storage key for persisting dynamic title
    private static func titleStorageKey(connectionId: UUID, rtachSessionId: String) -> String {
        return "session_title_\(connectionId.uuidString)_\(rtachSessionId)"
    }

    /// Restore saved title for a resumed session
    private func restoreSavedTitle(rtachSessionId: String) {
        // Restore Claude session flag first
        restoreClaudeSessionFlag(rtachSessionId: rtachSessionId)

        // Restore title
        let key = Self.titleStorageKey(connectionId: connectionConfig.id, rtachSessionId: rtachSessionId)
        if let savedTitle = UserDefaults.standard.string(forKey: key) {
            // Only restore if we don't already have a dynamic title
            if dynamicTitle == nil {
                dynamicTitle = savedTitle
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): restored title '\(savedTitle.prefix(30))'")
            }
        }
    }

    // MARK: - Scrollback Buffer

    /// Buffer of all received data (for persistence)
    private(set) var scrollbackBuffer = Data()

    /// Maximum scrollback buffer size (50KB)
    private let maxScrollbackSize = 50 * 1024

    // MARK: - Callbacks

    /// Called when data is received from SSH (to display in terminal)
    var onDataReceived: ((Data) -> Void)?

    /// The pane's size and whether it's this phone's, from rtach (2.26.0+; nil before it
    /// says, or from older masters). When it isn't, another device attached to the pane
    /// (a laptop) is in use and its output is drawn for that device's size.
    @Published private(set) var ptySize: RtachClient.PtySize?

    /// Another device has the pane: the terminal is drawn at its size, scaled to fit
    var inUseElsewhere: Bool { ptySize.map { !$0.yours } ?? false }

    /// Called with ptySize when it changes, in order with the terminal data around it
    var onPtySizeChanged: ((RtachClient.PtySize?) -> Void)?

    /// Called when session state changes
    var onStateChanged: ((State) -> Void)?

    /// Called when old scrollback is received (to prepend to terminal)
    var onScrollbackReceived: ((Data) -> Void)?

    /// Reads the terminal's text with its styling as VT (SGR) sequences: the screen,
    /// or with `true` the scrollback too. Set by the tab's terminal view; nil until
    /// it has a surface.
    var readTerminalText: ((Bool) -> String?)?

    /// The cursor's row in the terminal (points from its top) and the row height: agent
    /// mode's windows crop the terminal to whole rows around it
    struct CursorRow: Equatable {
        let top: CGFloat
        let height: CGFloat
    }
    @Published private(set) var cursorRow: CursorRow?
    /// Set by the terminal view
    var readCursorRow: (() -> CursorRow?)?
    /// A tap at this point (in the terminal's points): a click when a TUI takes the
    /// mouse, else the paste menu at the cursor. Set by the terminal view; agent mode's
    /// windows don't take touches themselves.
    var tapTerminal: ((CGPoint) -> Void)?
    /// A press and hold there: the edit menu (Paste), as a long press shows it
    var holdTerminal: ((CGPoint) -> Void)?
    /// Drops the terminal's selection, its handles and menu
    var clearSelection: (() -> Void)?
    /// The terminal has had output since the app started (agent mode's windows say
    /// they're connecting until then)
    @Published private(set) var hasOutput = false
    /// The program on the alternate screen didn't draw when this attach asked it to (rtach
    /// 2.37.0's `ready`): its name (possibly empty). The screen stays blank until it
    /// draws, so the views say it isn't responding instead. Cleared by its next output.
    @Published private(set) var notDrawing: String?
    /// What the views say while `notDrawing`: which program, and on which machine, since
    /// the problem is there and not in the app ("claude on devbox isn't responding"), then
    /// the likely reason
    var notRespondingMessage: (title: String, detail: String)? {
        guard let program = notDrawing else { return nil }
        let host = connectionConfig.isLocal ? "this Mac"
            : connectionConfig.name.isEmpty ? connectionConfig.host : connectionConfig.name
        let name = program.isEmpty ? "The program" : program
        return ("\(name) on \(host) isn't responding", "It may be waiting on something there, like a dialog")
    }
    /// Brings the soft keyboard back if it was hidden with the key bar; set by the
    /// terminal view
    var showKeyboard: (() -> Void)?
    /// Scrolls the terminal as a one-finger drag would: nil starts a drag, then each
    /// call is the finger's move in points (down: back through the history). Set by the
    /// terminal view; agent mode's windows don't take touches themselves.
    var scrollTerminal: ((CGFloat?) -> Void)?
    /// A TUI has taken the mouse (scrolls go to it as wheel events); set by the terminal view
    var terminalTakesMouse: (() -> Bool)?
    private var cursorUpdatePending = false

    /// Refresh cursorBottom soon (output arrived), at most a few times a second
    func scheduleCursorUpdate() {
        guard !cursorUpdatePending, readCursorRow != nil else { return }
        cursorUpdatePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.cursorUpdatePending = false
            let value = self.readCursorRow?()
            if value != self.cursorRow { self.cursorRow = value }
        }
    }

    /// Called when a port forward is requested via OSC 777
    var onPortForwardRequested: ((Int) -> Void)?

    /// Called when a web tab should be opened (`clauntty tab`): the port, and the pane
    /// that asked (rtach 2.29+; it may not be this session's, see handleRtachCommand)
    var onOpenTabRequested: ((Int, String?) -> Void)?

    /// Called when session needs reconnection (detected nil channel on send attempt)
    var onNeedsReconnect: (() -> Void)?

    /// The user closed it: when its channel closes (the host ended the session), it
    /// ends rather than reconnecting
    var isClosing = false

    /// Its rtach session said it ended (`ended`, rtach 2.22+): its shell exited or it was
    /// stopped. When the channel closes it ends rather than reconnecting.
    var hasEnded = false

    /// Called when the rtach session says it ended
    var onSessionEnded: (() -> Void)?

    /// Called when a URL should be opened in the device browser
    var onOpenBrowserRequested: ((String) -> Void)?

    /// Called when `clauntty show` sends an image path on the remote host, with its
    /// inbox ID (nil from rtach before 2.10) and the pane that sent it (rtach 2.21+)
    var onShowImageRequested: ((_ path: String, _ inboxId: String?, _ pane: String?) -> Void)?
    /// `clauntty review` made a review (rtach 2.38.0+): its id on the host, and the pane
    /// that ran it
    var onReviewRequested: ((_ id: String) -> Void)?

    /// `rtach ws` changed the host's workspaces: the workspace and pane to show, if any
    var onWorkspaceChanged: ((_ workspaceId: String?, _ paneId: String?) -> Void)?

    /// A session's state changed (`pane;<id>;<json>`): any pane on the host, not only this one
    var onPaneStateChanged: ((_ paneId: String, _ json: String) -> Void)?

    /// The user typed or pasted into this pane (the Mac's terminal view)
    var onTyped: (() -> Void)?

    /// rtach tracks an agent in this session (hooks): its state drives notifications,
    /// not the idle guess
    var agentTracked = false

    // MARK: - rtach Protocol Session

    /// State machine for rtach protocol (raw/framed mode handling)
    private let rtachProtocol = RtachClient.RtachSession()

    /// Debug counters for tracking data flow
    private var totalBytesReceived = 0
    private(set) var totalBytesToTerminal = 0

    // MARK: - Paginated Scrollback State

    /// Page size for scrollback requests (16KB)
    private let scrollbackPageSize = 16 * 1024

    /// History is paged backwards: each page ends where the previous one (at first, the
    /// attach replay) started. Absolute stream position, or historyBeforeReplay before
    /// the first page. (Paging used to go forward from the oldest byte while prepending
    /// each page, so history came out out of order, with gaps and duplicates.)
    private var historyBefore: UInt64 = ProtocolConstants.historyBeforeReplay

    /// Consecutive pages that came back empty (all alternate-screen output); bounded so
    /// a long full-screen session can't keep requesting
    private var emptyHistoryPages = 0
    private let maxEmptyHistoryPages = 8

    /// Whether we've finished loading all scrollback
    private var scrollbackFullyLoaded: Bool = false

    /// Whether a scrollback page request is currently in flight
    private var scrollbackPageRequestPending: Bool = false

    // MARK: - Initialization

    init(connectionConfig: SavedConnection, id: UUID = UUID(), createdAt: Date = Date(), groupId: UUID? = nil) {
        self.id = id
        self.connectionConfig = connectionConfig
        self.createdAt = createdAt
        self.groupId = groupId
    }

    // MARK: - Channel Management

    /// Attach an SSH channel to this session
    /// - Parameters:
    ///   - channel: The SSH channel
    ///   - handler: The channel handler
    ///   - connection: The parent SSH connection
    ///   - expectsRtach: Whether to expect rtach protocol (session management enabled)
    func attach(channel: Channel, handler: SSHChannelHandler, connection: SSHConnection, expectsRtach: Bool = true) {
        self.sshChannel = channel
        self.channelHandler = handler
        self.parentConnection = connection
        self.state = .connected
        self.usesRtach = expectsRtach
        onStateChanged?(.connected)

        // Reset scrollback tracking state for reconnects
        // rtach will send scrollback when we reconnect to an existing session
        resetBeforeReplay = expectsRtach
        reconnectFailed = false
        if expectsRtach { beginSettling() }
        isResting = false
        historyBefore = ProtocolConstants.historyBeforeReplay
        emptyHistoryPages = 0
        scrollbackFullyLoaded = false
        scrollbackPageRequestPending = false

        // Set up rtach protocol delegate and mark as connected
        rtachProtocol.expectsRtach = expectsRtach
        rtachProtocol.delegate = self
        rtachProtocol.connect()
        setPtySize(nil)

        // What came before (the handshake, often)
        let early = earlyData ?? []
        earlyData = nil
        early.forEach(handleDataReceived)

        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): channel attached, channelHandler is set")
    }

    /// Close the channel but keep the terminal: an idle pane costs its host nothing
    /// until it's shown again, which attaches it (the replay starts the terminal over)
    func rest() {
        isResting = true
        detach()
    }

    /// Detach the channel (on disconnect)
    func detach() {
        // Clean up inactivity timer
        inactivityTimer?.invalidate()
        inactivityTimer = nil

        // Close this pane's channel: the SSH connection is the host's, shared with its
        // other panes. What it still sends is dropped.
        attachToken = nil
        sshChannel?.close(promise: nil)
        sshConnection = nil
        sshChannel = nil
        channelHandler = nil
        parentConnection = nil
        state = .disconnected
        onStateChanged?(.disconnected)

        // Reset rtach protocol state for reconnection
        rtachProtocol.reset()
        forgetPause()

        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): channel detached")
    }

    /// The next attach is a new rtach client, and it streams: a pause, or a pre-fetch under
    /// way, was the old channel's. Kept, a pane shown again after the app let it go (idle)
    /// was paused by the pre-fetch's re-pause right after attaching, and its redraw waited
    /// in rtach until it was shown once more: blank, or half drawn.
    private func forgetPause() {
        isPaused = false
        isPrefetchingOnIdle = false
        pendingPause = false
    }

    // MARK: - Data Flow

    /// The attach under way or current (expectAttach); a channel's data with another
    /// token is from a channel this session has left, and is dropped
    private var attachToken: UUID?
    /// Data that came before attach() for this token: rtach's handshake can beat it (the
    /// channel's requests go out together), and the protocol isn't reading until then.
    /// Dropped, it left the pane waiting for a handshake that had come.
    private var earlyData: [Data]? = []

    /// A channel is about to be opened for this session: its data carries this token
    func expectAttach() -> UUID {
        let token = UUID()
        attachToken = token
        earlyData = []
        return token
    }

    /// Data from the channel opened with `token`
    func handleChannelData(_ data: Data, token: UUID) {
        guard token == attachToken else { return }
        if earlyData != nil {
            earlyData?.append(data)
            return
        }
        handleDataReceived(data)
    }

    /// Handle data received from SSH
    /// Delegates to RtachSession for protocol handling (raw vs framed mode)
    func handleDataReceived(_ data: Data) {
        self.totalBytesReceived += data.count
        if isAwaitingResume { endResuming() }
        // Verbose: expensive hex dump of incoming data
        Logger.clauntty.verbose("[FRAME] received \(data.count) bytes (total=\(self.totalBytesReceived)), state=\(String(describing: self.rtachProtocol.state)), first32=\(data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))")

        // Delegate to RtachSession for protocol handling
        rtachProtocol.processIncomingData(data)
    }

    /// Handle SSH channel becoming inactive (connection lost)
    /// This is called when the underlying TCP connection dies (e.g., after background timeout)
    func handleChannelInactive() {
        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): handling channel inactive")
        // The reconnect shows its own overlay
        endResuming()

        // Clear channel references
        parentConnection = nil
        sshConnection = nil
        sshChannel = nil
        channelHandler = nil

        // Reset protocol/transport state so reconnect starts cleanly
        rtachProtocol.reset()
        usesRtach = false
        forgetPause()
        pendingActiveClaim = false
        isWaitingForInput = false

        // Update state to disconnected
        state = .disconnected
        onStateChanged?(state)
    }

    // MARK: - Resuming Indicator

    /// Back in the foreground but nothing heard from the server yet. After the app has
    /// been suspended, the connection can stay open while no data moves for several
    /// seconds (the embedded Tailscale re-handshaking), so the screen would sit stale
    /// without any sign that it's waiting.
    @Published private(set) var isResuming: Bool = false
    private var isAwaitingResume = false
    private var resumingTask: Task<Void, Never>?

    /// Wait before showing the overlay: a healthy connection answers within
    /// milliseconds and shouldn't flash it
    private let resumingShowDelay: Duration = .milliseconds(400)

    /// The app came back to the foreground with this session connected
    func beginResuming() {
        guard state == .connected else { return }
        isAwaitingResume = true
        resumingTask?.cancel()
        resumingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.resumingShowDelay)
            guard !Task.isCancelled, self.isAwaitingResume else { return }
            self.isResuming = true
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): nothing received since foreground, showing resuming overlay")
        }
    }

    /// Data arrived, the connection check found the connection alive, or it closed
    func endResuming() {
        guard isAwaitingResume || isResuming else { return }
        isAwaitingResume = false
        resumingTask?.cancel()
        resumingTask = nil
        if isResuming {
            isResuming = false
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): resumed, hiding resuming overlay")
        }
    }

    // MARK: - Loading Indicator

    /// Whether we're currently loading a large amount of data (show loading indicator)
    @Published private(set) var isLoadingContent: Bool = false

    /// Bytes received in the current sliding window
    private var recentBytes: [(Date, Int)] = []

    /// Timer to check if loading is complete
    private var loadingCheckTimer: Timer?

    /// Threshold: show loading if we receive this many bytes in the window
    private let loadingShowThreshold = 10 * 1024  // 10KB (show quickly)

    /// Window size for tracking recent bytes
    private let loadingWindowSize: TimeInterval = 0.1  // 100ms

    /// How long of low activity before hiding loading indicator
    private let loadingHideDelay: TimeInterval = 0.3  // 300ms

    /// Update loading state based on incoming data rate
    private func updateLoadingState(bytesReceived: Int) {
        let now = Date()

        // Add this chunk to recent bytes
        recentBytes.append((now, bytesReceived))

        // Remove old entries outside the window
        let windowStart = now.addingTimeInterval(-loadingWindowSize)
        recentBytes.removeAll { $0.0 < windowStart }

        // Calculate bytes in window
        let bytesInWindow = recentBytes.reduce(0) { $0 + $1.1 }

        // If receiving lots of data, show loading indicator
        if bytesInWindow >= loadingShowThreshold {
            if !isLoadingContent {
                isLoadingContent = true
                Logger.clauntty.debugOnly("[LOAD] Showing loading indicator (bytes in window: \(bytesInWindow))")
            }

            // Reset/restart the hide timer
            loadingCheckTimer?.invalidate()
            loadingCheckTimer = Timer.scheduledTimer(withTimeInterval: loadingHideDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.checkLoadingComplete()
                }
            }
        }
    }

    /// Check if loading is complete (called after delay)
    private func checkLoadingComplete() {
        let now = Date()
        let windowStart = now.addingTimeInterval(-loadingWindowSize)
        recentBytes.removeAll { $0.0 < windowStart }

        let bytesInWindow = recentBytes.reduce(0) { $0 + $1.1 }

        // If data rate is low, hide loading indicator
        if bytesInWindow < 1024 {  // Less than 1KB in window
            if isLoadingContent {
                isLoadingContent = false
                Logger.clauntty.debugOnly("[LOAD] Hiding loading indicator (bytes in window: \(bytesInWindow))")
            }
        } else {
            // Still receiving data, check again later
            loadingCheckTimer = Timer.scheduledTimer(withTimeInterval: loadingHideDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.checkLoadingComplete()
                }
            }
        }
    }

    /// The next output starts the terminal over: rtach replays the screen and recent
    /// scrollback on every attach, and on top of what's already here it showed twice
    private var resetBeforeReplay = false

    /// Process terminal data (forward to terminal and track scrollback)
    private func processTerminalData(_ data: Data) {
        var data = data
        // rtach's own output: anything before its handshake (through Tailscale SSH,
        // `login` can print first) used up this check and missed the alternate screen
        if resetBeforeReplay, rtachProtocol.isFramedMode {
            resetBeforeReplay = false
            // A full reset (ESC c) clears the screen and scrollback, in the same write as
            // the replay so nothing draws in between. Older history pages in on scroll.
            data = Data([0x1b, 0x63]) + data
            scrollbackBuffer.removeAll()
            // A program on the alternate screen gets no replay, only a redraw, and only
            // for a real size change (Node ignores a SIGWINCH at the same size)
            if !expectingReady, data.range(of: Self.altScreenEnter) != nil {
                forceRemoteRepaint()
                nudgedSinceAttach = true
            }
        }
        if settling {
            settleHeld.append(data)
            if awaitingRedraw && nudgeRestored { awaitingRedraw = false }
            scheduleSettle()
            return
        }
        writeToTerminal(data)
    }

    private static let altScreenEnter = Data([0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x68]) // ESC[?1049h

    // MARK: - Settling After an Attach

    /// After an attach, output is held until it settles, then written at once: the replay,
    /// or a program's redraw for the new size, otherwise drew piece by piece as it came,
    /// the cursor walking down the screen. The terminal shows what it had meanwhile.
    private var settling = false
    private var settleHeld = Data()
    private var settleTimer: DispatchWorkItem?
    private var settleDeadline = Date.distantPast
    /// The repaint nudge is under way: the redraw that counts comes after it
    private var awaitingRedraw = false
    /// The nudge has put the real size back: output from now is that redraw
    private var nudgeRestored = false
    /// The real size while the nudge has the remote one row short
    private var nudgedSize: (rows: UInt16, columns: UInt16)?
    /// The repaint nudge went out for this attach
    private var nudgedSinceAttach = false
    /// The master sends `ready` (rtach 2.30.0+): output is held until then, and it does
    /// the repaint nudge itself. Older masters get the app's nudge and quiet window.
    private var expectingReady = false
    /// No more output for this long: it has settled
    private static let settleQuiet: TimeInterval = 0.05
    /// Held no longer than this after the attach, however busy the program (the
    /// master's nudge gives up after 0.5-1s)
    private static let settleLimit: TimeInterval = 1.5

    private func beginSettling() {
        settleTimer?.cancel()
        settling = true
        notDrawing = nil
        nudgedSinceAttach = false
        expectingReady = false
        awaitingRedraw = false
        settleHeld = Data()
        settleDeadline = Date().addingTimeInterval(Self.settleLimit)
        // Nothing comes at all: let go at the limit
        scheduleSettle(after: Self.settleLimit)
    }

    private func scheduleSettle(after delay: TimeInterval = Session.settleQuiet) {
        settleTimer?.cancel()
        let remaining = settleDeadline.timeIntervalSinceNow
        guard remaining > 0 else { return finishSettling() }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.settling else { return }
            // Still waiting on the program's redraw for the real size, on `ready`, or on
            // rtach at all (what came was from before its handshake: a login banner)
            if self.awaitingRedraw || self.expectingReady || !self.rtachProtocol.isFramedMode,
               self.settleDeadline.timeIntervalSinceNow > 0 {
                return self.scheduleSettle(after: self.settleDeadline.timeIntervalSinceNow)
            }
            self.finishSettling()
        }
        settleTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + min(delay, remaining), execute: item)
    }

    private func finishSettling() {
        settleTimer?.cancel()
        settleTimer = nil
        guard settling else { return }
        settling = false
        // The program didn't redraw after the nudge: once more, or the pane stays blank
        // Or it's on the alternate screen and no nudge went out at all (the master does it
        // when it sends `ready`)
        let missedRedraw = !expectingReady && !rtachProtocol.supportsReady
            && (awaitingRedraw || (!nudgedSinceAttach && settleHeld.range(of: Self.altScreenEnter) != nil))
        awaitingRedraw = false
        expectingReady = false
        let held = settleHeld
        settleHeld = Data()
        if !held.isEmpty { writeToTerminal(held) }
        if missedRedraw {
            Logger.clauntty.warning("Session \(self.id.uuidString.prefix(8)): no redraw after the repaint nudge, nudging again")
            forceRemoteRepaint()
        }
    }

    /// Forward output to the terminal and keep the bookkeeping that goes with it
    private func writeToTerminal(_ data: Data) {
        let sessionTitle = self.title.prefix(15)
        let hasCallback = self.onDataReceived != nil
        Logger.clauntty.verbose("DATA_FLOW[\(self.id.uuidString.prefix(8))] '\(sessionTitle)': \(data.count) bytes, callback=\(hasCallback)")
        totalBytesToTerminal += data.count
        // It drew after all
        if notDrawing != nil {
            notDrawing = nil
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): the program drew, it's responding again")
        }

        // Log if this data contains alternate screen switch escape sequence
        // ESC[?1049h = switch to alternate screen (bytes: 1b 5b 3f 31 30 34 39 68)
        // ESC[?1049l = switch to normal screen (bytes: 1b 5b 3f 31 30 34 39 6c)
        // Search for byte pattern directly (more reliable than UTF-8 string conversion)
        let altScreenEnter = Data([0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x68]) // ESC[?1049h
        let altScreenExit = Data([0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x6c])  // ESC[?1049l

        if data.range(of: altScreenEnter) != nil {
            Logger.clauntty.verbose("[ALTSCREEN] Received ESC[?1049h (switch to alternate screen) in \(data.count) bytes")
        }
        if data.range(of: altScreenExit) != nil {
            Logger.clauntty.verbose("[ALTSCREEN] Received ESC[?1049l (switch to normal screen) in \(data.count) bytes")
        }

        // Track loading state for showing loading indicator
        updateLoadingState(bytesReceived: data.count)

        // Reset inactivity timer - we received output
        resetInactivityTimer()

        // Append to scrollback buffer
        scrollbackBuffer.append(data)

        // Trim if too large (keep most recent data)
        if scrollbackBuffer.count > maxScrollbackSize {
            let excess = scrollbackBuffer.count - maxScrollbackSize
            scrollbackBuffer.removeFirst(excess)
        }

        // Forward to terminal
        onDataReceived?(data)
        if !hasOutput { hasOutput = true }
        scheduleCursorUpdate()

        // If we were pre-fetching on idle, re-pause now that we have the data
        if isPrefetchingOnIdle {
            isPrefetchingOnIdle = false
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): pre-fetch complete, re-pausing")
            rtachProtocol.sendPause()
        }
    }

    // TODO: The semicolon delimiter doesn't support multiple args if any arg contains semicolons.
    // Current commands only use single args (port or URL), so maxSplits:1 works.
    // If we need multi-arg commands, consider URL-encoding args or using a different delimiter.

    /// Handle a command received from rtach via command pipe
    /// Format: "command;arg1;arg2..."
    private func handleRtachCommand(_ command: String) {
        let parts = command.split(separator: ";", maxSplits: 1)
        guard let cmd = parts.first else { return }

        switch cmd {
        case "open":
            // "open;<port>;<pane>": commands come through the session the app shows, so
            // the pane says whose workspace the tab belongs to. Older rtach: "open;<port>".
            let args = parts.count > 1 ? parts[1].split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false) : []
            if let first = args.first, let port = Int(first) {
                let pane = args.count > 1 && !args[1].isEmpty ? String(args[1]) : nil
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): rtach command open port \(port) (pane \(pane ?? "none"))")
                onOpenTabRequested?(port, pane)
            }
        case "forward":
            if parts.count > 1, let port = Int(parts[1]) {
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): rtach command forward port \(port)")
                onPortForwardRequested?(port)
            }
        case "browser":
            if parts.count > 1 {
                let urlString = String(parts[1])
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): rtach command browser \(urlString)")
                onOpenBrowserRequested?(urlString)
            }
        case "image":
            if parts.count > 1 {
                let (path, inboxId, pane) = ImageInbox.parseImageArgument(String(parts[1]))
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): rtach command image \(path) (inbox \(inboxId ?? "none"), pane \(pane ?? "none"))")
                onShowImageRequested?(path, inboxId, pane)
            }
        case "review":
            // "review;<id>;<pane>": the pane is in the bundle too
            let id = parts.count > 1 ? String(parts[1].prefix { $0 != ";" }) : ""
            if ReviewReply.isValidId(id) {
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): rtach command review \(id)")
                onReviewRequested?(id)
            }
        case "ended":
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): rtach session ended")
            hasEnded = true
            onSessionEnded?()
        case "pane":
            let target = parts.count > 1 ? parts[1].split(separator: ";", maxSplits: 1) : []
            if target.count == 2 {
                onPaneStateChanged?(String(target[0]), String(target[1]))
            }
        case "push":
            // A pane's push notice (`<pane>;<kind>;<title>;<body>`), passed on by an older
            // master that doesn't send pushes: the app is here, so it notifies itself
            let notice = parts.count > 1 ? parts[1].split(separator: ";", maxSplits: 3, omittingEmptySubsequences: false) : []
            #if os(iOS)
            if notice.count == 4 {
                Task { await NotificationManager.shared.schedulePaneAttention(title: String(notice[2]), body: String(notice[3]), paneId: String(notice[0])) }
            }
            #endif
        case "workspace":
            // "workspace;<ws>/<pane>" shows a new pane, "workspace;" only refreshes
            let target = parts.count > 1 ? parts[1].split(separator: "/", maxSplits: 1) : []
            let workspaceId = target.count == 2 ? String(target[0]) : nil
            let paneId = target.count == 2 ? String(target[1]) : nil
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): rtach command workspace \(paneId ?? "(refresh)")")
            onWorkspaceChanged?(workspaceId, paneId)
        default:
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): unknown rtach command: \(cmd)")
        }
    }

    // MARK: - Inactivity Detection

    /// Reset the inactivity timer when output is received
    private func resetInactivityTimer() {
        inactivityTimer?.invalidate()

        // If we were waiting for input, we're not anymore (got output)
        // BUT: don't reset during pre-fetch - that's just catching up on buffered data
        if isWaitingForInput && !isPrefetchingOnIdle {
            isWaitingForInput = false
        }

        // Skip local idle detection when rtach is handling it server-side
        // rtach sends idle notifications which are more accurate (monitors PTY directly)
        guard !rtachProtocol.isFramedMode else { return }

        // Schedule timer to check for idle state (only for non-rtach connections)
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: inactivityThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.checkIfWaitingForInput()
            }
        }
    }

    /// Check if terminal is waiting for input after inactivity period
    private func checkIfWaitingForInput() {
        // Inactivity-based detection: no output for 1.5s means likely waiting for input
        if !isWaitingForInput {
            isWaitingForInput = true
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): waiting for input")
            checkNotificationForWaitingInput()
        }
    }

    /// Check if we should send a notification when waiting for input
    private func checkNotificationForWaitingInput() {
        // If we have title info, check notification immediately
        if dynamicTitle != nil || _isClaudeSession {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): checking notification, isClaudeSession=\(self.isClaudeSession)")
            #if os(iOS)
            if NotificationManager.shared.shouldNotify(for: self) {
                Task {
                    await NotificationManager.shared.scheduleInputReady(session: self)
                }
            }
            #endif
        } else {
            // No title yet - wait for title to be set
            pendingNotificationCheck = true
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): pending notification check (waiting for title)")
        }
    }

    /// Send data to remote (keyboard input)
    /// Uses rtach protocol to automatically frame when in framed mode
    func sendData(_ data: Data) {
        Logger.clauntty.verbose("Session \(self.id.uuidString.prefix(8)): sendData called with \(data.count) bytes, channelHandler=\(self.channelHandler != nil ? "set" : "nil")")
        if channelHandler == nil {
            Logger.clauntty.error("Session \(self.id.uuidString.prefix(8)): sendData called but channelHandler is nil!")

            // Connection dropped silently - update state if not already disconnected
            if state == .connected {
                handleChannelInactive()
            }
            // Also when it was already marked disconnected: typing into a dead tab
            // should bring it back (reconnect skips sessions already connecting)
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): no channel, triggering reconnect")
            onNeedsReconnect?()
            return
        }
        // Route through rtach protocol - handles raw vs framed mode
        rtachProtocol.sendKeyboardInput(data)
    }

    /// Last size sent to the remote, for forcing a repaint after reattach
    private var lastWindowSize: (rows: UInt16, columns: UInt16)?

    /// Send window size change
    func sendWindowChange(rows: UInt16, columns: UInt16) {
        Logger.clauntty.debugOnly("TAB_SWITCH: sendWindowChange called \(columns)x\(rows)")
        // While another device has the pane, the terminal is sized to its grid: that isn't
        // this phone's size. The phone's goes out again when the terminal sizes back.
        if inUseElsewhere {
            Logger.clauntty.debugOnly("TAB_SWITCH: sendWindowChange SKIPPED (in use on another device)")
            return
        }
        // The repaint nudge has the remote one row short: its restore sends this size.
        // Sent now (the view sends its size again as the attach settles), the program
        // read the real size again before noticing the change, and didn't redraw.
        if let nudged = nudgedSize, nudged == (rows, columns) {
            return
        }
        lastWindowSize = (rows, columns)
        guard let channel = sshChannel else {
            // Expected during connection setup - size will be sent after channel is established
            Logger.clauntty.debugOnly("TAB_SWITCH: sendWindowChange SKIPPED (no channel)")
            return
        }

        // Send SSH window change request
        let windowChange = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: Int(columns),
            terminalRowHeight: Int(rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )

        channel.eventLoop.execute {
            channel.triggerUserOutboundEvent(windowChange, promise: nil)
        }

        // Also send via rtach protocol (WINCH packet) if in framed mode
        let size = RtachClient.WindowSize(rows: rows, cols: columns)
        rtachProtocol.sendWindowSize(size)

        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): window change \(columns)x\(rows)")
    }

    /// Upload an image to the remote server for pasting (e.g., into Claude Code)
    /// - Returns: The image's path on the remote host, or nil if the upload failed
    func uploadImage(_ image: PlatformImage) async -> String? {
        guard let connection = sshConnection else {
            Logger.clauntty.error("Session \(self.id.uuidString.prefix(8)): cannot upload image, no SSH connection")
            return nil
        }

        // Convert image to PNG data
        guard let imageData = image.platformPNGData() else {
            Logger.clauntty.error("Session \(self.id.uuidString.prefix(8)): failed to convert image to PNG")
            return nil
        }

        // Generate unique filename
        let filename = "clauntty-paste-\(UUID().uuidString.prefix(8)).png"
        let remotePath = "/tmp/\(filename)"

        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): uploading image (\(imageData.count) bytes) to \(remotePath)")

        do {
            try await connection.executeWithStdin("cat > \(remotePath)", stdinData: imageData)
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): image uploaded")
            return remotePath
        } catch {
            Logger.clauntty.error("Session \(self.id.uuidString.prefix(8)): failed to upload image: \(error)")
            return nil
        }
    }

    /// Download a file from the remote host over this session's SSH connection
    func downloadFile(_ path: String, maxBytes: Int) async throws -> Data {
        guard let connection = sshConnection else { throw SessionError.notConnected }
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // One byte over the limit tells a too-large file from one that fits exactly
        let data = try await connection.executeCommandData("head -c \(maxBytes + 1) \(quoted)")
        guard data.count <= maxBytes else { throw SessionError.fileTooLarge }
        return data
    }

    /// Entries waiting in the remote host's image inbox
    func listImageInbox() async throws -> [ImageInbox.Entry] {
        guard let connection = sshConnection else { throw SessionError.notConnected }
        return ImageInbox.parseList(try await connection.executeCommand(ImageInbox.listCommand))
    }

    /// Run a POSIX sh script on the remote host and return its output. The script
    /// travels as base64, so it needs no quoting for whatever the login shell is
    /// (fish included).
    func runRemoteScript(_ script: String) async throws -> String {
        guard let connection = sshConnection else { throw SessionError.notConnected }
        let encoded = Data(script.utf8).base64EncodedString()
        return try await connection.executeCommand("echo \(encoded) | base64 -d | sh")
    }

    /// Reviews waiting on the host (`clauntty review`)
    func listReviews() async throws -> [String] {
        guard let connection = sshConnection else { throw SessionError.notConnected }
        return try await connection.executeCommand(ReviewReply.listCommand)
            .split(separator: "\n").map(String.init).filter(ReviewReply.isValidId)
    }

    enum ReviewDelivery: String {
        /// The waiting command took it
        case delivered
        /// Nobody was waiting: the comments should go to the pane
        case gone
        /// The review was already closed (sent from another device)
        case answered
    }

    /// Hand the user's comments to the `clauntty review` waiting for them
    func sendReviewReply(id: String, report: String) async throws -> ReviewDelivery {
        guard ReviewReply.isValidId(id) else { throw SessionError.notConnected }
        let output = try await runRemoteScript(ReviewReply.sendScript(id, report: report))
        guard let result = ReviewDelivery(rawValue: output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SessionError.reviewReplyFailed(output)
        }
        return result
    }

    /// Close a review without comments: the waiting command exits
    func dismissReview(id: String) async {
        guard let connection = sshConnection, ReviewReply.isValidId(id) else { return }
        _ = try? await connection.executeCommand(ReviewReply.dismissCommand(id))
    }

    func removeFromImageInbox(_ ids: [String]) async {
        guard let connection = sshConnection, let command = ImageInbox.removeCommand(ids) else { return }
        do {
            _ = try await connection.executeCommand(command)
        } catch {
            Logger.clauntty.warning("Session \(self.id.uuidString.prefix(8)): failed to clear image inbox: \(error.localizedDescription)")
        }
    }

    // MARK: - Power Management

    /// Pause terminal output streaming (for inactive tabs/backgrounded app)
    /// rtach will buffer output locally and send idle notifications
    func pauseOutput() {
        endResuming()
        guard !isPaused else {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): pauseOutput skipped (already paused)")
            return
        }
        guard rtachProtocol.isFramedMode else {
            // Not in framed mode yet - remember to pause after handshake
            pendingPause = true
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): pauseOutput deferred (not framed mode yet)")
            return
        }

        pendingPause = false
        isPaused = true
        isPrefetchingOnIdle = false
        rtachProtocol.sendPause()
        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): paused output streaming")
    }

    /// Update active state for this session (foreground tab tracking)
    func setActiveState(_ active: Bool) {
        isActive = active
        if !active {
            pendingActiveClaim = false
        }
    }

    /// Resume terminal output streaming (when tab becomes active)
    /// rtach will flush any buffered output since pause
    func resumeOutput() {
        Logger.clauntty.debugOnly("TAB_SWITCH[\(self.id.uuidString.prefix(8))]: resumeOutput called, isPaused=\(self.isPaused), isFramedMode=\(self.rtachProtocol.isFramedMode)")
        // Clear pending pause if we're resuming before framed mode
        pendingPause = false

        guard isPaused else {
            Logger.clauntty.debugOnly("TAB_SWITCH[\(self.id.uuidString.prefix(8))]: resumeOutput SKIPPED (not paused)")
            return
        }
        guard rtachProtocol.isFramedMode else {
            Logger.clauntty.debugOnly("TAB_SWITCH[\(self.id.uuidString.prefix(8))]: resumeOutput SKIPPED (not framed mode)")
            return
        }

        isPaused = false
        isPrefetchingOnIdle = false
        // No redraw request: resume already makes rtach send SIGWINCH so full-screen apps
        // repaint, and on the normal screen rtach answers redraw by resending all stored
        // output. That was harmless only while the proxy dropped redraw (before 2.7.5);
        // since then every tab switch appended a copy of the history.
        rtachProtocol.sendResume()
        Logger.clauntty.debugOnly("TAB_SWITCH[\(self.id.uuidString.prefix(8))]: resumeOutput SENT resume to rtach")
    }

    private func setPtySize(_ size: RtachClient.PtySize?) {
        guard size != ptySize else { return }
        ptySize = size
        onPtySizeChanged?(size)
    }

    /// Claim active client for window size and command routing. `commandsOnly` when the
    /// pane is just being shown (launch, foreground, reconnect), not used: commands come
    /// here, but a device typing in the pane keeps its size until this one is used.
    func claimActive(commandsOnly: Bool = false) {
        guard rtachSessionId != nil else { return }
        guard rtachProtocol.isFramedMode else {
            pendingClaimCommandsOnly = commandsOnly && (!pendingActiveClaim || pendingClaimCommandsOnly)
            pendingActiveClaim = true
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): claimActive deferred (not framed mode yet)")
            return
        }

        pendingActiveClaim = false
        rtachProtocol.sendClaimActive(commandsOnly: commandsOnly)
        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): claimActive sent\(commandsOnly ? " (commands only)" : "")")
    }

    // MARK: - Scrollback Request

    /// Request a page of old scrollback from rtach (paginated)
    /// This uses the new request_scrollback_page message type (6) which returns
    /// scrollback in chunks to prevent iOS watchdog kills.
    func requestScrollbackPage() {
        // Only request scrollback after we've confirmed rtach is running (received handshake)
        // Before handshake or in raw mode, these packets would be sent to the shell as garbage input
        guard rtachProtocol.isRtachRunning else {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): skipping scrollback request (no rtach handshake received)")
            return
        }

        guard !scrollbackFullyLoaded else {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): scrollback already fully loaded")
            return
        }

        guard !scrollbackPageRequestPending else {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): scrollback page request already pending")
            return
        }

        guard channelHandler != nil else {
            Logger.clauntty.warning("Session \(self.id.uuidString.prefix(8)): cannot request scrollback, no channel")
            return
        }

        // Masters from before history paging (sessions started by rtach < 2.8) only have
        // the offset-based page request, which pages the wrong way; show no older history
        // rather than scrambled history until the session is restarted
        guard rtachProtocol.supportsHistory else {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): master predates history paging, not loading older scrollback")
            scrollbackFullyLoaded = true
            return
        }

        scrollbackPageRequestPending = true
        rtachProtocol.requestHistory(before: historyBefore, limit: UInt32(scrollbackPageSize))

        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): requesting history before=\(self.historyBefore == ProtocolConstants.historyBeforeReplay ? "replay" : String(self.historyBefore)) limit=\(self.scrollbackPageSize)")
    }

    /// Load more scrollback if user is scrolling near the top and more is available
    /// Call this from TerminalView when user scrolls near the top of scrollback
    func loadMoreScrollbackIfNeeded() {
        Logger.clauntty.verbose("[SCROLL] loadMoreScrollbackIfNeeded called, pending=\(self.scrollbackPageRequestPending), fullyLoaded=\(self.scrollbackFullyLoaded)")
        requestScrollbackPage()
    }

    // MARK: - Scrollback Persistence

    /// Get scrollback data for restoration
    func getScrollbackData() -> Data {
        return scrollbackBuffer
    }

    /// Restore scrollback from saved data
    func restoreScrollback(_ data: Data) {
        scrollbackBuffer = data
        // Note: Terminal surface will need to replay this data
    }

    /// Clear scrollback buffer
    func clearScrollback() {
        scrollbackBuffer.removeAll()
    }
}

// MARK: - Hashable

extension Session: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    nonisolated static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - RtachSessionDelegate

extension Session: RtachClient.RtachSessionDelegate {
    /// On the main actor, in the order rtach sent them: these are called on the main thread
    /// (processIncomingData runs there), where a Task per message doesn't keep the order
    nonisolated private func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(body) }
        }
    }

    /// The screen is ready to show: write what's been held, and from now on as it comes.
    /// A program that didn't draw for rtach's nudge leaves it blank: say so until it draws.
    nonisolated func rtachSessionDidReceiveReady(_ session: RtachClient.RtachSession, notDrawing: String?) {
        onMain {
            self.expectingReady = false
            self.finishSettling()
            if let notDrawing {
                self.notDrawing = notDrawing
                Logger.clauntty.warning("Session \(self.id.uuidString.prefix(8)): \(notDrawing.isEmpty ? "the program" : notDrawing) didn't draw for the nudge, showing not responding")
            }
        }
    }

    /// The stream from rtach lost its place (bytes missing or out of order): nothing more
    /// would show. Closing the channel attaches again with a fresh stream (onChannelInactive).
    nonisolated func rtachSessionLostSync(_ session: RtachClient.RtachSession) {
        onMain {
            Logger.clauntty.error("Session \(self.id.uuidString.prefix(8)): lost its place in rtach's stream, attaching again")
            self.sshChannel?.close(promise: nil)
        }
    }

    nonisolated func rtachSession(_ session: RtachClient.RtachSession, didReceiveTerminalData data: Data) {
        onMain {
            self.processTerminalData(data)
        }
    }

    nonisolated func rtachSession(_ session: RtachClient.RtachSession, didReceiveScrollback data: Data) {
        onMain {
            Logger.clauntty.debugOnly("Scrollback response complete: \(data.count) bytes")
            self.scrollbackPageRequestPending = false
            self.onScrollbackReceived?(data)
        }
    }

    nonisolated func rtachSession(_ session: RtachClient.RtachSession, didReceiveScrollbackPage meta: RtachClient.ScrollbackPageMeta, data: Data) {
        // Offset-based pages aren't requested any more (see requestScrollbackPage)
        onMain {
            self.scrollbackPageRequestPending = false
        }
    }

    nonisolated func rtachSession(_ session: RtachClient.RtachSession, didReceiveHistoryPage meta: RtachClient.HistoryPageMeta, data: Data) {
        onMain {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): history page \(meta.start)..<\(meta.end), \(data.count) bytes, oldest=\(meta.oldest)")

            self.scrollbackPageRequestPending = false
            self.historyBefore = meta.start
            if meta.reachedOldest {
                self.scrollbackFullyLoaded = true
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): history fully loaded")
            }

            if !data.isEmpty {
                self.emptyHistoryPages = 0
                self.onScrollbackReceived?(data)
            } else if !self.scrollbackFullyLoaded {
                // Only alternate-screen output in this range; look further back
                self.emptyHistoryPages += 1
                if self.emptyHistoryPages < self.maxEmptyHistoryPages {
                    self.requestScrollbackPage()
                }
            }
        }
    }

    nonisolated func rtachSession(_ session: RtachClient.RtachSession, didReceiveCommand data: Data) {
        onMain {
            if let commandString = String(data: data, encoding: .utf8) {
                Logger.clauntty.debugOnly("Received command from rtach: \(commandString)")
                self.handleRtachCommand(commandString)
            }
        }
    }

    nonisolated func rtachSession(_ session: RtachClient.RtachSession, sendData data: Data) {
        // Log at entry point for paste debugging - show first few bytes to identify packet type
        let preview = data.prefix(10).map { String(format: "%02X", $0) }.joined(separator: " ")
        Logger.clauntty.verbose("[PASTE] rtachSession entry: \(data.count) bytes, isMain=\(Thread.isMainThread), preview=\(preview)")

        // Must run synchronously to maintain packet order
        // The upgrade packet must be sent BEFORE we start framing keyboard input
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if let handler = self.channelHandler {
                    Logger.clauntty.verbose("[PASTE] sending sync: \(data.count) bytes")
                    handler.sendToRemote(data)
                } else {
                    Logger.clauntty.warning("[PASTE] channelHandler nil! Dropping \(data.count) bytes")
                }
            }
        } else {
            Logger.clauntty.warning("[PASTE] async dispatch! \(data.count) bytes - may cause ordering issues")
            Task { @MainActor in
                if let handler = self.channelHandler {
                    Logger.clauntty.verbose("[PASTE] sending async: \(data.count) bytes")
                    handler.sendToRemote(data)
                } else {
                    Logger.clauntty.warning("[PASTE] channelHandler nil (async)! Dropping \(data.count) bytes")
                }
            }
        }
    }

    nonisolated func rtachSessionDidReceiveIdle(_ session: RtachClient.RtachSession) {
        onMain {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): received idle notification from rtach")

            // Reset pre-fetch state if we receive idle while still in pre-fetch mode
            // This handles the case where server had no buffered data
            if self.isPrefetchingOnIdle {
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): pre-fetch had no data, resetting")
                self.isPrefetchingOnIdle = false
                // Re-pause since we're still inactive
                self.rtachProtocol.sendPause()
            }

            // Mark as waiting for input
            self.isWaitingForInput = true

            // Check for notification (same logic as inactivity detection)
            self.checkNotificationForWaitingInput()

            // Pre-fetch buffered data if we're paused
            // This ensures instant tab switch by getting data before user activates tab
            // Not on the idle that our own pre-fetch's repaint caused: anything skipped
            // is still flushed when the tab is shown
            if self.isPaused,
               self.lastPrefetchAt.map({ Date().timeIntervalSince($0) > self.prefetchCooldown }) ?? true {
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): pre-fetching buffered data on idle")
                self.lastPrefetchAt = Date()
                self.isPrefetchingOnIdle = true
                self.rtachProtocol.sendResume()
                // After receiving buffered data, we'll re-pause in processTerminalData
            }
        }
    }

    /// Make the remote program repaint by briefly changing the terminal size by one row
    private func forceRemoteRepaint() {
        // Before the view has sent a size (a pane's first attach after launch), the size
        // the channel opened at: the PTY's from this attach. Skipping the nudge then left
        // the pane blank.
        let size = lastWindowSize ?? (UInt16(clamping: attachSize.rows), UInt16(clamping: attachSize.columns))
        guard size.rows > 2 else {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): no size yet, skipping repaint nudge")
            return
        }
        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): repaint nudge \(size.columns)x\(size.rows)")
        // Its redraw one row short isn't shown: settling holds output until the redraw
        // at the real size
        awaitingRedraw = settling
        nudgeRestored = false
        sendWindowChange(rows: size.rows - 1, columns: size.columns)
        nudgedSize = (size.rows, size.columns)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.nudgedSize = nil
            guard let self, let current = self.lastWindowSize else { return }
            // Restore the latest real size (a resize may have happened in between)
            let rows = current.rows == size.rows - 1 && current.columns == size.columns ? size.rows : current.rows
            self.sendWindowChange(rows: rows, columns: current.columns)
            self.nudgeRestored = true
        }
    }

    nonisolated func rtachSession(_ session: RtachClient.RtachSession, didReceivePtySize size: RtachClient.PtySize) {
        onMain {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): pty size \(size.cols)x\(size.rows), yours=\(size.yours)")
            self.setPtySize(size)
        }
    }

    nonisolated func rtachSessionDidEnterFramedMode(_ session: RtachClient.RtachSession) {
        onMain {
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): entered framed mode")

            // Request scrollback after framed mode is established
            // This gets scrollback history for reconnects (rtach preserves it on server)
            self.requestScrollbackPage()

            // Check if we have a pending pause request
            if self.pendingPause {
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): applying deferred pause")
                self.pauseOutput()
            }

            // The master says when the screen is ready (and nudges full-screen programs
            // itself); with an older one, a program on the alternate screen gets the app's
            // nudge once rtach's first output shows it's there (processTerminalData)
            if self.settling, self.rtachProtocol.supportsReady {
                self.expectingReady = true
            }

            if self.pendingActiveClaim {
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): applying deferred active claim")
                self.claimActive(commandsOnly: self.pendingClaimCommandsOnly)
            } else if self.isActive {
                // Connecting isn't using it: a device typing there keeps the size
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): claiming active on connect")
                self.claimActive(commandsOnly: true)
            }
        }
    }
}

/// Which pane of its SessionGroup a session shows
struct PaneRef: Equatable {
    let paneId: String
    var groupTitle: String
}

// MARK: - Image Inbox

/// `clauntty show` leaves each image in ~/.clauntty/inbox/<id> on the remote host (rtach's
/// inbox.zig). The app deletes an entry once it has shown the image and checks the inbox
/// when it connects, so images sent while it was in the background still arrive.
enum ImageInbox {
    struct Entry: Equatable {
        let id: String
        let path: String
        /// The pane that sent it (rtach 2.21+, from inside an rtach session)
        var pane: String? = nil
    }

    /// Entries older than this are skipped (rtach's inbox.max_age_ms)
    static let maxAge: TimeInterval = 6 * 60 * 60

    /// Prints `<id>\t<path>\t<pane>` per entry (an entry is its path, then the pane on a
    /// second line). sh, not the login shell (which may be fish); the script has no
    /// single quotes
    static let listCommand = #"sh -c 'cd ~/.clauntty/inbox 2>/dev/null || exit 0; for f in [0-9]*; do [ -f "$f" ] && printf "%s\t%s\t%s\n" "$f" "$(sed -n 1p "$f")" "$(sed -n 2p "$f")"; done; exit 0'"#

    static func removeCommand(_ ids: [String]) -> String? {
        let valid = ids.filter(isValidId)
        guard !valid.isEmpty else { return nil }
        return "rm -f " + valid.map { "~/.clauntty/inbox/\($0)" }.joined(separator: " ")
    }

    /// `<unix ms>-<pid>-<index>`, all digits, so safe to put in a shell command
    static func isValidId(_ id: String) -> Bool {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    static func createdAt(_ id: String) -> Date? {
        guard isValidId(id), let ms = Int64(id.prefix { $0 != "-" }) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    /// Argument of an `image` command: `<id>;<pane>;<path>` from rtach 2.21+ (the pane
    /// empty outside rtach), `<id>;<path>` from 2.10+, or just `<path>`. The path is
    /// absolute, so after the id a `/` means there's no pane.
    static func parseImageArgument(_ arg: String) -> (path: String, id: String?, pane: String?) {
        let parts = arg.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, isValidId(String(parts[0])) else { return (arg, nil, nil) }
        let id = String(parts[0])
        let rest = parts[1]
        if rest.hasPrefix("/") { return (String(rest), id, nil) }
        let fields = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2 else { return (String(rest), id, nil) }
        return (String(fields[1]), id, fields[0].isEmpty ? nil : String(fields[0]))
    }

    static func parseList(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2, isValidId(String(fields[0])), !fields[1].isEmpty else { return nil }
            let pane = fields.count == 3 && !fields[2].isEmpty ? String(fields[2]) : nil
            return Entry(id: String(fields[0]), path: String(fields[1]), pane: pane)
        }
    }
}

// MARK: - Errors

enum SessionError: Error, LocalizedError, Equatable {
    case notConnected
    case fileTooLarge
    /// The host's answer to a review's reply script, when it wasn't one it gives
    case reviewReplyFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "SSH connection not established"
        case .fileTooLarge:
            return "File is too large"
        case .reviewReplyFailed(let output):
            return output.isEmpty ? "The host didn't take the comments" : "The host didn't take the comments: \(output.prefix(200))"
        }
    }
}
