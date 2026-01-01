import SwiftUI
import GhosttyKit
import UserNotifications
import os.log

/// Initializes GhosttyKit global state - must be called before any other GhosttyKit functions
enum GhosttyGlobal {
    private static var initialized = false

    static func initialize() {
        guard !initialized else { return }
        initialized = true

        Logger.clauntty.info("Initializing GhosttyKit global state...")
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if result != 0 {
            Logger.clauntty.error("ghostty_init failed with code: \(result)")
        } else {
            Logger.clauntty.info("GhosttyKit global state initialized successfully")
        }
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
            Logger.clauntty.info("Preview mode: \(Self.previewMode.rawValue)")
        case .connectionList, .newConnection, .none:
            break
        }

        _appState = StateObject(wrappedValue: initialState)

        // Set up notification delegate
        UNUserNotificationCenter.current().delegate = NotificationManager.shared
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
        Logger.clauntty.info("Received URL: \(url.absoluteString)")

        guard url.scheme == "clauntty" else {
            Logger.clauntty.warning("Unknown URL scheme: \(url.scheme ?? "nil")")
            return
        }

        switch url.host {
        case "dump-text":
            dumpTerminalText()
        default:
            Logger.clauntty.warning("Unknown URL command: \(url.host ?? "nil")")
        }
    }

    /// Dump the active terminal's visible text to /tmp/clauntty_dump.txt
    private func dumpTerminalText() {
        // Post notification to request text capture from active terminal
        NotificationCenter.default.post(name: .captureTerminalText, object: nil)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Request to capture terminal text (handled by TerminalView)
    static let captureTerminalText = Notification.Name("captureTerminalText")
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
            Logger.clauntty.info("App backgrounded: paused all \(self.sessionManager.sessions.count) sessions")
        case .active:
            NotificationManager.shared.appIsBackgrounded = false
            NotificationManager.shared.clearAllPendingNotifications()
            NotificationManager.shared.endBackgroundTask()
            // Process any pending session switch from notification tap
            NotificationManager.shared.processPendingSessionSwitch()

            // Only reconnect/resume the ACTIVE session (lazy reconnect for others)
            if let activeSession = sessionManager.activeSession {
                if activeSession.state == .disconnected {
                    // Active session is disconnected - reconnect it
                    Logger.clauntty.info("App activated: reconnecting active session \(activeSession.id.uuidString.prefix(8))")
                    Task {
                        try? await sessionManager.reconnect(session: activeSession)
                    }
                } else {
                    // Active session is connected - just resume output
                    activeSession.resumeOutput()
                    Logger.clauntty.info("App activated: resumed active session \(activeSession.id.uuidString.prefix(8))")
                }
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
            Logger.clauntty.info("Switched to session from notification: \(sessionId.uuidString.prefix(8))")
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

    /// Active SSH connection (nil when disconnected)
    var sshConnection: SSHConnection?
}
