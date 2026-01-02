import SwiftUI
import os.log

/// Sheet for viewing and managing port forwarding for a session
struct PortsSheetView: View {
    let session: Session
    let onDismiss: () -> Void

    @EnvironmentObject var sessionManager: SessionManager
    @State private var ports: [RemotePort] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        let _ = Logger.clauntty.debugOnly("PortsSheetView: body evaluated, isLoading=\(isLoading), errorMessage=\(errorMessage ?? "nil"), ports.count=\(ports.count)")
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Scanning ports...")
                } else if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("Could not scan ports")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            Task { await scanPorts() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if ports.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "globe")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No Active Ports")
                            .font(.headline)
                        Text("No listening ports found on this server.\nStart a web server or service to forward it here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    List {
                        Section {
                            ForEach(ports) { port in
                                portRow(port)
                            }
                        } header: {
                            Text("Forward ports to access remote servers locally")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textCase(.none)
                        }
                    }
                }
            }
            .navigationTitle("Ports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await scanPorts() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        .task {
            await scanPorts()
        }
    }

    @ViewBuilder
    private func portRow(_ port: RemotePort) -> some View {
        let isForwarded = sessionManager.isPortForwarded(port.port, config: session.connectionConfig)
        let existingWebTab = sessionManager.webTabForPort(port.port, config: session.connectionConfig)
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
                        // Start forwarding and open web tab
                        Task {
                            await forwardAndOpen(port)
                        }
                    } else {
                        // Stop forwarding
                        stopForwarding(port)
                    }
                }
            ))
            .labelsHidden()
            .tint(.green)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap opens browser (starts forwarding if needed)
            if let webTab = existingWebTab {
                // Already open - switch to that tab
                sessionManager.switchTo(webTab)
                onDismiss()
            } else {
                // Not open - create new web tab
                Task {
                    await forwardAndOpen(port)
                    onDismiss()
                }
            }
        }
    }

    private func scanPorts() async {
        Logger.clauntty.debugOnly("PortsSheetView: scanPorts called for session \(session.id.uuidString.prefix(8))")
        Logger.clauntty.debugOnly("PortsSheetView: session.state=\(String(describing: session.state)), sshConnection=\(session.sshConnection != nil)")

        isLoading = true
        errorMessage = nil

        // Get connection from session
        guard let connection = session.sshConnection else {
            Logger.clauntty.warning("PortsSheetView: No SSH connection on session")
            await MainActor.run {
                errorMessage = "No active connection to server"
                isLoading = false
            }
            return
        }

        Logger.clauntty.debugOnly("PortsSheetView: Got connection, isConnected=\(connection.isConnected)")

        do {
            let scanner = PortScanner(connection: connection)
            Logger.clauntty.debugOnly("PortsSheetView: Calling listListeningPorts...")
            let discoveredPorts = try await scanner.listListeningPorts()
            Logger.clauntty.debugOnly("PortsSheetView: Found \(discoveredPorts.count) ports")
            await MainActor.run {
                ports = discoveredPorts
                isLoading = false
            }
        } catch {
            Logger.clauntty.error("PortsSheetView: Error scanning ports: \(error.localizedDescription)")
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func forwardAndOpen(_ port: RemotePort) async {
        do {
            // Create web tab (handles port forwarding internally)
            let webTab = try await sessionManager.createWebTab(
                for: port,
                config: session.connectionConfig
            )
            await MainActor.run {
                sessionManager.switchTo(webTab)
            }
        } catch {
            // Handle error silently for now
        }
    }

    private func stopForwarding(_ port: RemotePort) {
        // Close any open web tab for this port
        if let webTab = sessionManager.webTabForPort(port.port, config: session.connectionConfig) {
            sessionManager.closeWebTab(webTab)
        }
    }
}
