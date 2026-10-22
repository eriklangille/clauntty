import Foundation

/// The hosts the Mac app shows: ones you've opened from ~/.ssh/config, and This Mac,
/// kept in the shared ConnectionStore. Each is re-read from the config at launch, so
/// editing the config (a new HostName, another key) takes effect without re-adding it.
@MainActor
final class MacHosts: ObservableObject {
    let store: ConnectionStore
    /// The hosts in ~/.ssh/config you can open a shell on (not git forges)
    @Published private(set) var configHosts: [SSHConfig.Host] = []

    init(store: ConnectionStore) {
        self.store = store
        reload()
    }

    /// The hosts you've opened, in the order you opened them
    var opened: [SavedConnection] { store.connections }

    /// Config hosts not opened yet
    var addable: [SSHConfig.Host] {
        let ids = Set(store.connections.map(\.id))
        return configHosts.filter { !ids.contains(Self.connectionId(alias: $0.alias)) }
    }

    /// This Mac isn't open yet
    var canOpenThisMac: Bool {
        !store.connections.contains(where: \.isLocal)
    }

    /// Re-read ~/.ssh/config and refresh the opened hosts from it
    func reload() {
        let config = SSHConfig()
        configHosts = config.hosts.filter { !$0.isGitOnly }
        for connection in store.connections where !connection.isLocal {
            let fresh = Self.connection(for: config.resolve(connection.name), lastConnected: connection.lastConnected)
            if fresh != connection { store.update(fresh) }
        }
    }

    @discardableResult
    func open(_ host: SSHConfig.Host) -> SavedConnection {
        let connection = Self.connection(for: host)
        if let existing = store.connections.first(where: { $0.id == connection.id }) { return existing }
        store.add(connection)
        return connection
    }

    /// Terminals on this Mac, in its own ~/.clauntty: rtach sessions that a phone or a
    /// terminal here opens too
    @discardableResult
    func openThisMac() -> SavedConnection {
        if let existing = store.connections.first(where: \.isLocal) { return existing }
        let connection = SavedConnection(
            id: SavedConnection.thisMacId,
            name: "This Mac",
            host: "localhost",
            // No SSH port: its key (user@host:port) is never an ssh_config host's
            port: 0,
            username: NSUserName(),
            authMethod: .password
        )
        store.add(connection)
        return connection
    }

    /// A host dragged onto another's header takes its place: before it when dragged up,
    /// after it when dragged down
    func move(_ id: UUID, to target: UUID) {
        // The sidebar watches us, not the store
        objectWillChange.send()
        store.move(id, to: target)
    }

    func remove(_ connection: SavedConnection) {
        store.delete(connection)
    }

    /// Named by its alias, so the same host keeps its workspaces across launches
    static func connectionId(alias: String) -> UUID {
        SessionManager.stableId("ssh-config/\(alias)")
    }

    static func connection(for host: SSHConfig.Host, lastConnected: Date? = nil) -> SavedConnection {
        SavedConnection(
            id: connectionId(alias: host.alias),
            name: host.alias,
            host: host.hostName,
            port: host.port,
            username: host.user,
            // No key file: nothing to offer but "none", which is all Tailscale SSH needs
            authMethod: host.keyFile.map { .sshKey(keyId: SSHAuthenticator.keyFilePrefix + $0) } ?? .password,
            lastConnected: lastConnected,
            proxyCommand: host.proxyCommand
        )
    }
}
