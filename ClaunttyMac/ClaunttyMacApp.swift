import GhosttyKit
import SwiftUI

@main
struct ClaunttyMacApp: App {
    @StateObject private var ghostty: MacGhosttyApp

    init() {
        // Ghostty's global state (allocator, logging) must exist before any config or app.
        if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
            macLog.error("ghostty_init failed")
        }
        _ghostty = StateObject(wrappedValue: MacGhosttyApp())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ghostty)
                .frame(minWidth: 480, minHeight: 300)
        }
    }
}
