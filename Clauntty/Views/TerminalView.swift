import SwiftUI
import os.log

/// Terminal background color matching Ghostty's default theme (#282C34)
/// From ghostty/src/config/Config.zig: background: Color = .{ .r = 0x28, .g = 0x2C, .b = 0x34 }
private let terminalBackgroundColor = Color(red: 40/255.0, green: 44/255.0, blue: 52/255.0) // #282C34

/// Wrapper class to hold terminal surface reference (works with SwiftUI @StateObject)
@MainActor
class TerminalSurfaceHolder: ObservableObject {
    @Published var surface: TerminalSurfaceView?
}

struct TerminalView: View {
    @EnvironmentObject var ghosttyApp: GhosttyApp
    @EnvironmentObject var sessionManager: SessionManager

    /// The session this terminal view is displaying
    @ObservedObject var session: Session

    /// Reference to the terminal surface view for SSH data flow (wrapped in class for SwiftUI)
    @StateObject private var surfaceHolder = TerminalSurfaceHolder()

    /// Whether this terminal is currently the active tab
    private var isActive: Bool {
        sessionManager.activeTab == .terminal(session.id)
    }

    var body: some View {
        ZStack {
            // Show terminal surface based on GhosttyApp readiness
            switch ghosttyApp.readiness {
            case .loading:
                terminalBackgroundColor
                    .ignoresSafeArea()
                VStack {
                    ProgressView()
                        .tint(.white)
                    Text("Initializing terminal...")
                        .foregroundColor(.gray)
                        .padding(.top)
                }

            case .error:
                terminalBackgroundColor
                    .ignoresSafeArea()
                VStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.largeTitle)
                    Text("Failed to initialize terminal")
                        .foregroundColor(.white)
                        .padding(.top)
                }

            case .ready:
                // Terminal background extends under notch in landscape
                terminalBackgroundColor
                    .ignoresSafeArea()

                // Terminal surface - use full available space
                // Use .id(session.id) to ensure a new surface is created for each session
                TerminalSurface(
                    ghosttyApp: ghosttyApp,
                    isActive: isActive,
                    onTextInput: { data in
                        // Send keyboard input to SSH via session
                        session.sendData(data)
                    },
                    onTerminalSizeChanged: { rows, columns in
                        // Send window size change to SSH server
                        session.sendWindowChange(rows: rows, columns: columns)
                    },
                    onSurfaceReady: { surface in
                        Logger.clauntty.info("onSurfaceReady called for session \(session.id.uuidString.prefix(8)), state=\(String(describing: session.state))")
                        surfaceHolder.surface = surface
                        connectSession(surface: surface)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(session.id)  // Force new surface per session
                .onChange(of: session.state) { oldState, newState in
                    // Force re-render when session connects/reconnects
                    // This fixes blank/partial rendering after reconnection
                    if case .connected = newState {
                        Logger.clauntty.info("Session state changed to connected, forcing redraw")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            surfaceHolder.surface?.forceRedraw()
                        }
                    }
                }

                // Show connecting overlay
                if session.state == .connecting {
                    Color.black.opacity(0.7)
                        .ignoresSafeArea()
                    VStack {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.5)
                        Text("Connecting...")
                            .foregroundColor(.white)
                            .padding(.top)
                    }
                }

                // Show error overlay
                if case .error(let errorMessage) = session.state {
                    Color.black.opacity(0.9)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 48))
                        Text("Connection Failed")
                            .foregroundColor(.white)
                            .font(.headline)
                        Text(errorMessage)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Close Tab") {
                            sessionManager.closeSession(session)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .captureTerminalText)) { _ in
            // Only capture if this is the active terminal
            guard isActive, let surface = surfaceHolder.surface else { return }
            handleCaptureTerminalText(surface: surface)
        }
    }

    /// Handle request to capture terminal text (from URL scheme)
    private func handleCaptureTerminalText(surface: TerminalSurfaceView) {
        Logger.clauntty.info("Capturing terminal text for session \(session.id.uuidString.prefix(8))")

        guard let text = surface.captureVisibleText() else {
            Logger.clauntty.error("Failed to capture terminal text")
            return
        }

        // Write to app's Documents directory (accessible via simctl)
        guard let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Logger.clauntty.error("Failed to get Documents directory")
            return
        }
        let filePath = documentsPath.appendingPathComponent("clauntty_dump.txt")

        do {
            try text.write(to: filePath, atomically: true, encoding: .utf8)
            Logger.clauntty.info("Terminal text written to \(filePath.path) (\(text.count) chars)")
        } catch {
            Logger.clauntty.error("Failed to write terminal text: \(error.localizedDescription)")
        }
    }

    private func connectSession(surface: TerminalSurfaceView) {
        Logger.clauntty.info("connectSession called for session \(session.id.uuidString.prefix(8)), state=\(String(describing: session.state))")

        // Always wire up the display - we need this for data flow regardless of connection state
        wireSessionToSurface(surface: surface)

        // If not disconnected, connection is already in progress or complete
        guard session.state == .disconnected else {
            Logger.clauntty.info("connectSession: session not disconnected, returning")
            return
        }

        // Start connection via SessionManager
        Task {
            do {
                try await sessionManager.connect(session: session, rtachSessionId: session.rtachSessionId)
                Logger.clauntty.info("Session connected: \(session.id.uuidString.prefix(8))")

                // Force send actual terminal size immediately after connection
                // This ensures the remote PTY has correct dimensions before user types anything
                await MainActor.run {
                    let size = surface.terminalSize
                    Logger.clauntty.info("Sending initial window size: \(size.columns)x\(size.rows)")
                    session.sendWindowChange(rows: size.rows, columns: size.columns)
                }

                // Replay any scrollback buffer that was accumulated
                if !session.scrollbackBuffer.isEmpty {
                    await MainActor.run {
                        surface.writeSSHOutput(session.scrollbackBuffer)
                    }
                }
            } catch {
                Logger.clauntty.error("Session connection failed: \(error.localizedDescription)")
                // Error state is already set by SessionManager
            }
        }
    }

    private func wireSessionToSurface(surface: TerminalSurfaceView) {
        Logger.clauntty.info("wireSessionToSurface called for session \(session.id.uuidString.prefix(8))")

        // Set up callback for session data → terminal display
        // Capture surface strongly - it's safe because session doesn't own the view
        session.onDataReceived = { data in
            DispatchQueue.main.async {
                surface.writeSSHOutput(data)
            }
        }

        // Set up callback for old scrollback → prepend to terminal
        session.onScrollbackReceived = { [weak surface] data in
            guard let surface = surface else { return }
            DispatchQueue.main.async {
                surface.prependScrollback(data)
            }
        }

        // Set up callback for terminal title changes → session title
        surface.onTitleChanged = { [weak session] title in
            session?.dynamicTitle = title
        }

        // Set up callback for scroll-triggered scrollback loading
        // When user scrolls near the top, request old scrollback (paginated)
        // Skip if on alternate screen (vim, less, Claude Code) - no scrollback there
        surface.onScrollNearTop = { [weak session, weak surface] offset in
            guard let surface = surface, !surface.isAlternateScreen else { return }
            session?.loadMoreScrollbackIfNeeded()
        }
    }
}

#Preview {
    let config = SavedConnection(
        name: "Test Server",
        host: "example.com",
        username: "user",
        authMethod: .password
    )
    let session = Session(connectionConfig: config)

    return NavigationStack {
        TerminalView(session: session)
            .environmentObject(GhosttyApp())
            .environmentObject(SessionManager())
    }
}
