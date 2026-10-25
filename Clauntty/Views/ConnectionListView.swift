import SwiftUI
import SafariServices
import os.log

struct ConnectionListView: View {
    /// The first screen, with no sessions: in the theme's colors with the agent view's
    /// settings and voice pill. Off, the New Tab sheet, with a close button in its place
    /// (the agent view's header has Settings). Both show the servers as cards.
    var isHome = true
    var onVoice: () -> Void = {}
    var onClose: () -> Void = {}

    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var sshKeyStore: SSHKeyStore
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject private var ghosttyApp: GhosttyApp
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var tailscale = TailscaleManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingNewConnection = false
    @State private var connectionToEdit: SavedConnection?
    @State private var showingPasswordPrompt = false
    @State private var pendingConnection: SavedConnection?
    @State private var enteredPassword = ""

    // Connection state
    @State private var isConnecting = false
    @State private var connectionError: String?
    /// The server that failed to connect, for its key's setup command
    @State private var failedConnection: SavedConnection?
    @State private var showingError = false
    @State private var showingSettings = false

    // New workspace: the host, and the folder typed for it
    @State private var workspaceHost: SavedConnection?
    @State private var workspaceFolder = "~"

    // Tailscale: logging in from here, and a tailnet machine being added
    @State private var tailscaleLoginRequested = false
    /// Tailscale's login page, open in the app until the node is running
    @State private var tailscaleLogin: TailscaleLoginPage?
    @State private var tailnetMachine: TailnetPeer?
    /// The username last typed for a tailnet machine, for trying again
    @State private var tailnetUsername: String?
    @State private var showAllTailnetMachines = false

