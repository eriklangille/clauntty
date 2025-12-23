import SwiftUI
import GhosttyKit
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

@main
struct ClaunttyApp: App {
    @StateObject private var connectionStore = ConnectionStore()
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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionStore)
                .environmentObject(appState)
                .environmentObject(ghosttyApp)
                .environmentObject(sessionManager)
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
