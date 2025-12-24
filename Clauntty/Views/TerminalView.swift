import SwiftUI
import os.log

/// Terminal background color matching Ghostty's default theme (#282C34)
/// From ghostty/src/config/Config.zig: background: Color = .{ .r = 0x28, .g = 0x2C, .b = 0x34 }
private let terminalBackgroundColor = Color(red: 40/255.0, green: 44/255.0, blue: 52/255.0) // #282C34

struct TerminalView: View {
    @EnvironmentObject var ghosttyApp: GhosttyApp
    @EnvironmentObject var sessionManager: SessionManager

    /// The session this terminal view is displaying
    @ObservedObject var session: Session

    /// Reference to the terminal surface view for SSH data flow
    @State private var terminalSurface: TerminalSurfaceView?

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
                        self.terminalSurface = surface
                        connectSession(surface: surface)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(session.id)  // Force new surface per session

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
    }

    private func connectSession(surface: TerminalSurfaceView) {
        // Skip if already connected
        guard session.state == .disconnected else {
            // Already connecting or connected - just wire up display
            if session.state == .connected {
                wireSessionToSurface(surface: surface)
            }
            return
        }

        // Wire session data → terminal display
        wireSessionToSurface(surface: surface)

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
        // Set up callback for session data → terminal display
        session.onDataReceived = { data in
            DispatchQueue.main.async {
                surface.writeSSHOutput(data)
            }
        }

        // Set up callback for terminal title changes → session title
        surface.onTitleChanged = { [weak session] title in
            session?.dynamicTitle = title
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
