import SwiftUI

/// Picker for selecting an existing rtach session or creating a new one
struct SessionPickerView: View {
    let connection: SavedConnection
    @Binding var sessions: [RtachSession]
    @Binding var ports: [RemotePort]
    let deployer: RtachDeployer?
    let onSelect: (String?) -> Void  // nil = new session, String = session ID
    let onSelectPort: (RemotePort) -> Void  // Open web tab for port
    let onSwitchToTab: (Session) -> Void  // Switch to existing tab
    let onSwitchToWebTab: (WebTab) -> Void  // Switch to existing web tab

    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    // Alert state
    @State private var showingDeleteAlert = false
    @State private var showingRenameAlert = false
    @State private var sessionToDelete: RtachSession?
    @State private var sessionToRename: RtachSession?
    @State private var newName = ""
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundColor(.green)
                                .font(.title2)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("New Session")
                                    .font(.headline)
                                Text("Start a fresh terminal session")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }

                if !sessions.isEmpty {
                    Section("Existing Sessions") {
                        ForEach(sessions) { session in
                            sessionRow(session)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        sessionToDelete = session
                                        showingDeleteAlert = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }

                                    Button {
                                        sessionToRename = session
                                        newName = session.name
                                        showingRenameAlert = true
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(.orange)
                                }
                        }
                    }
                }

                if !ports.isEmpty {
                    Section("Active Ports") {
                        ForEach(ports) { port in
                            portRow(port)
                        }
                    }
                }
            }
            .navigationTitle("Select Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .disabled(isLoading)
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
        }
        .alert("Delete Session?", isPresented: $showingDeleteAlert, presenting: sessionToDelete) { session in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteSession(session)
            }
        } message: { session in
            Text("Delete '\(session.name)'? This will terminate the running shell.")
        }
        .alert("Rename Session", isPresented: $showingRenameAlert, presenting: sessionToRename) { session in
            TextField("Session name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                renameSession(session, to: newName)
            }
            .disabled(!SessionNameGenerator.isValid(newName))
        } message: { _ in
            Text("Enter a new name (letters, numbers, hyphens only)")
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: RtachSession) -> some View {
        let isOpenInTab = sessionManager.sessionForRtach(session.id) != nil

        Button {
            if let existingSession = sessionManager.sessionForRtach(session.id) {
                // Already open - switch to that tab
                onSwitchToTab(existingSession)
                dismiss()
            } else {
                // Not open - connect to it
                onSelect(session.id)
                dismiss()
            }
        } label: {
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundColor(isOpenInTab ? .green : .blue)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.name)
                            .font(.headline)

                        if isOpenInTab {
                            Text("Open")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .clipShape(Capsule())
                        }
                    }

                    Text("Last active \(session.lastActiveDescription)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: isOpenInTab ? "arrow.right.circle" : "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func portRow(_ port: RemotePort) -> some View {
        let existingWebTab = sessionManager.webTabForPort(port.port, config: connection)
        let isOpenInTab = existingWebTab != nil

        Button {
            if let webTab = existingWebTab {
                // Already open - switch to that tab
                onSwitchToWebTab(webTab)
                dismiss()
            } else {
                // Not open - create new web tab
                onSelectPort(port)
                dismiss()
            }
        } label: {
            HStack {
                Image(systemName: "globe")
                    .foregroundColor(isOpenInTab ? .green : .blue)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(":\(String(port.port))")
                            .font(.headline)
                            .fontDesign(.monospaced)

                        if let process = port.process {
                            Text(process)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if isOpenInTab {
                            Text("Open")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .clipShape(Capsule())
                        }
                    }

                    Text(port.address)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: isOpenInTab ? "arrow.right.circle" : "chevron.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func deleteSession(_ session: RtachSession) {
        guard let deployer = deployer else { return }

        // Check if open in a tab
        if let openSession = sessionManager.sessionForRtach(session.id) {
            sessionManager.closeSession(openSession)
        }

        isLoading = true
        Task {
            do {
                try await deployer.deleteSession(sessionId: session.id)
                await MainActor.run {
                    sessions.removeAll { $0.id == session.id }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    private func renameSession(_ session: RtachSession, to newName: String) {
        guard let deployer = deployer else { return }

        isLoading = true
        Task {
            do {
                try await deployer.renameSession(sessionId: session.id, newName: newName)
                await MainActor.run {
                    if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                        sessions[index].name = newName
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }
}

#Preview {
    SessionPickerView(
        connection: SavedConnection(
            name: "Test Server",
            host: "example.com",
            port: 22,
            username: "user",
            authMethod: .password
        ),
        sessions: .constant([
            RtachSession(
                id: "ABC12345-1234-1234-1234-123456789ABC",
                name: "swift-falcon",
                lastActive: Date().addingTimeInterval(-3600),
                socketPath: "~/.clauntty/sessions/ABC12345",
                created: Date().addingTimeInterval(-86400)
            ),
            RtachSession(
                id: "DEF67890-5678-5678-5678-567890ABCDEF",
                name: "bold-tiger",
                lastActive: Date().addingTimeInterval(-86400),
                socketPath: "~/.clauntty/sessions/DEF67890",
                created: Date().addingTimeInterval(-172800)
            )
        ]),
        ports: .constant([
            RemotePort(id: 3000, port: 3000, process: "node", address: "127.0.0.1"),
            RemotePort(id: 8080, port: 8080, process: "python", address: "0.0.0.0")
        ]),
        deployer: nil,
        onSelect: { _ in },
        onSelectPort: { _ in },
        onSwitchToTab: { _ in },
        onSwitchToWebTab: { _ in }
    )
    .environmentObject(SessionManager())
}
