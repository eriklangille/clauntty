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
    var onRefreshPorts: (() async -> [RemotePort])? = nil  // Refresh ports list
    var onForwardOnly: ((RemotePort) async -> Void)? = nil  // Forward without opening browser
    var onStopForwarding: ((RemotePort) -> Void)? = nil  // Stop forwarding a port

    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    // Alert state
    @State private var showingDeleteAlert = false
    @State private var showingRenameAlert = false
    @State private var showingKillPortAlert = false
    @State private var sessionToDelete: RtachSession?
    @State private var sessionToRename: RtachSession?
    @State private var portToKill: RemotePort?
    @State private var newName = ""
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            List {
                Section {
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
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(nil)
                        dismiss()
                    }
                }

                if !sessions.isEmpty {
                    Section("Active Sessions") {
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
                    Section {
                        ForEach(ports) { port in
                            portRow(port)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        portToKill = port
                                        showingKillPortAlert = true
                                    } label: {
                                        Label("Kill", systemImage: "xmark.circle")
                                    }
                                }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Active Ports")
                            Text("Forward ports to access remote servers locally. Enable forwarding for any ports your front-end needs (e.g., API servers).")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fontWeight(.regular)
                                .textCase(.none)
                        }
                    }
                }
            }
            .navigationTitle("Select Session")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                if let refresh = onRefreshPorts {
                    let newPorts = await refresh()
                    ports = newPorts
                }
            }
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
            Text("Delete '\(session.displayName)'? This will terminate the running shell.")
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
        .alert("Kill Process?", isPresented: $showingKillPortAlert, presenting: portToKill) { port in
            Button("Cancel", role: .cancel) {}
            Button("Kill", role: .destructive) {
                killPort(port)
            }
        } message: { port in
            if let process = port.process {
                Text("Kill '\(process)' on port \(String(port.port))?")
            } else {
                Text("Kill process on port \(String(port.port))?")
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: RtachSession) -> some View {
        let isOpenInTab = sessionManager.sessionForRtach(session.id) != nil

        HStack {
            Image(systemName: "terminal.fill")
                .foregroundColor(isOpenInTab ? .green : .blue)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayName)
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
        .contentShape(Rectangle())
        .onTapGesture {
            if let existingSession = sessionManager.sessionForRtach(session.id) {
                // Already open - switch to that tab
                onSwitchToTab(existingSession)
                dismiss()
            } else {
                // Not open - connect to it
                onSelect(session.id)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func portRow(_ port: RemotePort) -> some View {
        let isForwarded = sessionManager.isPortForwarded(port.port, config: connection)
        let existingWebTab = sessionManager.webTabForPort(port.port, config: connection)
        let isOpenInTab = existingWebTab != nil

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

                    // "Open" badge when has web tab
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

            // Forwarding toggle
            Toggle("", isOn: Binding(
                get: { isForwarded || isOpenInTab },
                set: { newValue in
                    if newValue {
                        // Start forwarding
                        Task {
                            await onForwardOnly?(port)
                        }
                    } else {
                        // Stop forwarding
                        onStopForwarding?(port)
                    }
                }
            ))
            .labelsHidden()
            .tint(.green)

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap opens browser (starts forwarding if needed)
            if let webTab = existingWebTab {
                // Already open - switch to that tab
                onSwitchToWebTab(webTab)
                dismiss()
            } else {
                // Not open - create new web tab (will start forwarding)
                onSelectPort(port)
                dismiss()
            }
        }
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

    private func killPort(_ port: RemotePort) {
        guard let deployer = deployer else { return }

        // Close any open web tab for this port
        if let webTab = sessionManager.webTabForPort(port.port, config: connection) {
            sessionManager.closeWebTab(webTab)
        }

        isLoading = true
        Task {
            do {
                let scanner = PortScanner(connection: deployer.connection)
                try await scanner.killProcess(onPort: port.port)
                await MainActor.run {
                    ports.removeAll { $0.port == port.port }
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
                title: "vim ~/project/main.c",  // Has OSC title
                lastActive: Date().addingTimeInterval(-3600),
                socketPath: "~/.clauntty/sessions/ABC12345",
                created: Date().addingTimeInterval(-86400)
            ),
            RtachSession(
                id: "DEF67890-5678-5678-5678-567890ABCDEF",
                name: "bold-tiger",
                title: nil,  // No title yet, will show verb-noun
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
        onSwitchToWebTab: { _ in },
        onForwardOnly: { _ in },
        onStopForwarding: { _ in }
    )
    .environmentObject(SessionManager())
}
