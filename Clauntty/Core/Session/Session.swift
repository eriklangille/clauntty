import Foundation
import NIOCore
import NIOSSH
import os.log
import RtachClient
import UIKit

/// Represents a single terminal session (one tab)
/// Each session has its own SSH channel and terminal surface
@MainActor
class Session: ObservableObject, Identifiable {
    // MARK: - Identity

    let id: UUID
    var connectionConfig: SavedConnection
    let createdAt: Date

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

    /// Cached screenshot for tab selector (captured when switching away)
    var cachedScreenshot: UIImage?

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

        if NotificationManager.shared.shouldNotify(for: self) {
            Task {
                await NotificationManager.shared.scheduleInputReady(session: self)
            }
        }
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

    /// Reference to parent connection (for sending data)
    weak var parentConnection: SSHConnection?

    /// Strong reference to SSH connection - each session owns its connection
    /// This keeps the connection alive for the lifetime of the session
    var sshConnection: SSHConnection?

    // MARK: - Terminal Size

    /// Initial terminal size to use when connecting (rows, columns)
    /// Set this before connecting for correct initial PTY size
    var initialTerminalSize: (rows: Int, columns: Int) = (30, 60)

    // MARK: - Power Management

    /// Whether output streaming is paused (tab is inactive/backgrounded)
    private(set) var isPaused: Bool = false

    /// Whether this session's tab is currently active/foreground
    private(set) var isActive: Bool = false

    /// Whether we're pre-fetching after idle (need to re-pause after receiving data)
    private var isPrefetchingOnIdle: Bool = false

    /// Whether we want to pause but are waiting for framed mode to be established
    private var pendingPause: Bool = false

    /// Whether we want to claim active but are waiting for framed mode
    private var pendingActiveClaim: Bool = false

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

    /// Called when session state changes
    var onStateChanged: ((State) -> Void)?

    /// Called when old scrollback is received (to prepend to terminal)
    var onScrollbackReceived: ((Data) -> Void)?

    /// Called when a port forward is requested via OSC 777
    var onPortForwardRequested: ((Int) -> Void)?

    /// Called when a web tab should be opened via OSC 777
    var onOpenTabRequested: ((Int) -> Void)?

    /// Called when session needs reconnection (detected nil channel on send attempt)
    var onNeedsReconnect: (() -> Void)?

    /// Called when a URL should be opened in the device browser
    var onOpenBrowserRequested: ((String) -> Void)?

    // MARK: - rtach Protocol Session

    /// State machine for rtach protocol (raw/framed mode handling)
    private let rtachProtocol = RtachClient.RtachSession()

    /// Debug counters for tracking data flow
    private var totalBytesReceived = 0
    private var totalBytesToTerminal = 0

    // MARK: - Paginated Scrollback State

    /// Page size for scrollback requests (16KB)
    private let scrollbackPageSize = 16 * 1024

    /// Current offset into scrollback (0 = oldest data)
    private var scrollbackLoadedOffset: Int = 0

    /// Total scrollback size (set when first page received)
    private var scrollbackTotalSize: Int?

    /// Whether we've finished loading all scrollback
    private var scrollbackFullyLoaded: Bool = false

    /// Whether a scrollback page request is currently in flight
    private var scrollbackPageRequestPending: Bool = false

    // MARK: - Initialization

