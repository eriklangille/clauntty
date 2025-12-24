import SwiftUI
import os.log

struct ContentView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionManager: SessionManager

    @State private var showingNewTabSheet = false
    @State private var hasCheckedAutoConnect = false

    var body: some View {
        NavigationStack {
            if sessionManager.hasSessions {
                // Show tabs + content when there are active sessions or web tabs
                VStack(spacing: 0) {
                    SessionTabBar(onNewTab: {
                        showingNewTabSheet = true
                    })

                    // Keep ALL views alive, but only show the active one.
                    // This preserves terminal state (font size, scrollback, etc.) across tab switches.
                    ZStack {
                        // Terminal tabs
                        ForEach(sessionManager.sessions) { session in
                            TerminalView(session: session)
                                .opacity(sessionManager.activeTab == .terminal(session.id) ? 1 : 0)
                                .allowsHitTesting(sessionManager.activeTab == .terminal(session.id))
                        }

                        // Web tabs
                        ForEach(sessionManager.webTabs) { webTab in
                            WebTabView(webTab: webTab)
                                .opacity(sessionManager.activeTab == .web(webTab.id) ? 1 : 0)
                                .allowsHitTesting(sessionManager.activeTab == .web(webTab.id))
                        }
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showingNewTabSheet) {
                    NavigationStack {
                        ConnectionListView()
                            .navigationTitle("New Tab")
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel") {
                                        showingNewTabSheet = false
                                    }
                                }
                            }
                    }
                }
                .onChange(of: sessionManager.sessions.count) { oldCount, newCount in
                    // Dismiss sheet when a new session is added
                    if newCount > oldCount {
                        showingNewTabSheet = false
                    }
                }
                .onChange(of: sessionManager.webTabs.count) { oldCount, newCount in
                    // Dismiss sheet when a new web tab is added
                    if newCount > oldCount {
                        showingNewTabSheet = false
                    }
                }
            } else {
                // Show connection list when no sessions
                ConnectionListView()
            }
        }
        .onAppear {
            checkAutoConnect()
        }
    }

    /// Check for --connect <name> launch argument and auto-connect
    private func checkAutoConnect() {
        guard !hasCheckedAutoConnect else { return }
        hasCheckedAutoConnect = true

        guard let connectionName = LaunchArgs.autoConnectName() else { return }

        Logger.clauntty.info("Auto-connect requested for: \(connectionName)")

        // Find connection by name (case-insensitive)
        guard let connection = connectionStore.connections.first(where: {
            $0.name.lowercased() == connectionName.lowercased() ||
            $0.host.lowercased() == connectionName.lowercased()
        }) else {
            let available = connectionStore.connections.map { "\($0.name) (\($0.host))" }.joined(separator: ", ")
            Logger.clauntty.error("Auto-connect: connection '\(connectionName)' not found. Available: \(available)")
            return
        }

        Logger.clauntty.info("Auto-connect: found connection \(connection.name) (\(connection.host))")

        // Create session and connect
        Task {
            do {
                // First, establish SSH and deploy rtach
                Logger.clauntty.info("Auto-connect: establishing SSH and deploying rtach...")
                let _ = try await sessionManager.connectAndListSessions(for: connection)
                Logger.clauntty.info("Auto-connect: rtach deployed, creating session...")

                // Now create and connect the terminal session
                let session = sessionManager.createSession(for: connection)
                try await sessionManager.connect(session: session)
                Logger.clauntty.info("Auto-connect: session connected successfully")
            } catch {
                Logger.clauntty.error("Auto-connect failed: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ConnectionStore())
        .environmentObject(AppState())
        .environmentObject(SessionManager())
}
