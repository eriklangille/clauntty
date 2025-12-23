import SwiftUI
import os.log

struct TerminalView: View {
    @EnvironmentObject var ghosttyApp: GhosttyApp
    @EnvironmentObject var sessionManager: SessionManager

    /// The session this terminal view is displaying
    @ObservedObject var session: Session

    /// Reference to the terminal surface view for SSH data flow
    @State private var terminalSurface: TerminalSurfaceView?

    var body: some View {
        ZStack {
            // Show terminal surface based on GhosttyApp readiness
            switch ghosttyApp.readiness {
            case .loading:
                Color.black
                    .ignoresSafeArea()
                VStack {
                    ProgressView()
                        .tint(.white)
                    Text("Initializing terminal...")
                        .foregroundColor(.gray)
                        .padding(.top)
                }

            case .error:
                Color.black
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
                // Black background extends under notch
                Color.black
                    .ignoresSafeArea()

                // Terminal respects safe area
                // Use .id(session.id) to ensure a new surface is created for each session
                TerminalSurface(
                    ghosttyApp: ghosttyApp,
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
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.black.opacity(0.8), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
                try await sessionManager.connect(session: session)
                Logger.clauntty.info("Session connected: \(session.id.uuidString.prefix(8))")

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
