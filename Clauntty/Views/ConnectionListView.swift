import SwiftUI
import os.log

struct ConnectionListView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingNewConnection = false
    @State private var connectionToEdit: SavedConnection?
    @State private var showingPasswordPrompt = false
    @State private var pendingConnection: SavedConnection?
    @State private var enteredPassword = ""

    // Session picker state
    @State private var isConnecting = false
    @State private var showingSessionPicker = false
    @State private var rtachSessions: [RtachSession] = []
    @State private var detectedPorts: [RemotePort] = []
    @State private var connectionForPicker: SavedConnection?
    @State private var deployerForPicker: RtachDeployer?
    @State private var connectionError: String?
    @State private var showingError = false

    var body: some View {
        List {
            if connectionStore.connections.isEmpty {
                emptyStateView
            } else {
                ForEach(connectionStore.connections) { connection in
                    ConnectionRow(connection: connection)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            connect(to: connection)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                connectionStore.delete(connection)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                connectionToEdit = connection
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }
            }
        }
        .navigationTitle("Servers")
        .toolbar {
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
        .sheet(item: $connectionToEdit) { connection in
            NewConnectionView(existingConnection: connection)
        }
        .alert("Enter Password", isPresented: $showingPasswordPrompt) {
            SecureField("Password", text: $enteredPassword)
            Button("Cancel", role: .cancel) {
                enteredPassword = ""
                pendingConnection = nil
            }
            Button("Connect") {
                if let connection = pendingConnection {
                    performConnect(to: connection, password: enteredPassword)
                }
                enteredPassword = ""
            }
        } message: {
            if let connection = pendingConnection {
                Text("Enter password for \(connection.username)@\(connection.host)")
            }
        }
        .sheet(isPresented: $showingSessionPicker) {
            if let connection = connectionForPicker {
                SessionPickerView(
                    connection: connection,
                    sessions: $rtachSessions,
                    ports: $detectedPorts,
                    deployer: deployerForPicker,
                    onSelect: { selectedSessionId in
                        finalizeConnection(to: connection, rtachSessionId: selectedSessionId)
                    },
                    onSelectPort: { port in
                        openWebTab(for: port, connection: connection)
                    },
                    onSwitchToTab: { existingSession in
                        sessionManager.switchTo(existingSession)
                        // Dismiss this view too (not just the picker) to return to terminal
                        dismiss()
                    },
                    onSwitchToWebTab: { webTab in
                        sessionManager.switchTo(webTab)
                        dismiss()
                    }
                )
            }
        }
        .alert("Connection Error", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(connectionError ?? "Unknown error")
        }
        .overlay {
            if isConnecting {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    ProgressView("Connecting...")
                        .padding()
                        .background(.regularMaterial)
                        .cornerRadius(10)
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No Servers")
                .font(.headline)
            Text("Tap + to add your first server")
                .font(.subheadline)
                .foregroundColor(.secondary)

            #if DEBUG
            // Debug button to test terminal rendering without SSH
            Button("Test Terminal View") {
                let testConfig = SavedConnection(
                    name: "Test",
                    host: "localhost",
                    port: 22,
                    username: "test",
                    authMethod: .password
                )
                _ = sessionManager.createSession(for: testConfig)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 20)
            #endif
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    private func connect(to connection: SavedConnection) {
        switch connection.authMethod {
        case .password:
            // Check if we have a saved password
            if let _ = try? KeychainHelper.getPassword(for: connection.id) {
                performConnect(to: connection, password: nil)
            } else {
                // Prompt for password
                pendingConnection = connection
                showingPasswordPrompt = true
            }
        case .sshKey:
            // SSH key auth - check if key exists and has passphrase
            performConnect(to: connection, password: nil)
        }
    }

    private func performConnect(to connection: SavedConnection, password: String?) {
        // Save password if provided
        if let password = password, !password.isEmpty {
            try? KeychainHelper.savePassword(for: connection.id, password: password)
        }

        connectionStore.updateLastConnected(connection)

        // Start async connection flow
        isConnecting = true

        Task {
            do {
                // Connect SSH and list existing rtach sessions
                let result = try await sessionManager.connectAndListSessions(for: connection)

                // Also scan for listening ports
                var ports: [RemotePort] = []
                do {
                    ports = try await sessionManager.scanPorts(for: connection)
                    Logger.clauntty.info("ConnectionListView: found \(ports.count) listening ports")
                } catch {
                    Logger.clauntty.warning("ConnectionListView: port scan failed: \(error.localizedDescription)")
                }

                await MainActor.run {
                    isConnecting = false
                    detectedPorts = ports

                    if let result = result {
                        Logger.clauntty.info("ConnectionListView: got \(result.sessions.count) sessions from connectAndListSessions")
                        if !result.sessions.isEmpty || !ports.isEmpty {
                            // Show session picker (has sessions or ports)
                            rtachSessions = result.sessions
                            deployerForPicker = result.deployer
                            connectionForPicker = connection
                            showingSessionPicker = true
                        } else {
                            Logger.clauntty.info("ConnectionListView: no existing sessions or ports, creating new")
                            finalizeConnection(to: connection, rtachSessionId: nil)
                        }
                    } else if !ports.isEmpty {
                        // No rtach sessions but have ports - still show picker
                        rtachSessions = []
                        deployerForPicker = nil
                        connectionForPicker = connection
                        showingSessionPicker = true
                    } else {
                        Logger.clauntty.info("ConnectionListView: connectAndListSessions returned nil, creating new session")
                        // No existing sessions, create new one directly
                        finalizeConnection(to: connection, rtachSessionId: nil)
                    }
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    connectionError = error.localizedDescription
                    showingError = true
                }
            }
        }
    }

    private func finalizeConnection(to connection: SavedConnection, rtachSessionId: String?) {
        // Create a new session object with rtach session ID
        let session = sessionManager.createSession(for: connection)
        session.rtachSessionId = rtachSessionId

        // Navigation happens automatically when sessionManager.hasSessions becomes true
        // TerminalView will call sessionManager.connect() via connectSession()
    }

    private func openWebTab(for port: RemotePort, connection: SavedConnection) {
        Task {
            do {
                let webTab = try await sessionManager.createWebTab(for: port, config: connection)
                Logger.clauntty.info("ConnectionListView: created web tab for port \(port.port)")
                await MainActor.run {
                    sessionManager.switchTo(webTab)
                }
            } catch {
                Logger.clauntty.error("ConnectionListView: failed to create web tab: \(error.localizedDescription)")
                await MainActor.run {
                    connectionError = "Failed to forward port \(port.port): \(error.localizedDescription)"
                    showingError = true
                }
            }
        }
    }
}

struct ConnectionRow: View {
    let connection: SavedConnection

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayName)
                    .font(.headline)
                HStack(spacing: 4) {
                    Text("\(connection.username)@\(connection.host)")
                    if connection.port != 22 {
                        Text(":\(connection.port)")
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: connection.authMethod == .password ? "key.fill" : "key.horizontal.fill")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        ConnectionListView()
            .environmentObject(ConnectionStore())
            .environmentObject(AppState())
            .environmentObject(SessionManager())
    }
}
