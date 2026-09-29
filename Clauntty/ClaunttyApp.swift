import SwiftUI
import GhosttyKit
import UserNotifications
import os.log
#if canImport(TailscaleKit)
import TailscaleKit
#endif

/// Initializes GhosttyKit global state - must be called before any other GhosttyKit functions
enum GhosttyGlobal {
    private static var initialized = false

    static func initialize() {
        guard !initialized else { return }
        initialized = true

        StderrCapture.start()
        useDefaultCrashHandlers()

        Logger.clauntty.debugOnly("Initializing GhosttyKit global state...")
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if result != 0 {
            Logger.clauntty.error("ghostty_init failed with code: \(result)")
        } else {
            Logger.clauntty.debugOnly("GhosttyKit global state initialized successfully")
        }
    }

    /// TailscaleKit's Go runtime installs handlers for SIGSEGV/SIGBUS/SIGFPE. For a fault on a
    /// non-Go thread (e.g. main) with nothing to forward to, Go prints a fatal error and
    /// exit(2)s: the app vanishes with no crash report. Put them back to the system default
    /// so any crash leaves a normal iOS crash report. Go doesn't need them for normal
    /// operation (a nil deref inside Go code crashes instead of panicking).
    private static func useDefaultCrashHandlers() {
        #if canImport(TailscaleKit)
        // Go initializes on a background thread at load; any call into an exported Go
        // function waits for that to finish. (Unknown handle: returns EBADF, no-op.)
        var errBuf = [CChar](repeating: 0, count: 8)
        _ = tailscale_errmsg(-1, &errBuf, errBuf.count)
        for sig in [SIGSEGV, SIGBUS, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = SIG_DFL
            sigemptyset(&action.sa_mask)
            sigaction(sig, &action, nil)
        }
        #endif
    }
}

/// Preview modes for testing different UI states
enum PreviewMode: String {
    case none
    case terminal = "--preview-terminal"        // Show terminal view
    case terminalKeyboard = "--preview-keyboard" // Terminal with keyboard visible
    case connectionList = "--preview-connections" // Connection list
    case newConnection = "--preview-new-connection" // New connection form

    static func fromArgs() -> PreviewMode {
        for mode in [terminal, terminalKeyboard, connectionList, newConnection] {
            if CommandLine.arguments.contains(mode.rawValue) {
                return mode
            }
        }
        // Legacy support
        if CommandLine.arguments.contains("--test-terminal") {
            return .terminal
        }
        return .none
    }
}

