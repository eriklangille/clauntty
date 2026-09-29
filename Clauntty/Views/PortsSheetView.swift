import SwiftUI
import os.log

/// Sheet for one machine: its forwarded ports, the ports listening on it, and a new tab.
/// Opened from a machine in the tab selector's strip or a tab's Ports button.
struct PortsSheetView: View {
    let config: SavedConnection
    let onDismiss: () -> Void
    /// Called after a tab was opened or switched to from the sheet (defaults to onDismiss).
    /// The tab selector uses it to close itself too.
    var onOpenedTab: (() -> Void)?

    @EnvironmentObject var sessionManager: SessionManager
    @State private var ports: [RemotePort] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var machineName: String { config.name.isEmpty ? config.host : config.name }

    /// Background forwards on this machine (ports without a web tab)
    private var forwarded: [ForwardedPort] {
        sessionManager.forwardedPorts(on: config)
    }

    var body: some View {
        NavigationStack {
            List {
                if !forwarded.isEmpty {
                    Section {
                        ForEach(forwarded) { port in
                            forwardedRow(port)
                        }
                    } header: {
                        Text("Forwarded")
                    } footer: {
                        Text("Reachable on this phone at localhost")
                    }
                }

                Section {
                    listeningContent
                } header: {
                    Text("Listening on \(machineName)")
                }
            }
            .navigationTitle(machineName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await scanPorts() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)

                    Button {
                        openNewTerminal()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New Tab on \(machineName)")
                }
            }
        }
        .task {
            await scanPorts()
        }
    }

    // MARK: - Forwarded

    private func forwardedRow(_ port: ForwardedPort) -> some View {
        let url = URL(string: "http://localhost:\(port.localPort)")!

        return HStack {
            Image(systemName: "arrow.left.arrow.right")
                .foregroundColor(.green)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(":\(String(port.remotePort.port))")
                    .font(.headline)
                    .fontDesign(.monospaced)
                Text("localhost:\(String(port.localPort))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Menu {
                Button {
                    openInTab(port.remotePort)
                } label: {
                    Label("Open in Tab", systemImage: "square.on.square")
                }
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("Open in Safari", systemImage: "safari")
                }
                Button {
                    UIPasteboard.general.string = url.absoluteString
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                    sessionManager.stopForwarding(port: port.remotePort, config: port.connectionConfig)
                } label: {
                    Label("Stop Forwarding", systemImage: "stop.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
        }
        .padding(.vertical, 4)
        .swipeActions {
            Button("Stop", role: .destructive) {
                sessionManager.stopForwarding(port: port.remotePort, config: port.connectionConfig)
            }
        }
    }

    // MARK: - Listening

    @ViewBuilder
    private var listeningContent: some View {
        if isLoading {
            HStack {
                ProgressView()
                Text("Scanning ports...")
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
            }
        } else if let error = errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Label("Could not scan ports", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Retry") {
                    Task { await scanPorts() }
                }
            }
        } else if ports.isEmpty {
            Text("No listening ports. Start a web server or service to forward it here.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            ForEach(ports) { port in
                portRow(port)
            }
        }
    }

    @ViewBuilder
    private func portRow(_ port: RemotePort) -> some View {
        let isForwarded = sessionManager.isPortForwarded(port.port, config: config)
        let existingWebTab = sessionManager.webTabForPort(port.port, config: config)
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
                        openInTab(port)
                    } else {
                        sessionManager.stopForwarding(port: port, config: config)
                    }
                }
            ))
            .labelsHidden()
            .tint(.green)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap opens the port in a tab (starting forwarding if needed)
            openInTab(port)
        }
    }

    // MARK: - Actions

    private func openInTab(_ port: RemotePort) {
        Task {
            do {
                try await sessionManager.openPortInTab(port, config: config)
                (onOpenedTab ?? onDismiss)()
            } catch {
                Logger.clauntty.error("PortsSheetView: failed to open port \(port.port): \(error.localizedDescription)")
            }
        }
    }

    private func openNewTerminal() {
        // Becomes the active tab; its TerminalView connects when the surface is ready
        _ = sessionManager.createSession(for: config)
        sessionManager.savePersistence()
        (onOpenedTab ?? onDismiss)()
    }

    private func scanPorts() async {
        isLoading = true
        errorMessage = nil

        guard let connection = sessionManager.sshConnection(for: config) else {
            Logger.clauntty.warning("PortsSheetView: no SSH connection to \(config.host)")
            errorMessage = "Not connected to \(machineName)"
            isLoading = false
            return
        }

        do {
            let scanner = PortScanner(connection: connection)
            ports = try await scanner.listListeningPorts()
        } catch {
            Logger.clauntty.error("PortsSheetView: error scanning ports: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