    var body: some View {
        List {
            if !connectionStore.connections.isEmpty {
                SectionLabel(title: "Servers")
                ForEach(connectionStore.connections) { connection in
                    ConnectionRow(connection: connection, peer: peer(for: connection), background: background)
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
                            Button {
                                connectionToEdit = connection
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                connectionStore.delete(connection)
                            } label: {
                                Label("Delete", systemImage: "trash")
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
                        .modifier(CardRow())
                }
            }

            tailnetSection

            if connectionStore.connections.isEmpty && newTailnetMachines.isEmpty {
                emptyStateView
            }
        }
        .modifier(HomeStyle(background: background, isLight: isLightTheme) {
            HStack(spacing: 8) {
                if isHome {
                    HeaderPill(onSettings: { showingSettings = true }, onVoice: onVoice)
                } else {
                    GlassCircle(systemName: "xmark", size: 40, action: onClose)
                        .accessibilityLabel("Close")
                }
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
        .sheet(item: $tailnetMachine) { peer in
            TailnetMachineSheet(peer: peer, username: tailnetUsername ?? recentUsername) { username in
                addAndConnect(peer, username: username)
            }
            .presentationDetents([.medium])
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
            if let setup = setupCommand(for: failedConnection) {
                Button("Copy Setup Command") {
                    UIPasteboard.general.string = setup
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            if setupCommand(for: failedConnection) != nil {
                Text((connectionError ?? "Unknown error")
                     + "\n\nIf the server doesn't use Tailscale SSH, run the setup command on it once to let Clauntty's key in.")
            } else {
                Text(connectionError ?? "Unknown error")
            }
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
        .sheet(item: $tailscaleLogin) { page in
            SafariView(url: page.url)
                .ignoresSafeArea()
        }
        .onChange(of: tailscale.state) { _, state in
            if tailscaleLoginRequested, case .needsLogin(let url?) = state {
                tailscaleLoginRequested = false
                tailscaleLogin = TailscaleLoginPage(url: url)
            }
            if case .running = state {
                tailscaleLoginRequested = false
                tailscaleLogin = nil
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

    // MARK: - Tailnet

    /// Tailnet machines that could be servers and aren't saved yet, online first
    private var newTailnetMachines: [TailnetPeer] {
        guard tailscale.isRunning else { return [] }
        let saved = Set(connectionStore.connections.map { Self.hostKey($0.host) })
        return tailscale.peers.filter { peer in
            peer.isLikelyServer && ![peer.dnsName, peer.name, peer.ip ?? ""].contains { saved.contains(Self.hostKey($0)) }
        }
    }

    private static let collapsedMachineCount = 5

    /// Tailscale's part of the list: its machines not saved yet, or a card to connect it
    /// (the empty screen has its own button)
    @ViewBuilder
    private var tailnetSection: some View {
        let machines = newTailnetMachines
        if !machines.isEmpty {
            let shown = showAllTailnetMachines ? machines : Array(machines.prefix(Self.collapsedMachineCount))
            SectionLabel(title: "Tailscale", tailscale: true)
            ForEach(shown) { peer in
                TailnetMachineRow(peer: peer, background: background)
                    .contentShape(Rectangle())
                    .onTapGesture { tailnetMachine = peer }
                    .modifier(CardRow())
            }
            if machines.count > Self.collapsedMachineCount {
                Button(showAllTailnetMachines ? "Show fewer" : "Show all \(machines.count)") {
                    withAnimation { showAllTailnetMachines.toggle() }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .modifier(CardRow())
            }
        } else if !tailscale.isRunning && !connectionStore.connections.isEmpty {
            HStack(spacing: 12) {
                TailscaleLogo(size: 15)
                    .frame(width: 16)
                Text("Connect Tailscale")
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                if isLoggingIn {
                    ProgressView()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(background))
            .overlay(CardEdge())
            .contentShape(Rectangle())
            .onTapGesture(perform: logInToTailscale)
            .modifier(CardRow())
        }
    }

    private var isLoggingIn: Bool {
        tailscaleLoginRequested || tailscale.state == .starting
    }

    /// The tailnet machine a saved server is, for its online dot and OS
    private func peer(for connection: SavedConnection) -> TailnetPeer? {
        let host = Self.hostKey(connection.host)
        return tailscale.peers.first { peer in
            [peer.dnsName, peer.name, peer.ip ?? ""].contains { Self.hostKey($0) == host }
        }
    }

    private static func hostKey(_ host: String) -> String {
        (host.hasSuffix(".") ? String(host.dropLast()) : host).lowercased()
    }

    /// The username of the server connected to last, for a new tailnet machine
    private var recentUsername: String {
        connectionStore.connections
            .max { ($0.lastConnected ?? .distantPast) < ($1.lastConnected ?? .distantPast) }?
            .username ?? ""
    }

    private func logInToTailscale() {
        if case .needsLogin(let url?) = tailscale.state {
            tailscaleLogin = TailscaleLoginPage(url: url)
        } else {
            tailscaleLoginRequested = true
            tailscale.start()
        }
    }

    /// A tailnet machine over Tailscale with the app's key, saved once it connects: one
    /// that refuses it stays in the tailnet list, to try again
    private func addAndConnect(_ peer: TailnetPeer, username: String) {
        let key: SSHKey
        do {
            key = try sshKeyStore.appKey()
        } catch {
            connectionError = "Couldn't make a key: \(error.localizedDescription)"
            showingError = true
            return
        }
        let connection = SavedConnection(
            name: peer.name,
            host: peer.host,
            username: username,
            authMethod: .sshKey(keyId: key.id),
            useTailscale: true
        )
        tailnetUsername = username
        performConnect(to: connection, password: nil, isNew: true)
    }

    /// For a server that signs in with a key made in the app: the line that lets it in
    private func setupCommand(for connection: SavedConnection?) -> String? {
        guard case .sshKey(let keyId)? = connection?.authMethod,
              let key = sshKeyStore.key(withId: keyId),
              let publicKey = sshKeyStore.publicKey(for: key) else { return nil }
        return OpenSSHKeyFile.setupCommand(publicKey: publicKey)
    }

    /// The terminal's background, as the agent view's
    private var background: Color {
        themeManager.theme(withId: ghosttyApp.currentThemeId)?.backgroundColor
            ?? Color(red: 40 / 255, green: 44 / 255, blue: 52 / 255)
    }

    private var isLightTheme: Bool {
        themeManager.theme(withId: ghosttyApp.currentThemeId)?.isLight == true
    }

    /// No servers yet: Tailscale first, which finds them, else one typed in
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Text("Add a server")
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 12)

            if !tailscale.isRunning {
                Button(action: logInToTailscale) {
                    HStack(spacing: 10) {
                        if isLoggingIn {
                            ProgressView().tint(background)
                        } else {
                            TailscaleLogo(size: 17, color: background)
                        }
                        Text("Connect Tailscale")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(background)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(Color.primary))
                }
                .buttonStyle(.plain)
            }

            Button {
                showingNewConnection = true
            } label: {
                Text(tailscale.isRunning ? "Add Server" : "Add manually")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .glass(in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 120)
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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
                failedConnection = nil
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

    /// `isNew`: not saved yet, only once it connects
    private func performConnect(to connection: SavedConnection, password: String?, isNew: Bool = false) {
        // Save password if provided
        if let password = password, !password.isEmpty {
            try? KeychainHelper.savePassword(for: connection.id, password: password)
        }

        if !isNew {
            connectionStore.updateLastConnected(connection)
        }

        // Start async connection flow
        isConnecting = true

        Task {
            do {
                // Connect SSH and sync sessions with server (auto-creates tabs for existing sessions)
                let result = try await sessionManager.connectAndListSessions(for: connection)
                if isNew {
                    connectionStore.add(connection)
                    connectionStore.updateLastConnected(connection)
                }
                if let result {
                    // Sync existing sessions -> marks deleted ones, creates tabs for new ones
                    await sessionManager.syncSessionsWithServer(config: connection, deployer: result.deployer)
                }

                // A new tab: a one-pane workspace. Its TerminalView connects it.
                let session = await sessionManager.openTerminal(on: connection)
                sessionManager.savePersistence()
                isConnecting = false
                if session == nil, let message = sessionManager.workspaceMessage {
                    sessionManager.workspaceMessage = nil
                    failedConnection = nil
                    connectionError = message
                    showingError = true
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    // Refused: its key may not be on the server yet
                    if case SSHError.authenticationFailed = error {
                        failedConnection = connection
                    } else {
                        failedConnection = nil
                    }
                    connectionError = error.localizedDescription
                    showingError = true
                }
            }
        }
    }
}

/// The theme's background and its light or dark, the header in place of the navigation bar
private struct HomeStyle<Header: View>: ViewModifier {
    let background: Color
    let isLight: Bool
    @ViewBuilder let header: () -> Header

    func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                header()
                    .padding(.bottom, 6)
                    .background(background.ignoresSafeArea())
            }
            .preferredColorScheme(isLight ? .light : .dark)
    }
}

/// A card's row: no separators or row background, spaced as the agent view's windows
private struct CardRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
    }
}

/// A small label over a group of cards
private struct SectionLabel: View {
    let title: String
    var tailscale = false

    var body: some View {
        HStack(spacing: 6) {
            if tailscale {
                TailscaleLogo(size: 11, color: .secondary)
            }
            Text(title)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 14, leading: 10, bottom: 2, trailing: 10))
    }
}

/// A server as a card, like a collapsed window: its machine's glyph, the name, and beneath
/// it the address; on the tailnet, a dot for whether it's online
struct ConnectionRow: View {
    let connection: SavedConnection
    var peer: TailnetPeer?
    var background: Color = .clear

    var body: some View {
        HStack(spacing: 12) {
            MachineGlyph(os: peer?.os)
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(address)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let peer {
                Circle()
                    .fill(peer.online ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(peer.online ? "Online" : "Offline")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(background))
        .overlay(CardEdge())
    }

    /// user@host, a MagicDNS name by its machine's name alone
    private var address: String {
        let host = connection.host.hasSuffix(".ts.net")
            ? String(connection.host.split(separator: ".").first ?? "")
            : connection.host
        return connection.port == 22 ? "\(connection.username)@\(host)" : "\(connection.username)@\(host):\(connection.port)"
    }
}

/// A tailnet machine not saved yet: its OS and when it was last online, and a + to add it
private struct TailnetMachineRow: View {
    let peer: TailnetPeer
    let background: Color

    var body: some View {
        HStack(spacing: 12) {
            MachineGlyph(os: peer.os)
            VStack(alignment: .leading, spacing: 3) {
                Text(peer.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                detail
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(background))
        .overlay(CardEdge())
        .opacity(peer.online ? 1 : 0.6)
    }

    @ViewBuilder
    private var detail: some View {
        let os = MachineGlyph.osName(peer.os)
        if peer.online {
            Text("\(os) · Online")
        } else if let lastSeen = peer.lastSeen {
            Text("\(os) · Seen \(lastSeen, format: .relative(presentation: .named))")
        } else {
            Text("\(os) · Offline")
        }
    }
}

/// The machine's kind, as the agent view's cards have their glyph at the left
private struct MachineGlyph: View {
    let os: String?

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 16)
    }

    private var systemName: String {
        switch os?.lowercased() {
        case "macos": "apple.logo"
        case "windows": "pc"
        default: "server.rack"
        }
    }

    static func osName(_ os: String) -> String {
        switch os.lowercased() {
        case "macos": "macOS"
        case "linux": "Linux"
        case "windows": "Windows"
        case "freebsd": "FreeBSD"
        case "": "Machine"
        default: os
        }
    }
}

/// Tailscale's logo: nine dots, the T in them lit
struct TailscaleLogo: View {
    var size: CGFloat = 16
    var color: Color = .primary

    var body: some View {
        Canvas { context, canvas in
            let pitch = canvas.width / 3
            let dot = pitch * 0.72
            for row in 0..<3 {
                for column in 0..<3 {
                    let lit = row == 1 || (row == 2 && column == 1)
                    let rect = CGRect(x: CGFloat(column) * pitch + (pitch - dot) / 2,
                                      y: CGFloat(row) * pitch + (pitch - dot) / 2,
                                      width: dot, height: dot)
                    context.fill(Path(ellipseIn: rect), with: .color(color.opacity(lit ? 1 : 0.3)))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct TailscaleLoginPage: Identifiable {
    let url: URL
    var id: URL { url }
}

/// A web page in the app (Safari's view), so a login comes back here by itself
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Adding a tailnet machine: only its username. It signs in with the app's key; a machine
/// with Tailscale SSH lets it in without, any other needs the key added once.
private struct TailnetMachineSheet: View {
    let peer: TailnetPeer
    let onConnect: (String) -> Void

    @EnvironmentObject private var sshKeyStore: SSHKeyStore
    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var copied = false

    init(peer: TailnetPeer, username: String, onConnect: @escaping (String) -> Void) {
        self.peer = peer
        self.onConnect = onConnect
        _username = State(initialValue: username)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        MachineGlyph(os: peer.os)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name)
                                .font(.headline)
                            Text(peer.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(connect)
                } header: {
                    Text("Username")
                } footer: {
                    Text("Machines with Tailscale SSH let you straight in. On any other, run the setup command once to add Clauntty's key.")
                }

                Section {
                    Button {
                        copySetupCommand()
                    } label: {
                        Label(copied ? "Copied" : "Copy Setup Command", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }
            .navigationTitle("Add Machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: connect)
                        .disabled(trimmed.isEmpty)
                }
            }
        }
    }

    private var trimmed: String { username.trimmingCharacters(in: .whitespaces) }

    private func connect() {
        guard !trimmed.isEmpty else { return }
        dismiss()
        onConnect(trimmed)
    }

    private func copySetupCommand() {
        guard let key = try? sshKeyStore.appKey(), let publicKey = sshKeyStore.publicKey(for: key) else { return }
        UIPasteboard.general.string = OpenSSHKeyFile.setupCommand(publicKey: publicKey)
        copied = true
    }
}

#Preview {
    NavigationStack {
        ConnectionListView()
            .environmentObject(ConnectionStore())
            .environmentObject(SSHKeyStore())
            .environmentObject(AppState())
            .environmentObject(SessionManager())
    }
}
