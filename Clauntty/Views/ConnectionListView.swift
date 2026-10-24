import SwiftUI
import os.log

struct ConnectionListView: View {
    /// The first screen, with no sessions: in the theme's colors with the agent view's
    /// settings and voice pill, its servers as cards. Off, the New Tab sheet (the agent
    /// view's header has Settings).
    var isHome = true
    var onVoice: () -> Void = {}

    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject private var ghosttyApp: GhosttyApp
    @ObservedObject private var themeManager = ThemeManager.shared
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
                    ConnectionRow(connection: connection, isCard: isHome, background: background)
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
                        .modifier(CardRow(isOn: isHome))
                }
            }
        }
        .navigationTitle("Servers")
        .toolbar {
            if !isHome {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewConnection = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .modifier(HomeStyle(isOn: isHome, background: background, isLight: isLightTheme) {
            HStack(spacing: 0) {
                HeaderPill(onSettings: { showingSettings = true }, onVoice: onVoice)
                Spacer(minLength: 0)
                GlassCircle(systemName: "plus", size: 40) { showingNewConnection = true }
                    .accessibilityLabel("Add Server")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        })
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

    /// The terminal's background, as the agent view's
    private var background: Color {
        themeManager.theme(withId: ghosttyApp.currentThemeId)?.backgroundColor
            ?? Color(red: 40 / 255, green: 44 / 255, blue: 52 / 255)
    }

    private var isLightTheme: Bool {
        themeManager.theme(withId: ghosttyApp.currentThemeId)?.isLight == true
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

/// The first screen: the theme's background and its light or dark, the header in place of
/// the navigation bar, and a small "Servers" over the cards
private struct HomeStyle<Header: View>: ViewModifier {
    let isOn: Bool
    let background: Color
    let isLight: Bool
    @ViewBuilder let header: () -> Header

    func body(content: Content) -> some View {
        if isOn {
            content
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(background.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        header()
                        Text("Servers")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 26)
                    }
                    .padding(.bottom, 6)
                    .background(background.ignoresSafeArea())
                }
                .preferredColorScheme(isLight ? .light : .dark)
        } else {
            content
        }
    }
}

/// A card's row: no separators or row background, spaced as the agent view's windows
private struct CardRow: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
        } else {
            content
        }
    }
}

struct ConnectionRow: View {
    let connection: SavedConnection
    /// The first screen's: a card like the agent view's
    var isCard = false
    var background: Color = .clear

    var body: some View {
        if isCard { card } else { row }
    }

    private var keyIcon: some View {
        Image(systemName: connection.authMethod == .password ? "key.fill" : "key.horizontal.fill")
            .foregroundColor(.secondary)
            .font(.caption)
    }

    /// As a collapsed window: the glyph at the left, the name, and beneath it the address
    private var card: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(connection.endpointDisplay)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            keyIcon
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(background))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(SwitcherWindow.overviewBorder), lineWidth: 1)
        )
    }

    private var row: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(connection.displayName)
                    .font(.headline)
                Text(connection.endpointDisplay)
                .font(.subheadline)
                .foregroundColor(.secondary)
            }

            Spacer()

            keyIcon
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
