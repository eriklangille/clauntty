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

@main
struct ClaunttyApp: App {
    @StateObject private var connectionStore = ConnectionStore()
    @StateObject private var appState: AppState
    @StateObject private var ghosttyApp: GhosttyApp

    init() {
        // Initialize GhosttyKit BEFORE creating GhosttyApp
        GhosttyGlobal.initialize()
        _ghosttyApp = StateObject(wrappedValue: GhosttyApp())

        // Check for test mode launch argument
        let testTerminal = CommandLine.arguments.contains("--test-terminal")
        let initialState = AppState()
        if testTerminal {
            initialState.connectionStatus = .connected
            Logger.clauntty.info("Test mode: auto-navigating to terminal view")
        }
        _appState = StateObject(wrappedValue: initialState)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionStore)
                .environmentObject(appState)
                .environmentObject(ghosttyApp)
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
