import SwiftUI

/// What the sidebar selects: a pane, or a web page from a port on the host.
enum SidebarItem: Hashable {
    case pane(PaneSelection)
    case web(UUID)
}

/// Hosts, each with its workspaces and their panes, named and marked as on the
/// phone and in rtach's picker, and web pages under the workspace that opened them.
/// Selecting a row shows it.
struct Sidebar: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var hosts: MacHosts

    var body: some View {
        List(selection: selection) {
            ForEach(hosts.opened) { connection in
                Section {
                    ForEach(groups(on: connection)) { group in
                        WorkspaceRows(group: group)
                        ForEach(sessionManager.webTabs.filter { $0.workspaceId == group.id }) { webTab in
                            WebTabRow(webTab: webTab)
                                .padding(.leading, 10)
                        }
                    }
                    // Opened outside any workspace shown here
                    ForEach(looseWebTabs(on: connection)) { webTab in
                        WebTabRow(webTab: webTab)
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

    private func looseWebTabs(on connection: SavedConnection) -> [WebTab] {
        let groupIds = Set(sessionManager.sessionGroups.map(\.id))
        return sessionManager.webTabs(on: connection).filter { webTab in
            webTab.workspaceId.map { !groupIds.contains($0) } ?? true
        }
    }

    /// The pane or page shown, as the list's selection; picking a row shows it.
    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if let webTab = sessionManager.activeWebTab { return .web(webTab.id) }
                guard let session = sessionManager.activeSession, let groupId = session.groupId,
                      let paneId = session.pane?.paneId else { return nil }
                return .pane(PaneSelection(groupId: groupId, paneId: paneId))
            },
            set: { newValue in
                switch newValue {
                case .pane(let pane):
                    MainView.show(pane, sessionManager)
                case .web(let id):
                    if let webTab = sessionManager.webTabs.first(where: { $0.id == id }) {
                        sessionManager.switchTo(webTab)
                    }
                case nil:
                    break
                }
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
                .tag(SidebarItem.pane(PaneSelection(groupId: group.id, paneId: pane.id)))
        } else {
            Text(group.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .selectionDisabled()
            ForEach(group.panes, id: \.id) { pane in
                PaneRow(title: pane.title, status: pane.status)
                    .padding(.leading, 10)
                    .tag(SidebarItem.pane(PaneSelection(groupId: group.id, paneId: pane.id)))
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

/// A forwarded port's page; closing it stops the forward.
private struct WebTabRow: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @ObservedObject var webTab: WebTab

    var body: some View {
        Label {
            Text(webTab.title)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "globe")
                .foregroundStyle(.secondary)
        }
        .tag(SidebarItem.web(webTab.id))
        .contextMenu {
            Button("Close Page") { sessionManager.closeWebTab(webTab) }
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
