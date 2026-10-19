import SwiftUI

/// Hosts, each with its workspaces and their panes, named and marked as on the
/// phone and in rtach's picker. Selecting a pane shows it.
struct Sidebar: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts

    var body: some View {
        List(selection: selection) {
            ForEach(hosts.opened) { connection in
                Section {
                    ForEach(groups(on: connection)) { group in
                        WorkspaceRows(group: group)
                    }
                } header: {
                    HostHeader(connection: connection)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            AddHostMenu()
                .padding(10)
        }
    }

    private func groups(on connection: SavedConnection) -> [SessionGroup] {
        sessionManager.sessionGroups.filter { $0.connectionId == connection.id }
    }

    /// The pane shown, as the list's selection; picking a row shows that pane.
    private var selection: Binding<PaneSelection?> {
        Binding(
            get: {
                guard let session = sessionManager.activeSession, let groupId = session.groupId,
                      let paneId = session.pane?.paneId else { return nil }
                return PaneSelection(groupId: groupId, paneId: paneId)
            },
            set: { newValue in
                guard let newValue else { return }
                MainView.show(newValue, sessionManager)
            }
        )
    }
}

/// A workspace's name, then its panes. A workspace with one pane is one row.
private struct WorkspaceRows: View {
    let group: SessionGroup

    var body: some View {
        if group.panes.count == 1, let pane = group.panes.first {
            PaneRow(title: group.title, status: pane.status)
                .tag(PaneSelection(groupId: group.id, paneId: pane.id))
        } else {
            Text(group.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .selectionDisabled()
            ForEach(group.panes, id: \.id) { pane in
                PaneRow(title: pane.title, status: pane.status)
                    .padding(.leading, 10)
                    .tag(PaneSelection(groupId: group.id, paneId: pane.id))
            }
        }
    }
}

private struct PaneRow: View {
    let title: String
    let status: PaneStatus

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: status.symbolName)
                .foregroundStyle(status.color)
                .symbolEffect(.pulse, isActive: status == .blocked)
        }
    }
}

extension PaneStatus {
    /// The phone's status colours
    var color: Color {
        switch self {
        case .none: return .secondary.opacity(0.6)
        case .idle: return .secondary
        case .working: return .cyan
        case .blocked: return .orange
        case .done: return .green
        }
    }
}

private struct HostHeader: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts
    let connection: SavedConnection

    var body: some View {
        HStack {
            Text(connection.name)
            Spacer()
            Menu {
                Button("New Workspace") {
                    Task { await sessionManager.newWorkspace(on: connection, folder: "~") }
                }
                Button("Refresh") {
                    Task { await sessionManager.refreshWorkspaces(for: connection) }
                }
                Divider()
                Button("Remove Host", role: .destructive) {
                    // Its workspaces leave the sidebar; the panes keep running on the host
                    sessionManager.applyWorkspaces([], hostName: nil, config: connection)
                    for session in sessionManager.sessions where session.connectionConfig.id == connection.id {
                        sessionManager.closeSession(session, killRemote: false)
                    }
                    hosts.remove(connection)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

/// Opens another host from ~/.ssh/config.
private struct AddHostMenu: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts

    var body: some View {
        Menu {
            if hosts.addable.isEmpty {
                Text("No other hosts in ~/.ssh/config")
            }
            ForEach(hosts.addable) { host in
                Button(host.alias) {
                    let connection = hosts.open(host)
                    Task { await MainView.openHost(connection, sessionManager) }
                }
            }
            Divider()
            Button("Reload ~/.ssh/config") { hosts.reload() }
        } label: {
            Label("Open Host", systemImage: "plus")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
