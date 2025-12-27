import Foundation
import NIOCore
import NIOSSH
import os.log

/// Represents a single terminal session (one tab)
/// Each session has its own SSH channel and terminal surface
@MainActor
class Session: ObservableObject, Identifiable {
    // MARK: - Identity

    let id: UUID
    let connectionConfig: SavedConnection
    let createdAt: Date

    // MARK: - State

    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.connecting, .connecting),
                 (.connected, .connected):
                return true
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published var state: State = .disconnected

    /// Dynamic title set by terminal escape sequences (OSC 0/1/2)
    @Published var dynamicTitle: String? {
        didSet {
            Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): dynamicTitle set to '\(self.dynamicTitle ?? "nil")'")

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
            Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): marked as Claude session")
        }
    }

    /// Restore Claude session flag from UserDefaults
    private func restoreClaudeSessionFlag(rtachSessionId: String) {
        let key = Self.claudeSessionKey(connectionId: connectionConfig.id, rtachSessionId: rtachSessionId)
        _isClaudeSession = UserDefaults.standard.bool(forKey: key)
        if _isClaudeSession {
            Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): restored Claude session flag")
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
        Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): checking pending notification, isClaudeSession=\(self.isClaudeSession)")

        if NotificationManager.shared.shouldNotify(for: self) {
            Task {
                await NotificationManager.shared.scheduleInputReady(session: self)
            }
        }
    }

    // MARK: - Input Detection (Inactivity-based)

    /// Whether the terminal is waiting for user input (detected via inactivity timeout)
    @Published private(set) var isWaitingForInput: Bool = false

    /// Timer for detecting inactivity after output stops
    private var inactivityTimer: Timer?

    /// How long to wait after output stops before considering terminal idle (seconds)
    private let inactivityThreshold: TimeInterval = 1.5

    // MARK: - SSH Channel

    /// The SSH child channel for this session
    private(set) var sshChannel: Channel?

    /// Channel handler for data flow
    private(set) var channelHandler: SSHChannelHandler?

    /// Reference to parent connection (for sending data)
    weak var parentConnection: SSHConnection?

    /// Strong reference to SSH connection - each session owns its connection
    /// This keeps the connection alive for the lifetime of the session
    var sshConnection: SSHConnection?

    // MARK: - Terminal Size

    /// Initial terminal size to use when connecting (rows, columns)
    /// Set this before connecting for correct initial PTY size
    var initialTerminalSize: (rows: Int, columns: Int) = (30, 60)

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
                Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): restored title '\(savedTitle.prefix(30))'")
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

    // MARK: - Scrollback Request State

    /// State machine for scrollback request/response
    private enum ScrollbackState {
        case idle                          // Not requesting scrollback
        case waitingForHeader              // Sent request, waiting for 5-byte header
        case receivingData(remaining: Int) // Receiving scrollback data (legacy type=1)
        case waitingForPageMeta(dataLen: Int) // Waiting for 8-byte metadata (paginated type=3)
        case receivingPageData(remaining: Int) // Receiving paginated scrollback data
    }

    /// Current scrollback request state
    private var scrollbackState: ScrollbackState = .idle

    /// Buffer for accumulating scrollback response
    private var scrollbackResponseBuffer = Data()

    /// Buffer for partial header (if header arrives split across packets)
    private var headerBuffer = Data()

    /// Buffer for partial metadata (if metadata arrives split across packets)
    private var metaBuffer = Data()

    /// Whether we've already requested scrollback for this session
    private var scrollbackRequested = false

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

    // MARK: - Command Message State

    /// State machine for receiving command messages from rtach
    private enum CommandState {
        case idle                          // Not receiving a command
        case waitingForHeader              // Saw command type byte, waiting for rest of header
        case receivingData(remaining: Int) // Receiving command data
    }

    /// Current command receive state
    private var commandState: CommandState = .idle

    /// Buffer for accumulating command header
    private var commandHeaderBuffer = Data()

    /// Buffer for accumulating command data
    private var commandDataBuffer = Data()

    // MARK: - Initialization

    init(connectionConfig: SavedConnection) {
        self.id = UUID()
        self.connectionConfig = connectionConfig
        self.createdAt = Date()
    }

    // MARK: - Channel Management

    /// Attach an SSH channel to this session
    func attach(channel: Channel, handler: SSHChannelHandler, connection: SSHConnection) {
        self.sshChannel = channel
        self.channelHandler = handler
        self.parentConnection = connection
        self.state = .connected
        onStateChanged?(.connected)
        Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): channel attached, channelHandler is set")
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
        Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): channel detached")
    }

    // MARK: - Data Flow

    /// Handle data received from SSH
    func handleDataReceived(_ data: Data) {
        // If we're receiving a scrollback response, handle it separately
        if case .idle = scrollbackState {
            // Normal data flow
            handleNormalData(data)
        } else {
            // Scrollback response handling
            handleScrollbackResponse(data)
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
                Logger.clauntty.info("[LOAD] Showing loading indicator (bytes in window: \(bytesInWindow))")
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
                Logger.clauntty.info("[LOAD] Hiding loading indicator (bytes in window: \(bytesInWindow))")
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

    /// Handle normal terminal data
    private func handleNormalData(_ data: Data) {
        var remainingData = data

        // Check for command messages from rtach (type byte = 2)
        // These can arrive mixed with terminal data
        while !remainingData.isEmpty {
            switch commandState {
            case .idle:
                // Check if this looks like a command message (type = 2)
                if remainingData[0] == 2 {
                    // Start accumulating command header
                    commandState = .waitingForHeader
                    commandHeaderBuffer.removeAll()
                    commandHeaderBuffer.append(remainingData[0])
                    remainingData = remainingData.dropFirst(1)
                } else {
                    // Normal terminal data - process and return
                    processTerminalData(remainingData)
                    return
                }

            case .waitingForHeader:
                // Accumulate bytes until we have 5 bytes for the header
                let headerSize = 5  // 1 byte type + 4 bytes length
                let needed = headerSize - commandHeaderBuffer.count
                let available = min(needed, remainingData.count)

                commandHeaderBuffer.append(remainingData.prefix(available))
                remainingData = remainingData.dropFirst(available)

                if commandHeaderBuffer.count >= headerSize {
                    // Parse header: [type: 1 byte][length: 4 bytes little-endian]
                    let type = commandHeaderBuffer[0]
                    let length = commandHeaderBuffer.withUnsafeBytes { ptr -> UInt32 in
                        ptr.loadUnaligned(fromByteOffset: 1, as: UInt32.self)
                    }

                    if type == 2 && length > 0 && length < 1024 {
                        // Valid command header - receive data
                        commandState = .receivingData(remaining: Int(length))
                        commandDataBuffer.removeAll(keepingCapacity: true)
                    } else if type == 2 && length == 0 {
                        // Empty command (shouldn't happen, but handle it)
                        commandState = .idle
                        commandHeaderBuffer.removeAll()
                    } else {
                        // Not a valid command - treat header bytes as terminal data
                        Logger.clauntty.debug("Invalid command header, forwarding as terminal data")
                        processTerminalData(commandHeaderBuffer)
                        commandState = .idle
                        commandHeaderBuffer.removeAll()
                    }
                }

            case .receivingData(let remaining):
                let toRead = min(remaining, remainingData.count)
                commandDataBuffer.append(remainingData.prefix(toRead))
                remainingData = remainingData.dropFirst(toRead)

                let newRemaining = remaining - toRead
                if newRemaining <= 0 {
                    // Complete command - dispatch it
                    if let commandString = String(data: commandDataBuffer, encoding: .utf8) {
                        Logger.clauntty.info("Received command from rtach: \(commandString)")
                        handleRtachCommand(commandString)
                    }
                    commandState = .idle
                    commandHeaderBuffer.removeAll()
                    commandDataBuffer.removeAll()
                } else {
                    commandState = .receivingData(remaining: newRemaining)
                }
            }
        }
    }

    /// Process actual terminal data (after command detection)
    private func processTerminalData(_ data: Data) {
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
    }

    /// Handle a command received from rtach via command pipe
    /// Format: "command;arg1;arg2..."
    private func handleRtachCommand(_ command: String) {
        let parts = command.split(separator: ";", maxSplits: 1)
        guard let cmd = parts.first else { return }

        switch cmd {
        case "open":
            if parts.count > 1, let port = Int(parts[1]) {
                Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): rtach command open port \(port)")
                onOpenTabRequested?(port)
            }
        case "forward":
            if parts.count > 1, let port = Int(parts[1]) {
                Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): rtach command forward port \(port)")
                onPortForwardRequested?(port)
            }
        default:
            Logger.clauntty.debug("Session \(self.id.uuidString.prefix(8)): unknown rtach command: \(cmd)")
        }
    }

    /// Handle scrollback response data (when in scrollback receive mode)
    private func handleScrollbackResponse(_ data: Data) {
        var remainingData = data
        var processedAny = false

        while !remainingData.isEmpty {
            switch scrollbackState {
            case .idle:
                // Shouldn't happen, but if we get here, forward remaining data normally
                if processedAny {
                    handleNormalData(remainingData)
                }
                return

            case .waitingForHeader:
                // Accumulate bytes until we have 5 bytes for the header
                let headerSize = 5  // 1 byte type + 4 bytes length
                let needed = headerSize - headerBuffer.count
                let available = min(needed, remainingData.count)

                headerBuffer.append(remainingData.prefix(available))
                remainingData = remainingData.dropFirst(available)
                processedAny = true

                if headerBuffer.count >= headerSize {
                    // Parse header: [type: 1 byte][length: 4 bytes little-endian]
                    let type = headerBuffer[0]
                    // Use loadUnaligned since the UInt32 is at offset 1 (not 4-byte aligned)
                    let length = headerBuffer.withUnsafeBytes { ptr -> UInt32 in
                        ptr.loadUnaligned(fromByteOffset: 1, as: UInt32.self)
                    }

                    Logger.clauntty.info("Scrollback header: type=\(type), length=\(length)")

                    if type == 1 && length > 0 {
                        // Type 1 = legacy scrollback, transition to receiving data
                        scrollbackState = .receivingData(remaining: Int(length))
                        scrollbackResponseBuffer.removeAll(keepingCapacity: true)
                    } else if type == 3 && length > 8 {
                        // Type 3 = paginated scrollback_page, need to read metadata first
                        // length includes 8 bytes of metadata + data
                        scrollbackState = .waitingForPageMeta(dataLen: Int(length) - 8)
                        metaBuffer.removeAll()
                    } else if type == 3 && length == 8 {
                        // Type 3 with only metadata (no data) - empty page
                        scrollbackState = .waitingForPageMeta(dataLen: 0)
                        metaBuffer.removeAll()
                    } else if length == 0 {
                        // Empty scrollback response
                        Logger.clauntty.info("Scrollback response: empty (all data was in initial send)")
                        scrollbackState = .idle
                        scrollbackPageRequestPending = false
                        scrollbackFullyLoaded = true
                    } else {
                        // Unknown type, abort
                        Logger.clauntty.warning("Unknown scrollback response type: \(type)")
                        scrollbackState = .idle
                        scrollbackPageRequestPending = false
                    }
                    headerBuffer.removeAll()
                }

            case .receivingData(let remaining):
                // Legacy scrollback response (type=1)
                let toRead = min(remaining, remainingData.count)
                scrollbackResponseBuffer.append(remainingData.prefix(toRead))
                remainingData = remainingData.dropFirst(toRead)
                processedAny = true

                let newRemaining = remaining - toRead
                if newRemaining <= 0 {
                    // Complete! Deliver the scrollback
                    let byteCount = self.scrollbackResponseBuffer.count
                    Logger.clauntty.info("Scrollback response complete: \(byteCount) bytes")
                    let scrollbackData = self.scrollbackResponseBuffer
                    self.scrollbackResponseBuffer.removeAll()
                    self.scrollbackState = .idle

                    // Deliver to callback
                    self.onScrollbackReceived?(scrollbackData)
                } else {
                    self.scrollbackState = .receivingData(remaining: newRemaining)
                }

            case .waitingForPageMeta(let dataLen):
                // Accumulate 8 bytes for metadata
                let metaSize = 8  // total_len (4) + offset (4)
                let needed = metaSize - metaBuffer.count
                let available = min(needed, remainingData.count)

                metaBuffer.append(remainingData.prefix(available))
                remainingData = remainingData.dropFirst(available)
                processedAny = true

                if metaBuffer.count >= metaSize {
                    // Parse metadata: [total_len: 4 bytes LE][offset: 4 bytes LE]
                    let totalLen = metaBuffer.withUnsafeBytes { ptr -> UInt32 in
                        ptr.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
                    }
                    let offset = metaBuffer.withUnsafeBytes { ptr -> UInt32 in
                        ptr.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                    }

                    Logger.clauntty.info("Scrollback page meta: total=\(totalLen), offset=\(offset), dataLen=\(dataLen)")

                    scrollbackTotalSize = Int(totalLen)

                    if dataLen > 0 {
                        scrollbackState = .receivingPageData(remaining: dataLen)
                        scrollbackResponseBuffer.removeAll(keepingCapacity: true)
                    } else {
                        // Empty page - we've loaded everything
                        scrollbackState = .idle
                        scrollbackPageRequestPending = false
                        scrollbackFullyLoaded = true
                        Logger.clauntty.info("Scrollback fully loaded (empty page)")
                    }
                    metaBuffer.removeAll()
                }

            case .receivingPageData(let remaining):
                // Paginated scrollback response (type=3)
                let toRead = min(remaining, remainingData.count)
                scrollbackResponseBuffer.append(remainingData.prefix(toRead))
                remainingData = remainingData.dropFirst(toRead)
                processedAny = true

                let newRemaining = remaining - toRead
                if newRemaining <= 0 {
                    // Page complete!
                    let byteCount = self.scrollbackResponseBuffer.count
                    Logger.clauntty.info("Scrollback page complete: \(byteCount) bytes")
                    let scrollbackData = self.scrollbackResponseBuffer
                    self.scrollbackResponseBuffer.removeAll()
                    self.scrollbackState = .idle
                    self.scrollbackPageRequestPending = false

                    // Update offset
                    self.scrollbackLoadedOffset += byteCount

                    // Check if fully loaded
                    if let total = self.scrollbackTotalSize, self.scrollbackLoadedOffset >= total {
                        self.scrollbackFullyLoaded = true
                        Logger.clauntty.info("Scrollback fully loaded: \(total) bytes total")
                    }

                    // Deliver to callback
                    self.onScrollbackReceived?(scrollbackData)
                } else {
                    self.scrollbackState = .receivingPageData(remaining: newRemaining)
                }
            }
        }
    }

    // MARK: - Inactivity Detection

    /// Reset the inactivity timer when output is received
    private func resetInactivityTimer() {
        inactivityTimer?.invalidate()

        // If we were waiting for input, we're not anymore (got output)
        if isWaitingForInput {
            isWaitingForInput = false
        }

        // Schedule timer to check for idle state
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
            Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): waiting for input")
            checkNotificationForWaitingInput()
        }
    }

    /// Check if we should send a notification when waiting for input
    private func checkNotificationForWaitingInput() {
        // If we have title info, check notification immediately
        if dynamicTitle != nil || _isClaudeSession {
            Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): checking notification, isClaudeSession=\(self.isClaudeSession)")
            if NotificationManager.shared.shouldNotify(for: self) {
                Task {
                    await NotificationManager.shared.scheduleInputReady(session: self)
                }
            }
        } else {
            // No title yet - wait for title to be set
            pendingNotificationCheck = true
            Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): pending notification check (waiting for title)")
        }
    }

    /// Send data to remote (keyboard input)
    func sendData(_ data: Data) {
        let hasHandler = self.channelHandler != nil
        Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): sendData called with \(data.count) bytes, channelHandler=\(hasHandler ? "set" : "nil")")
        if channelHandler == nil {
            Logger.clauntty.error("Session \(self.id.uuidString.prefix(8)): sendData called but channelHandler is nil!")
        }
        channelHandler?.sendToRemote(data)
    }

    /// Send window size change
    func sendWindowChange(rows: UInt16, columns: UInt16) {
        guard let channel = sshChannel else {
            Logger.clauntty.warning("Session \(self.id.uuidString.prefix(8)): cannot send window change, no channel")
            return
        }

        let windowChange = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: Int(columns),
            terminalRowHeight: Int(rows),
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )

        channel.eventLoop.execute {
            channel.triggerUserOutboundEvent(windowChange, promise: nil)
        }
        Logger.clauntty.debug("Session \(self.id.uuidString.prefix(8)): window change \(columns)x\(rows)")
    }

    // MARK: - Scrollback Request

    /// Request a page of old scrollback from rtach (paginated)
    /// This uses the new request_scrollback_page message type (6) which returns
    /// scrollback in chunks to prevent iOS watchdog kills.
    func requestScrollbackPage() {
        guard !scrollbackFullyLoaded else {
            Logger.clauntty.debug("Session \(self.id.uuidString.prefix(8)): scrollback already fully loaded")
            return
        }

        guard !scrollbackPageRequestPending else {
            Logger.clauntty.debug("Session \(self.id.uuidString.prefix(8)): scrollback page request already pending")
            return
        }

        guard case .idle = scrollbackState else {
            Logger.clauntty.debug("Session \(self.id.uuidString.prefix(8)): scrollback state not idle")
            return
        }

        guard channelHandler != nil else {
            Logger.clauntty.warning("Session \(self.id.uuidString.prefix(8)): cannot request scrollback, no channel")
            return
        }

        scrollbackPageRequestPending = true
        scrollbackState = .waitingForHeader
        headerBuffer.removeAll()

        // Build request: [type: 1 byte = 6][len: 1 byte = 8][offset: 4 bytes LE][limit: 4 bytes LE]
        var packet = Data()
        packet.append(6)  // MessageType.request_scrollback_page = 6
        packet.append(8)  // Payload length = 8 bytes

        var offset = UInt32(scrollbackLoadedOffset).littleEndian
        var limit = UInt32(scrollbackPageSize).littleEndian
        withUnsafeBytes(of: &offset) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: &limit) { packet.append(contentsOf: $0) }

        channelHandler?.sendToRemote(packet)

        Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): requesting scrollback page offset=\(self.scrollbackLoadedOffset) limit=\(self.scrollbackPageSize)")
    }

    /// Load more scrollback if user is scrolling near the top and more is available
    /// Call this from TerminalView when user scrolls near the top of scrollback
    func loadMoreScrollbackIfNeeded() {
        requestScrollbackPage()
    }

    /// Legacy: Request all old scrollback at once (deprecated - use requestScrollbackPage instead)
    /// This can cause watchdog kills on iOS with large scrollback buffers
    @available(*, deprecated, message: "Use requestScrollbackPage() for paginated loading")
    func requestScrollback() {
        guard !scrollbackRequested else {
            Logger.clauntty.debug("Session \(self.id.uuidString.prefix(8)): scrollback already requested")
            return
        }

        guard channelHandler != nil else {
            Logger.clauntty.warning("Session \(self.id.uuidString.prefix(8)): cannot request scrollback, no channel")
            return
        }

        scrollbackRequested = true
        scrollbackState = .waitingForHeader
        headerBuffer.removeAll()

        // Send rtach request_scrollback packet (legacy)
        // Format: [type: 1 byte = 5][length: 1 byte = 0]
        let packet = Data([5, 0])  // MessageType.request_scrollback = 5, length = 0
        channelHandler?.sendToRemote(packet)

        Logger.clauntty.info("Session \(self.id.uuidString.prefix(8)): requested old scrollback from rtach (legacy)")
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
