import SwiftUI

/// Simplified server picker for creating new sessions
/// Shown when user taps '+' button in tab selector
struct ServerPickerView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// Callback when a server is selected
    let onSelectServer: (SavedConnection) -> Void

    /// Whether to show the new connection form
    @State private var showingNewConnection = false

    var body: some View {
        NavigationStack {
            List {
                if connectionStore.connections.isEmpty {
                    ContentUnavailableView(
                        "No Servers",
                        systemImage: "server.rack",
                        description: Text("Add a server to create a new session")
                    )
                } else {
                    ForEach(connectionStore.connections) { connection in
                        ServerRow(
                            connection: connection,
                            sessionCount: sessionCount(for: connection)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelectServer(connection)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewConnection = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewConnection) {
                NewConnectionView()
            }
        }
        .onAppear {
            appState.beginInputSuppression()
            dismissTerminalInput()
        }
        .onDisappear {
            appState.endInputSuppression()
        }
    }

    /// Get the number of sessions for a connection
    private func sessionCount(for connection: SavedConnection) -> Int {
        sessionManager.sessions.filter { $0.connectionConfig.id == connection.id }.count
    }

    private func dismissTerminalInput() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.endEditing(true) }
        NotificationCenter.default.post(name: .hideAllAccessoryBars, object: nil)
    }
}

// MARK: - Server Row

/// Row showing a server with session count
struct ServerRow: View {
    let connection: SavedConnection
    let sessionCount: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayName)
                    .font(.body)
                    .fontWeight(.medium)

                Text(connection.endpointDisplay)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if sessionCount > 0 {
                Text("\(sessionCount) tab\(sessionCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray5))
                    .cornerRadius(4)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    ServerPickerView(onSelectServer: { _ in })
        .environmentObject(ConnectionStore())
        .environmentObject(SessionManager())
        .environmentObject(AppState())
}