/// Launch arguments for auto-connecting
enum LaunchArgs {
    /// Get connection name from --connect <name> argument
    static func autoConnectName() -> String? {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--connect"), idx + 1 < args.count {
            return args[idx + 1]
        }
        return nil
    }

    /// Tab specification for launch
    /// With persistence, numbers refer to persisted tab indices for the server
    enum TabSpec: Equatable {
        case existing(Int)     // Select existing persisted tab by index (0-based, for this server)
        case newSession        // Create new session (use "new" or "n")
        case port(Int)         // Port forward (prefix with :)
    }

    /// Get tab specs from --tabs argument
    /// Example: --tabs "0,1,new" or --tabs "0,:3000"
    /// Numbers select existing persisted tabs for the specified server
    static func tabSpecs() -> [TabSpec]? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--tabs"), idx + 1 < args.count else {
            return nil
        }

        let tabsArg = args[idx + 1]
        var specs: [TabSpec] = []

        for part in tabsArg.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix(":") {
                // Port forward
                if let port = Int(trimmed.dropFirst()) {
                    specs.append(.port(port))
                }
            } else if trimmed == "new" || trimmed == "n" {
                specs.append(.newSession)
            } else if let index = Int(trimmed) {
                specs.append(.existing(index))
            }
        }

        return specs.isEmpty ? nil : specs
    }

    enum SeedAuthMethod: Equatable {
        case password
        case sshKey(keyId: String)
    }

    struct SeedConnectionSpec: Equatable {
        let name: String
        let host: String
        let port: Int
        let username: String
        let authMethod: SeedAuthMethod
        let password: String?
        var useTailscale: Bool = false
    }

    enum SeedConnectionParseResult: Equatable {
        case none
        case invalid(String)
        case spec(SeedConnectionSpec)
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else {
            return nil
        }
        return args[idx + 1]
    }

    static func seedConnectionSpec() -> SeedConnectionParseResult {
        let args = CommandLine.arguments
        let hasSeedFlags = args.contains { $0.hasPrefix("--seed-") }
        if !hasSeedFlags {
            return .none
        }

        let name = value(after: "--seed-name", in: args)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = value(after: "--seed-host", in: args)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let username = value(after: "--seed-user", in: args)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let portRaw = value(after: "--seed-port", in: args)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "22"
        let authRaw = value(after: "--seed-auth", in: args)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "password"

        guard !name.isEmpty else {
            return .invalid("missing required --seed-name")
        }
        guard !host.isEmpty else {
            return .invalid("missing required --seed-host")
        }
        guard !username.isEmpty else {
            return .invalid("missing required --seed-user")
        }
        guard let port = Int(portRaw), (1...65535).contains(port) else {
            return .invalid("invalid --seed-port '\(portRaw)' (must be 1...65535)")
        }

        let authLower = authRaw.lowercased()
        let authMethod: SeedAuthMethod
        if authLower == "password" {
            authMethod = .password
        } else if authLower.hasPrefix("sshkey:") {
            let keyId = String(authRaw.dropFirst("sshkey:".count)).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !keyId.isEmpty else {
                return .invalid("invalid --seed-auth '\(authRaw)' (missing ssh key id)")
            }
            authMethod = .sshKey(keyId: keyId)
        } else if authLower.hasPrefix("ssh-key:") {
            let keyId = String(authRaw.dropFirst("ssh-key:".count)).trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !keyId.isEmpty else {
                return .invalid("invalid --seed-auth '\(authRaw)' (missing ssh key id)")
            }
            authMethod = .sshKey(keyId: keyId)
        } else {
            return .invalid("invalid --seed-auth '\(authRaw)' (use 'password' or 'sshKey:<keyId>')")
        }

        let passwordEnv = ProcessInfo.processInfo.environment["CLAUNTTY_SEED_PASSWORD"]?
            .trimmingCharacters(in: .newlines)
        let password = (passwordEnv?.isEmpty == false) ? passwordEnv : nil

        return .spec(
            SeedConnectionSpec(
                name: name,
                host: host,
                port: port,
                username: username,
                authMethod: authMethod,
                password: password,
                useTailscale: args.contains("--seed-tailscale")
            )
        )
    }
}

@main
struct ClaunttyApp: App {
    @StateObject private var connectionStore = ConnectionStore()
    @StateObject private var sshKeyStore = SSHKeyStore()
    @StateObject private var appState: AppState
    @StateObject private var ghosttyApp: GhosttyApp
    @StateObject private var sessionManager = SessionManager()

    static let previewMode = PreviewMode.fromArgs()

    init() {
        // Initialize GhosttyKit BEFORE creating GhosttyApp
        GhosttyGlobal.initialize()
        _ghosttyApp = StateObject(wrappedValue: GhosttyApp())

        let initialState = AppState()

        // Configure state based on preview mode
        switch Self.previewMode {
        case .terminal, .terminalKeyboard:
            initialState.connectionStatus = .connected
            Logger.clauntty.debugOnly("Preview mode: \(Self.previewMode.rawValue)")
        case .connectionList, .newConnection, .none:
            break
        }

        _appState = StateObject(wrappedValue: initialState)

        // Set up notification delegate
        UNUserNotificationCenter.current().delegate = NotificationManager.shared

        // Bring the embedded Tailscale node up early so tailnet connections don't wait on it
        TailscaleManager.shared.startIfLoggedIn()
    }

