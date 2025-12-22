import SwiftUI
import os.log

struct TerminalView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var ghosttyApp: GhosttyApp

    /// Reference to the terminal surface view for SSH data flow
    @State private var terminalSurface: TerminalSurfaceView?
    @State private var isConnecting = false
    @State private var connectionError: String?

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
                TerminalSurface(
                    ghosttyApp: ghosttyApp,
                    onTextInput: { data in
                        // Send keyboard input to SSH
                        appState.sshConnection?.sendData(data)
                    },
                    onSurfaceReady: { surface in
                        self.terminalSurface = surface
                        connectSSH(surface: surface)
                    }
                )

                // Show connecting overlay
                if isConnecting {
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
                if let error = connectionError {
                    Color.black.opacity(0.9)
                        .ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 48))
                        Text("Connection Failed")
                            .foregroundColor(.white)
                            .font(.headline)
                        Text(error)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Dismiss") {
                            disconnect()
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top)
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    disconnect()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color.black.opacity(0.8), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func connectSSH(surface: TerminalSurfaceView) {
        guard let sshConnection = appState.sshConnection else {
            Logger.clauntty.warning("No SSH connection configured")
            return
        }

        isConnecting = true
        connectionError = nil

        // Wire SSH data received → terminal display
        sshConnection.onDataReceived = { data in
            DispatchQueue.main.async {
                surface.writeSSHOutput(data)
            }
        }

        // Start connection
        Task {
            do {
                try await sshConnection.connect()
                await MainActor.run {
                    isConnecting = false
                    Logger.clauntty.info("SSH connection established")
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    connectionError = error.localizedDescription
                    Logger.clauntty.error("SSH connection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func disconnect() {
        appState.sshConnection?.disconnect()
        appState.sshConnection = nil
        appState.connectionStatus = .disconnected
        appState.currentConnection = nil
    }
}

#Preview {
    NavigationStack {
        TerminalView()
            .environmentObject({
                let state = AppState()
                state.currentConnection = SavedConnection(
                    name: "Test Server",
                    host: "example.com",
                    username: "user",
                    authMethod: .password
                )
                state.connectionStatus = .connected
                return state
            }())
            .environmentObject(GhosttyApp())
    }
}
