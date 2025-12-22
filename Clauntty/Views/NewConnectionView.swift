import SwiftUI

struct NewConnectionView: View {
    @EnvironmentObject var connectionStore: ConnectionStore
    @Environment(\.dismiss) private var dismiss

    // Form state
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authType: AuthType = .password
    @State private var password: String = ""
    @State private var savePassword: Bool = true
    @State private var sshKeyId: String = ""

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
                _sshKeyId = State(initialValue: keyId)
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
                        // TODO: Implement SSH key selection UI
                        Text("SSH key import coming soon")
                            .foregroundColor(.secondary)
                    }
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

    private var isValid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        (Int(port) ?? 0) > 0 && (Int(port) ?? 0) <= 65535
    }

    private func saveConnection() {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)

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
            authMethod = .sshKey(keyId: sshKeyId.isEmpty ? UUID().uuidString : sshKeyId)
        }

        let connection = SavedConnection(
            id: existingConnection?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            host: trimmedHost,
            port: portNumber,
            username: trimmedUsername,
            authMethod: authMethod,
            lastConnected: existingConnection?.lastConnected
        )

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
}
