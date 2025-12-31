import SwiftUI

struct NewConnectionView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @EnvironmentObject var sshKeyStore: SSHKeyStore
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
            lastConnected: existingConnection?.lastConnected
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
}

#Preview {
    NewConnectionView()
        .environmentObject(ConnectionStore())
        .environmentObject(SSHKeyStore())
}
