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

    // Connection state
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var showingError = false
    @State private var showingSettings = false

    // New workspace: the host, and the folder typed for it
    @State private var workspaceHost: SavedConnection?
    @State private var workspaceFolder = "~"

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
                        .contextMenu {
                            Button {
                                workspaceFolder = "~"
                                workspaceHost = connection
                            } label: {
                                Label("New Workspace…", systemImage: "rectangle.split.2x1")
                            }
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
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gear")
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
        .sheet(item: $connectionToEdit) { connection in
            NewConnectionView(existingConnection: connection)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
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
        .alert("New Workspace", isPresented: Binding(
            get: { workspaceHost != nil },
            set: { if !$0 { workspaceHost = nil } }
        ), presenting: workspaceHost) { connection in
            TextField("Folder", text: $workspaceFolder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                createWorkspace(on: connection, folder: workspaceFolder)
            }
        } message: { connection in
            Text("A folder on \(connection.displayName). The workspace starts at its git root, if it has one.")
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
        .onAppear {
            appState.beginInputSuppression()
            dismissTerminalInput()
        }
        .onDisappear {
            appState.endInputSuppression()
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

    private func dismissTerminalInput() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.endEditing(true) }
        NotificationCenter.default.post(name: .hideAllAccessoryBars, object: nil)
    }

    private func createWorkspace(on connection: SavedConnection, folder: String) {
        isConnecting = true
        Task {
            await sessionManager.newWorkspace(on: connection, folder: folder)
            isConnecting = false
            // Shown here: ContentView's alert can't appear over this sheet
            if let message = sessionManager.workspaceMessage {
                sessionManager.workspaceMessage = nil
                connectionError = message
                showingError = true
            } else {
                dismiss()
            }
        }
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
                // Connect SSH and sync sessions with server (auto-creates tabs for existing sessions)
                if let result = try await sessionManager.connectAndListSessions(for: connection) {
                    // Sync existing sessions -> marks deleted ones, creates tabs for new ones
                    await sessionManager.syncSessionsWithServer(config: connection, deployer: result.deployer)
                }

                // A new tab: a one-pane workspace. Its TerminalView connects it.
                let session = await sessionManager.openTerminal(on: connection)
                sessionManager.savePersistence()
                isConnecting = false
                if session == nil, let message = sessionManager.workspaceMessage {
                    sessionManager.workspaceMessage = nil
                    connectionError = message
                    showingError = true
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
}

struct ConnectionRow: View {
    let connection: SavedConnection

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayName)
                    .font(.headline)
                Text(connection.endpointDisplay)
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
