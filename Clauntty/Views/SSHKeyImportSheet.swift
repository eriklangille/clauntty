import SwiftUI

/// Sheet for importing a new SSH key with a required label
struct SSHKeyImportSheet: View {
    @ObservedObject var sshKeyStore: SSHKeyStore
    @Environment(\.dismiss) private var dismiss

    var onImport: (SSHKey) -> Void

    @State private var label: String = ""
    @State private var keyContent: String = ""
    @State private var passphrase: String = ""
    @State private var showingFileImporter = false

    // Validation
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Key name", text: $label)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Label")
                } footer: {
                    Text("A name to identify this key (e.g., \"Work Laptop\")")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste your private key (Ed25519 or ECDSA):")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextEditor(text: $keyContent)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                    }

                    Button {
                        showingFileImporter = true
                    } label: {
                        Label("Import from Files", systemImage: "doc")
                    }
                } header: {
                    Text("Private Key")
                }

                Section {
                    SecureField("Passphrase", text: $passphrase)
                } header: {
                    Text("Passphrase")
                } footer: {
                    Text("Leave empty if your key is not encrypted")
                }
            }
            .navigationTitle("Add SSH Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        importKey()
                    }
                    .disabled(!isValid)
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.data, .text],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var isValid: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
        !keyContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func importKey() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedKey = keyContent.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for duplicate label
        if sshKeyStore.keyExists(withLabel: trimmedLabel) {
            errorMessage = "A key with this name already exists"
            showingError = true
            return
        }

        // Validate key format
        guard trimmedKey.contains("BEGIN OPENSSH PRIVATE KEY") else {
            errorMessage = "Invalid SSH key format. OpenSSH format required (Ed25519 or ECDSA)."
            showingError = true
            return
        }

        guard let keyData = trimmedKey.data(using: .utf8) else {
            errorMessage = "Failed to encode SSH key"
            showingError = true
            return
        }

        do {
            let trimmedPassphrase = passphrase.isEmpty ? nil : passphrase
            let key = try sshKeyStore.addKey(label: trimmedLabel, privateKeyData: keyData, passphrase: trimmedPassphrase)
            onImport(key)
            dismiss()
        } catch {
            errorMessage = "Failed to save SSH key: \(error.localizedDescription)"
            showingError = true
        }
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Cannot access file"
                showingError = true
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                keyContent = content

                // Auto-fill label from filename if empty
                if label.isEmpty {
                    let filename = url.deletingPathExtension().lastPathComponent
                    label = filename
                }
            } catch {
                errorMessage = "Failed to read file: \(error.localizedDescription)"
                showingError = true
            }

        case .failure(let error):
            errorMessage = "Failed to import file: \(error.localizedDescription)"
            showingError = true
        }
    }
}

#Preview {
    SSHKeyImportSheet(sshKeyStore: SSHKeyStore()) { key in
        print("Imported key: \(key.label)")
    }
}
