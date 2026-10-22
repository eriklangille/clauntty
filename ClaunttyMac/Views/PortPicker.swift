import SwiftUI

/// Open Port (⇧⌘O, or a workspace's menu): the ports listening on the workspace's host,
/// to open as a page in that workspace. Type a port number, or filter the list (port or
/// program) and pick one; Return opens it, Escape closes.
struct PortPicker: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var window: WindowState
    /// The workspace the page goes in
    let group: SessionGroup
    @State private var query = ""
    @State private var selected = 0
    @State private var listening: [RemotePort]?
    @State private var scanError: String?
    @FocusState private var fieldFocused: Bool

    private var config: SavedConnection? {
        sessionManager.sessions.first { $0.groupId == group.id }?.connectionConfig
    }

    /// Listening ports matching the query; a typed number that isn't listed comes first
    private var items: [RemotePort] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        let ports = (listening ?? []).filter {
            text.isEmpty || String($0.port).hasPrefix(text) || ($0.process?.lowercased().contains(text) ?? false)
        }
        if let typed = Int(text), typed > 0, typed < 65536, !ports.contains(where: { $0.port == typed }) {
            return [RemotePort(id: typed, port: typed, process: nil, address: "127.0.0.1")] + ports
        }
        return ports
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            TextField("Open port: a number, or pick one listening", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .focused($fieldFocused)
                .onSubmit { choose(items) }
                .onKeyPress(.downArrow) { move(1, in: items); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
                .onKeyPress(.escape) { window.portPickerShown = false; return .handled }
            Divider()
            if items.isEmpty {
                Text(listening == nil ? (scanError ?? "Looking for ports on \(config?.name ?? "the host")…")
                                      : "Nothing listening matches")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, port in
                            row(port, highlighted: index == selected)
                                .onTapGesture {
                                    selected = index
                                    choose(items)
                                }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 520)
        .glass(in: .rect(cornerRadius: 14))
        // After the terminal has let go of the keyboard
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
        .onChange(of: query) { _, _ in selected = 0 }
        .task { await scan() }
    }

    private func row(_ port: RemotePort, highlighted: Bool) -> some View {
        let page = config.flatMap { config in sessionManager.webTabs(on: config).first { $0.remotePort.port == port.port } }
        return HStack(spacing: 10) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(":\(String(port.port))")
                .monospacedDigit()
            if let process = port.process {
                Text(process)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if page != nil {
                Text("Open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(highlighted ? Color.accentColor.opacity(0.35) : .clear, in: .rect(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func scan() async {
        guard let config else { return }
        do {
            listening = try await sessionManager.scanPorts(for: config)
        } catch {
            scanError = "Couldn't list the ports on \(config.name): type one"
            listening = []
        }
    }

    private func move(_ offset: Int, in items: [RemotePort]) {
        guard !items.isEmpty else { return }
        selected = (selected + offset + items.count) % items.count
    }

    private func choose(_ items: [RemotePort]) {
        guard items.indices.contains(selected), let config else { return }
        let port = items[selected]
        let workspace = group.id
        window.portPickerShown = false
        Task { try? await sessionManager.openPortInTab(port, config: config, workspace: workspace) }
    }
}