    var body: some Scene {
        WindowGroup {
            AppContentView(sessionManager: sessionManager)
                .environmentObject(connectionStore)
                .environmentObject(sshKeyStore)
                .environmentObject(appState)
                .environmentObject(ghosttyApp)
                .environmentObject(sessionManager)
                .onOpenURL { url in
                    handleURL(url)
                }
        }
    }

    /// Handle custom URL schemes for testing/debugging
    /// - clauntty://dump-text - Dump visible terminal text to /tmp/clauntty_dump.txt
    private func handleURL(_ url: URL) {
        Logger.clauntty.debugOnly("Received URL: \(url.absoluteString)")

        guard url.scheme == "clauntty" else {
            Logger.clauntty.warning("Unknown URL scheme: \(url.scheme ?? "nil")")
            return
        }

        switch url.host {
        case "dump-text":
            // ?scope=screen includes the scrollback, not just the viewport
            let scope = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "scope" })?.value
            dumpTerminalText(wholeScreen: scope == "screen")
        default:
            Logger.clauntty.warning("Unknown URL command: \(url.host ?? "nil")")
        }
    }

    /// Dump the active terminal's visible text to /tmp/clauntty_dump.txt
    private func dumpTerminalText(wholeScreen: Bool) {
        // Post notification to request text capture from active terminal
        NotificationCenter.default.post(name: .captureTerminalText, object: nil, userInfo: ["wholeScreen": wholeScreen])
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Request to capture terminal text (handled by TerminalView)
    static let captureTerminalText = Notification.Name("captureTerminalText")
    /// Request the active terminal to refresh its tab preview (handled by TerminalView)
    static let captureTabThumbnail = Notification.Name("captureTabThumbnail")
}

/// Wrapper view that handles scenePhase changes and notification taps
struct AppContentView: View {
    @Environment(\.scenePhase) var scenePhase
    @EnvironmentObject var connectionStore: ConnectionStore
    @ObservedObject var sessionManager: SessionManager

    /// Track if we've loaded persisted tabs (only do once)
    @State private var hasLoadedPersistedTabs = false