    init(connectionConfig: SavedConnection, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.connectionConfig = connectionConfig
        self.createdAt = createdAt
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
        scrollbackLoadedOffset = 0
        scrollbackTotalSize = nil
        scrollbackFullyLoaded = false
        scrollbackPageRequestPending = false

        // Set up rtach protocol delegate and mark as connected
        rtachProtocol.expectsRtach = expectsRtach
        rtachProtocol.delegate = self
        rtachProtocol.connect()

        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): channel attached, channelHandler is set")
    }

    /// Detach the channel (on disconnect)
    func detach() {
        // Clean up inactivity timer
        inactivityTimer?.invalidate()
        inactivityTimer = nil

        // Disconnect our SSH connection
        sshConnection?.disconnect()
        sshConnection = nil
        sshChannel = nil
        channelHandler = nil
        parentConnection = nil
        state = .disconnected
        onStateChanged?(.disconnected)

        // Reset rtach protocol state for reconnection
        rtachProtocol.reset()

        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): channel detached")
    }

    // MARK: - Data Flow

    /// Handle data received from SSH
    /// Delegates to RtachSession for protocol handling (raw vs framed mode)
    func handleDataReceived(_ data: Data) {
        self.totalBytesReceived += data.count
        // Verbose: expensive hex dump of incoming data
        Logger.clauntty.verbose("[FRAME] received \(data.count) bytes (total=\(self.totalBytesReceived)), state=\(String(describing: self.rtachProtocol.state)), first32=\(data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " "))")

        // Delegate to RtachSession for protocol handling
        rtachProtocol.processIncomingData(data)
    }

    /// Handle SSH channel becoming inactive (connection lost)
    /// This is called when the underlying TCP connection dies (e.g., after background timeout)
    func handleChannelInactive() {
        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): handling channel inactive")

        // Clear channel references
        parentConnection = nil
        sshConnection = nil
        sshChannel = nil
        channelHandler = nil

        // Reset protocol/transport state so reconnect starts cleanly
        rtachProtocol.reset()
        usesRtach = false
        isPaused = false
        isPrefetchingOnIdle = false
        pendingPause = false
        pendingActiveClaim = false
        isWaitingForInput = false

        // Update state to disconnected
        state = .disconnected
        onStateChanged?(state)
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

    /// Process terminal data (forward to terminal and track scrollback)
    private func processTerminalData(_ data: Data) {
        let sessionTitle = self.title.prefix(15)
        let hasCallback = self.onDataReceived != nil
        Logger.clauntty.verbose("DATA_FLOW[\(self.id.uuidString.prefix(8))] '\(sessionTitle)': \(data.count) bytes, callback=\(hasCallback)")
        totalBytesToTerminal += data.count

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
            if parts.count > 1, let port = Int(parts[1]) {
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): rtach command open port \(port)")
                onOpenTabRequested?(port)
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
            if NotificationManager.shared.shouldNotify(for: self) {
                Task {
                    await NotificationManager.shared.scheduleInputReady(session: self)
                }
            }
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
            if state != .disconnected {
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): detected disconnection, triggering reconnect")
                handleChannelInactive()
                onNeedsReconnect?()
            }
            return
        }
        // Route through rtach protocol - handles raw vs framed mode
        rtachProtocol.sendKeyboardInput(data)
    }

    /// Send window size change
    func sendWindowChange(rows: UInt16, columns: UInt16) {
        Logger.clauntty.debugOnly("TAB_SWITCH: sendWindowChange called \(columns)x\(rows)")
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

    /// Upload an image to the remote server and paste the file path
    /// Used for pasting images from clipboard into terminal (e.g., for Claude Code)
    func uploadImageAndPaste(_ image: UIImage) {
        guard let connection = sshConnection else {
            Logger.clauntty.error("Session \(self.id.uuidString.prefix(8)): cannot upload image, no SSH connection")
            return
        }

        // Convert image to PNG data
        guard let imageData = image.pngData() else {
            Logger.clauntty.error("Session \(self.id.uuidString.prefix(8)): failed to convert image to PNG")
            return
        }

        // Generate unique filename
        let filename = "clauntty-paste-\(UUID().uuidString.prefix(8)).png"
        let remotePath = "/tmp/\(filename)"

        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): uploading image (\(imageData.count) bytes) to \(remotePath)")

        // Upload async and paste path when done
        Task {
            do {
                try await connection.executeWithStdin("cat > \(remotePath)", stdinData: imageData)
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): image uploaded, pasting path")

                // Paste the file path to the terminal
                if let pathData = remotePath.data(using: .utf8) {
                    sendData(pathData)
                }
            } catch {
                Logger.clauntty.error("Session \(self.id.uuidString.prefix(8)): failed to upload image: \(error)")
            }
        }
    }

    // MARK: - Power Management

    /// Pause terminal output streaming (for inactive tabs/backgrounded app)
    /// rtach will buffer output locally and send idle notifications
    func pauseOutput() {
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
        rtachProtocol.sendResume()
        // Also request a full redraw from rtach to force TUI apps to repaint
        rtachProtocol.requestRedraw()
        Logger.clauntty.debugOnly("TAB_SWITCH[\(self.id.uuidString.prefix(8))]: resumeOutput SENT resume + redraw to rtach")
    }

    /// Claim active client for window size and command routing
    func claimActive() {
        guard rtachSessionId != nil else { return }
        guard rtachProtocol.isFramedMode else {
            pendingActiveClaim = true
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): claimActive deferred (not framed mode yet)")
            return
        }

        pendingActiveClaim = false
        rtachProtocol.sendClaimActive()
        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): claimActive sent")
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

        scrollbackPageRequestPending = true

        // Send via rtach protocol
        rtachProtocol.requestScrollbackPage(offset: UInt32(scrollbackLoadedOffset), limit: UInt32(scrollbackPageSize))

        Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): requesting scrollback page offset=\(self.scrollbackLoadedOffset) limit=\(self.scrollbackPageSize)")
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
    nonisolated func rtachSession(_ session: RtachClient.RtachSession, didReceiveTerminalData data: Data) {
        Task { @MainActor in
            self.processTerminalData(data)
        }
    }

    nonisolated func rtachSession(_ session: RtachClient.RtachSession, didReceiveScrollback data: Data) {
        Task { @MainActor in
            Logger.clauntty.debugOnly("Scrollback response complete: \(data.count) bytes")
            self.scrollbackPageRequestPending = false
            self.onScrollbackReceived?(data)
        }
    }

    nonisolated func rtachSession(_ session: RtachClient.RtachSession, didReceiveScrollbackPage meta: RtachClient.ScrollbackPageMeta, data: Data) {
        Task { @MainActor in
            Logger.clauntty.debugOnly("Scrollback page complete: \(data.count) bytes, total=\(meta.totalLength), offset=\(meta.offset)")

            self.scrollbackTotalSize = Int(meta.totalLength)
            self.scrollbackPageRequestPending = false
            self.scrollbackLoadedOffset += data.count

            // Check if fully loaded
            if self.scrollbackLoadedOffset >= Int(meta.totalLength) {
                self.scrollbackFullyLoaded = true
                Logger.clauntty.debugOnly("Scrollback fully loaded: \(meta.totalLength) bytes total")
            }

            self.onScrollbackReceived?(data)
        }
    }

    nonisolated func rtachSession(_ session: RtachClient.RtachSession, didReceiveCommand data: Data) {
        Task { @MainActor in
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
        Task { @MainActor in
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
            if self.isPaused {
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): pre-fetching buffered data on idle")
                self.isPrefetchingOnIdle = true
                self.rtachProtocol.sendResume()
                // After receiving buffered data, we'll re-pause in processTerminalData
            }
        }
    }

    nonisolated func rtachSessionDidEnterFramedMode(_ session: RtachClient.RtachSession) {
        Task { @MainActor in
            Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): entered framed mode")

            // Request scrollback after framed mode is established
            // This gets scrollback history for reconnects (rtach preserves it on server)
            self.requestScrollbackPage()

            // Check if we have a pending pause request
            if self.pendingPause {
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): applying deferred pause")
                self.pauseOutput()
            }

            if self.pendingActiveClaim {
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): applying deferred active claim")
                self.claimActive()
            } else if self.isActive {
                Logger.clauntty.debugOnly("Session \(self.id.uuidString.prefix(8)): claiming active on connect")
                self.claimActive()
            }
        }
    }
}
