import SwiftUI
import os.log

/// Sheet for one machine: its ports (forwarded or listening) and a new tab.
/// Opened from a machine in the tab selector's strip or a tab's Ports button.
struct PortsSheetView: View {
    let config: SavedConnection
    let onDismiss: () -> Void
    /// Called after a tab was opened or switched to from the sheet (defaults to onDismiss).
    /// The tab selector uses it to close itself too.
    var onOpenedTab: (() -> Void)?

    @EnvironmentObject var sessionManager: SessionManager
    @State private var scannedPorts: [RemotePort] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    /// Row order, fixed while the sheet is open so toggling a port doesn't move it
    @State private var order: [Int] = []

    private var machineName: String { config.name.isEmpty ? config.host : config.name }

    /// A port that is listening on the machine, forwarded to the phone, or both
    private struct PortRow: Identifiable {
        let port: RemotePort
        let isListening: Bool
        let isForwarded: Bool
        let isOpenInTab: Bool
        /// Port on the phone when forwarded
        let localPort: Int?

        var id: Int { port.port }
    }

    /// Forwarded ports first (background forwards and web tabs), then the rest of the scan
    private var rows: [PortRow] {
        let listening = Dictionary(scannedPorts.map { ($0.port, $0) }, uniquingKeysWith: { first, _ in first })
        var forwarded: [Int: Int] = [:]  // remote -> local
        for port in sessionManager.forwardedPorts(on: config) {
            forwarded[port.remotePort.port] = port.localPort
        }
        // A restored web tab only forwards once it has reconnected
        let tabs = sessionManager.webTabs(on: config)
        for webTab in tabs where webTab.state == .connected {
            forwarded[webTab.remotePort.port] = webTab.localPort
        }
        let tabPorts = Set(tabs.map { $0.remotePort.port })

        func row(_ port: RemotePort) -> PortRow {
            PortRow(
                port: port,
                isListening: listening[port.port] != nil,
                isForwarded: forwarded[port.port] != nil,
                isOpenInTab: tabPorts.contains(port.port),
                localPort: forwarded[port.port]
            )
        }

        // Ports with a tab stay listed even when it isn't forwarding yet
        let shownFirst = Set(forwarded.keys).union(tabPorts)
        let forwardedRows = shownFirst.sorted().map { remote in
            row(listening[remote] ?? RemotePort(id: remote, port: remote, process: nil, address: "127.0.0.1"))
        }
        let otherRows = scannedPorts.filter { !shownFirst.contains($0.port) }.map(row)
        let sorted = forwardedRows + otherRows

        // Keep the order from the last scan; ports it didn't know go first
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let known = sorted.filter { position[$0.id] != nil }.sorted { position[$0.id]! < position[$1.id]! }
        return sorted.filter { position[$0.id] == nil } + known
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { row in
                        portRow(row)
                    }
                    scanStatus
                } footer: {
                    Text("Forwarded ports are reachable on this phone at localhost.")
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

    // MARK: - Rows

    private func portRow(_ row: PortRow) -> some View {
        HStack {
            // Only the port itself opens a tab, so taps on the menu and toggle stay theirs
            Button {
                openInTab(row.port)
            } label: {
                HStack {
                    Image(systemName: row.isForwarded ? "arrow.left.arrow.right" : "globe")
                        .foregroundColor(row.isForwarded ? .green : .secondary)
                        .font(.title3)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(":\(String(row.port.port))")
                            .font(.headline)
                            .fontDesign(.monospaced)
                        Text(status(row))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    openInTab(row.port)
                } label: {
                    Label(row.isOpenInTab ? "Show Tab" : "Open in Tab", systemImage: "square.on.square")
                }
                Button {
                    withForward(row) { url in UIApplication.shared.open(url) }
                } label: {
                    Label("Open in Safari", systemImage: "safari")
                }
                Button {
                    withForward(row) { url in UIPasteboard.general.string = url.absoluteString }
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)

            Toggle("", isOn: Binding(
                get: { row.isForwarded },
                set: { on in
                    if on {
                        withForward(row) { _ in }
                    } else {
                        sessionManager.stopForwarding(port: row.port, config: config)
                    }
                }
            ))
            .labelsHidden()
            .tint(.green)
        }
        .padding(.vertical, 4)
    }

    /// e.g. "node · forwarded to localhost:3000", "sshd", "open in tab · not listening"
    private func status(_ row: PortRow) -> String {
        var parts: [String] = []
        if let process = row.port.process {
            parts.append(process)
        }
        if row.isOpenInTab {
            // A restored tab forwards again once it's opened
            parts.append(row.isForwarded ? "open in tab" : "tab not connected")
        } else if row.isForwarded, let local = row.localPort {
            parts.append("forwarded to localhost:\(String(local))")
        }
        // Only claim nothing is listening once a scan has succeeded
        if row.isForwarded && !row.isListening && !isLoading && errorMessage == nil {
            parts.append("not listening")
        }
        if parts.isEmpty {
            parts.append(row.port.address)
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var scanStatus: some View {
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
        } else if rows.isEmpty {
            Text("No listening ports. Start a web server or service to forward it here.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Actions

    /// Run `action` with the port's local URL, forwarding it first if needed
    private func withForward(_ row: PortRow, _ action: @escaping (URL) -> Void) {
        Task {
            do {
                if !row.isForwarded {
                    try await sessionManager.startForwarding(port: row.port, config: config)
                }
                let local = sessionManager.forwardedPort(row.port.port, config: config)?.localPort
                    ?? row.localPort ?? row.port.port
                if let url = URL(string: "http://localhost:\(local)") {
                    action(url)
                }
            } catch {
                Logger.clauntty.error("PortsSheetView: failed to forward port \(row.port.port): \(error.localizedDescription)")
            }
        }
    }

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

        do {
            // Connects if no tab has (e.g. only a restored web tab so far)
            let connection: SSHConnection
            if let open = sessionManager.sshConnection(for: config) {
                connection = open
            } else {
                connection = try await sessionManager.pooledConnection(for: config)
            }
            let scanner = PortScanner(connection: connection)
            scannedPorts = try await scanner.listListeningPorts()
            order = []
            order = rows.map(\.id)
        } catch {
            Logger.clauntty.error("PortsSheetView: error scanning ports: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