    var body: some View {
        ContentView()
            .onAppear {
                // Load persisted tabs on first appear
                if !hasLoadedPersistedTabs {
                    hasLoadedPersistedTabs = true
                    sessionManager.loadPersistedTabs(connectionStore: connectionStore)
                    sessionManager.loadPersistedWebTabs(connectionStore: connectionStore)
                    sessionManager.loadTabOrder()  // Load or migrate global tab order

                    // After Wi-Fi ↔ cellular open connections can be stuck on the old
                    // network. Experiment: leave the Tailscale node to follow the change
                    // itself (a dial timeout still restarts it)
                    NetworkMonitor.shared.onChange = { [sessionManager] in
                        sessionManager.checkConnections(reason: "network changed")
                    }
                    NetworkMonitor.shared.start()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
            .onReceive(NotificationCenter.default.publisher(for: .switchToSession)) { notification in
                handleSwitchToSession(notification)
            }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            let activeTitle = sessionManager.activeSession?.title.prefix(20) ?? "none"
            let activeId = sessionManager.activeSession?.id.uuidString.prefix(8) ?? "none"
            Logger.clauntty.debugOnly("APP_LIFECYCLE: BACKGROUNDING - activeSession='\(activeTitle)' [\(activeId)], totalSessions=\(self.sessionManager.sessions.count)")

            NotificationManager.shared.appIsBackgrounded = true
            // Request background time to continue processing SSH data
            // This gives us ~30 seconds to detect when Claude finishes
            NotificationManager.shared.startBackgroundTask()
            // Save current tab state (including active tab) before backgrounding
            sessionManager.savePersistence()
            // Pause ALL sessions when app goes to background (battery optimization)
            // rtach will buffer output and send idle notifications
            for session in sessionManager.sessions {
                session.pauseOutput()
            }
            Logger.clauntty.debugOnly("APP_LIFECYCLE: BACKGROUNDED - paused all \(self.sessionManager.sessions.count) sessions")
        case .active:
            let activeTitle = sessionManager.activeSession?.title.prefix(20) ?? "none"
            let activeId = sessionManager.activeSession?.id.uuidString.prefix(8) ?? "none"
            Logger.clauntty.debugOnly("APP_LIFECYCLE: FOREGROUNDING - activeSession='\(activeTitle)' [\(activeId)]")

            NotificationManager.shared.appIsBackgrounded = false
            NotificationManager.shared.clearAllPendingNotifications()
            NotificationManager.shared.endBackgroundTask()
            // Process any pending session switch from notification tap
            NotificationManager.shared.processPendingSessionSwitch()

            // Only reconnect/resume the ACTIVE session (lazy reconnect for others)
            if let activeSession = sessionManager.activeSession {
                let needsReconnect =
                    activeSession.state == .disconnected ||
                    (activeSession.state == .connected && !activeSession.hasAttachedChannel)

                if needsReconnect {
                    // Active session is disconnected (or lost its channel) - reconnect it
                    Logger.clauntty.debugOnly("APP_LIFECYCLE: reconnecting active session (state=\(activeSession.stateDescription), channel=\(activeSession.hasAttachedChannel ? "attached" : "missing"))")
                    Task {
                        try? await sessionManager.reconnect(session: activeSession)
                    }
                } else {
                    // Active session is connected - just resume output
                    Logger.clauntty.debugOnly("APP_LIFECYCLE: resuming connected active session")
                    activeSession.resumeOutput()
                    // It may have died while the app was suspended without closing
                    sessionManager.checkConnections(reason: "foreground")
                }
            } else {
                Logger.clauntty.debugOnly("APP_LIFECYCLE: no active session to resume")
            }
        case .inactive:
            // Transitional state, don't change background flag
            break
        @unknown default:
            break
        }
    }

    private func handleSwitchToSession(_ notification: Notification) {
        guard let sessionId = notification.userInfo?["sessionId"] as? UUID else { return }

        // Find and switch to the session
        if let session = sessionManager.sessions.first(where: { $0.id == sessionId }) {
            sessionManager.switchTo(session)
            Logger.clauntty.debugOnly("Switched to session from notification: \(sessionId.uuidString.prefix(8))")
        } else {
            Logger.clauntty.warning("Session not found for notification: \(sessionId.uuidString.prefix(8))")
        }
    }
}

/// Global app state management
@MainActor
class AppState: ObservableObject {
    enum ConnectionStatus {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    @Published var currentConnection: SavedConnection?
    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published private var inputSuppressionCount: Int = 0

    /// Active SSH connection (nil when disconnected)
    var sshConnection: SSHConnection?

    /// Whether terminal input (keyboard + accessory bar) should be suppressed
    var isInputSuppressed: Bool {
        inputSuppressionCount > 0
    }

    func beginInputSuppression() {
        inputSuppressionCount += 1
    }

    func endInputSuppression() {
        inputSuppressionCount = max(0, inputSuppressionCount - 1)
    }
}

/// Sends the process's stderr to Library/Caches/stderr.log (previous launch kept as
/// stderr.prev.log). On a device stderr is otherwise discarded, which loses fatal error
/// messages from the Go runtime (TailscaleKit) and Ghostty's logs.
enum StderrCapture {
    static func start() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let current = caches.appendingPathComponent("stderr.log")
        let previous = caches.appendingPathComponent("stderr.prev.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: current, to: previous)
        let fd = open(current.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        dup2(fd, STDERR_FILENO)
        close(fd)
        fputs("stderr capture started \(Date())\n", stderr)
    }
}
