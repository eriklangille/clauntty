import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionManager: SessionManager

    @State private var showingNewTabSheet = false

    var body: some View {
        NavigationStack {
            if sessionManager.hasSessions {
                // Show tabs + terminal when there are active sessions
                VStack(spacing: 0) {
                    SessionTabBar(onNewTab: {
                        showingNewTabSheet = true
                    })

                    if let activeSession = sessionManager.activeSession {
                        TerminalView(session: activeSession)
                    } else {
                        // Fallback if no active session (shouldn't happen)
                        Color.black.ignoresSafeArea()
                    }
                }
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
            } else {
                // Show connection list when no sessions
                ConnectionListView()
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
