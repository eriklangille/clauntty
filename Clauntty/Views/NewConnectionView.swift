import SwiftUI

struct NewConnectionView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var sshKeyStore: SSHKeyStore
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    // Form state
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authType: AuthType = .password
    @State private var password: String = ""
    @State private var savePassword: Bool = true
    @State private var selectedKeyId: String?
    @State private var showingKeyImportSheet = false
    @State private var useTailscale = false
    /// Once the user flips the toggle, stop auto-suggesting it from the host
    @State private var tailscaleTouched = false
    @ObservedObject private var tailscale = TailscaleManager.shared
    @State private var showAllTailnetMachines = false

    // Validation
    @State private var showingValidationError = false
    @State private var validationError = ""

    private let existingConnection: SavedConnection?
    private var isEditing: Bool { existingConnection != nil }

    enum AuthType: String, CaseIterable {
        case password = "Password"
        case sshKey = "SSH Key"
    }

    init(existingConnection: SavedConnection? = nil) {
        self.existingConnection = existingConnection

        if let existing = existingConnection {
            _name = State(initialValue: existing.name)
            _host = State(initialValue: existing.host)
            _port = State(initialValue: String(existing.port))
            _username = State(initialValue: existing.username)
            _useTailscale = State(initialValue: existing.useTailscale)
            _tailscaleTouched = State(initialValue: true)
            switch existing.authMethod {
            case .password:
                _authType = State(initialValue: .password)
            case .sshKey(let keyId):
                _authType = State(initialValue: .sshKey)
                _selectedKeyId = State(initialValue: keyId)
            }
        } else {
            _name = State(initialValue: "")
            _host = State(initialValue: "")
            _port = State(initialValue: "22")
            _username = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !isEditing && tailscale.isRunning && !tailnetMachines.isEmpty {
                    tailnetSection
                }

                Section("Server") {
                    TextField("Name (optional)", text: $name)
                        .textInputAutocapitalization(.never)

                    TextField("Host", text: $host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)

                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Toggle("Connect via Tailscale", isOn: Binding(
                        get: { useTailscale },
                        set: { useTailscale = $0; tailscaleTouched = true }
                    ))
                } footer: {
                    if useTailscale && !tailscale.isRunning {
                        Text("Log in to Tailscale in Settings to use this. Clauntty joins your tailnet itself; the Tailscale app isn't needed.")
                    } else {
                        Text("Reach this server over your tailnet. Only Clauntty's connections use Tailscale.")
                    }
                }

                Section("Authentication") {
                    Picker("Method", selection: $authType) {
                        ForEach(AuthType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }

                    switch authType {
                    case .password:
                        SecureField("Password", text: $password)
                        Toggle("Save password", isOn: $savePassword)
                    case .sshKey:
                        sshKeySection
                    }
                }
            }
            .sheet(isPresented: $showingKeyImportSheet) {
                SSHKeyImportSheet(sshKeyStore: sshKeyStore) { key in
                    selectedKeyId = key.id
                }
            }
            .navigationTitle(isEditing ? "Edit Server" : "New Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveConnection()
                    }
                    .disabled(!isValid)
                }
            }
            .alert("Validation Error", isPresented: $showingValidationError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(validationError)
            }
        }
        .onChange(of: host) { _, newHost in
            if !tailscaleTouched {
                useTailscale = SavedConnection.looksLikeTailnetHost(newHost.trimmingCharacters(in: .whitespaces))
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

    // MARK: - Tailnet Machines

    private var tailnetMachines: [TailnetPeer] {
        tailscale.peers.filter(\.isLikelyServer)
    }

    private static let collapsedMachineCount = 5

    @ViewBuilder
    private var tailnetSection: some View {
        let machines = tailnetMachines
        let shown = showAllTailnetMachines ? machines : Array(machines.prefix(Self.collapsedMachineCount))
        Section {
            ForEach(shown) { peer in
                Button {
                    selectTailnetMachine(peer)
                } label: {
                    tailnetRow(peer)
                }
                .buttonStyle(.plain)
            }
            if machines.count > Self.collapsedMachineCount {
                Button(showAllTailnetMachines ? "Show fewer" : "Show all \(machines.count)") {
                    showAllTailnetMachines.toggle()
                }
            }
        } header: {
            Text("Tailnet Machines")
        } footer: {
            Text("Tap a machine to fill in its address.")
        }
    }

    private func tailnetRow(_ peer: TailnetPeer) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(peer.online ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                    .foregroundColor(peer.online ? .primary : .secondary)
                Text(peer.ip ?? peer.dnsName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(peer.os)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !peer.online, let lastSeen = peer.lastSeen {
                    Text(lastSeen, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            if host == peer.host {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func selectTailnetMachine(_ peer: TailnetPeer) {
        host = peer.host
        port = "22"
        useTailscale = true
        tailscaleTouched = true
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            name = peer.name
        }
    }

    // MARK: - SSH Key Section

    @ViewBuilder
    private var sshKeySection: some View {
        if sshKeyStore.keys.isEmpty {
            // No existing keys - prompt to add one
            VStack(alignment: .leading, spacing: 8) {
                Text("No SSH keys saved")
                    .foregroundColor(.secondary)

                Button {
                    showingKeyImportSheet = true
                } label: {
                    Label("Add SSH Key", systemImage: "plus.circle")
                }
            }
        } else {
            // Show picker with existing keys
            Picker("SSH Key", selection: $selectedKeyId) {
                Text("Select a key...").tag(nil as String?)
                ForEach(sshKeyStore.keys) { key in
                    Text(key.label).tag(key.id as String?)
                }
            }

            // Show selected key info or add button
            if let keyId = selectedKeyId, let key = sshKeyStore.key(withId: keyId) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(key.label)
                        .foregroundColor(.secondary)
                }
            }

            Button {
                showingKeyImportSheet = true
            } label: {
                Label("Add New Key", systemImage: "plus")
            }
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        let baseValid = !host.trimmingCharacters(in: .whitespaces).isEmpty &&
            !username.trimmingCharacters(in: .whitespaces).isEmpty &&
            (Int(port) ?? 0) > 0 && (Int(port) ?? 0) <= 65535

        // For SSH key auth, require a key to be selected
        if authType == .sshKey {
            return baseValid && selectedKeyId != nil
        }

        return baseValid
    }

    private func saveConnection() {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)

        guard !trimmedHost.isEmpty else {
            validationError = "Host is required"
            showingValidationError = true
            return
        }

        guard !trimmedUsername.isEmpty else {
            validationError = "Username is required"
            showingValidationError = true
            return
        }

        guard let portNumber = Int(port), portNumber > 0, portNumber <= 65535 else {
            validationError = "Port must be between 1 and 65535"
            showingValidationError = true
            return
        }

        let authMethod: AuthMethod
        switch authType {
        case .password:
            authMethod = .password
        case .sshKey:
            guard let keyId = selectedKeyId else {
                validationError = "Please select an SSH key"
                showingValidationError = true
                return
            }
            authMethod = .sshKey(keyId: keyId)
        }

        let connection = SavedConnection(
            id: existingConnection?.id ?? UUID(),
            name: trimmedName,
            host: trimmedHost,
            port: portNumber,
            username: trimmedUsername,
            authMethod: authMethod,
            lastConnected: existingConnection?.lastConnected,
            useTailscale: useTailscale
        )

        // Check for duplicate (same host, port, username, and name)
        if let duplicate = connectionStore.findDuplicate(of: connection, excludingId: existingConnection?.id) {
            validationError = "A connection with the same settings already exists: \(duplicate.displayName)"
            showingValidationError = true
            return
        }

        // Save password to Keychain if provided
        if authType == .password && savePassword && !password.isEmpty {
            try? KeychainHelper.savePassword(for: connection.id, password: password)
        }

        if isEditing {
            connectionStore.update(connection)
        } else {
            connectionStore.add(connection)
        }

        dismiss()
    }

    private func dismissTerminalInput() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.endEditing(true) }
        NotificationCenter.default.post(name: .hideAllAccessoryBars, object: nil)
    }
}

#Preview {
    NewConnectionView()
        .environmentObject(ConnectionStore())
        .environmentObject(SSHKeyStore())
}
