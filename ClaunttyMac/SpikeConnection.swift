import Foundation
import os.log

/// Spike: attach one rtach session given on the command line, the way
/// SessionManager.connect does on iOS. Phase 2 shares SessionManager instead.
///
///   --host H [--port 22] --user U --password P [--session NAME]
///
/// Without --host the window shows a local echo terminal.
@MainActor
final class SpikeConnection: ObservableObject {
    struct Options {
        var host: String
        var port = 22
        var user: String
        var password: String
        var sessionName = "mac-spike"
    }

    @Published private(set) var status = "Not connected"
    private(set) var session: Session?

    static let options: Options? = {
        var values: [String: String] = [:]
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            guard arg.hasPrefix("--"), let value = args.next() else { continue }
            values[String(arg.dropFirst(2))] = value
        }
        guard let host = values["host"], let user = values["user"], let password = values["password"] else {
            return nil
        }
        var options = Options(host: host, user: user, password: password)
        if let port = values["port"].flatMap(Int.init) { options.port = port }
        if let name = values["session"] { options.sessionName = name }
        return options
    }()

    /// Connect, deploy rtach if needed, attach the session and wire it to the view.
    func connect(_ options: Options, to view: MacTerminalView) async {
        // A fixed ID, so the spike reuses one keychain entry.
        let config = SavedConnection(
            id: UUID(uuidString: "6D61632D-7370-696B-6500-000000000001")!,
            name: "spike", host: options.host, port: options.port,
            username: options.user, authMethod: .password
        )
        let session = Session(connectionConfig: config)
        self.session = session
        let grid = view.gridSize ?? (columns: 80, rows: 24)
        session.initialTerminalSize = (rows: Int(grid.rows), columns: Int(grid.columns))

        do {
            try KeychainHelper.savePassword(for: config.id, password: options.password)
            status = "Connecting to \(options.host)…"
            let connection = SSHConnection(
                host: config.host, port: config.port, username: config.username,
                authMethod: config.authMethod, connectionId: config.id
            )
            try await connection.connect()
            session.sshConnection = connection

            status = "Checking rtach…"
            let deployer = RtachDeployer(connection: connection)
            try await deployer.ensureDeployed()
            session.rtachSessionId = options.sessionName
            let command = deployer.shellCommand(sessionId: options.sessionName, create: true)

            let (channel, handler) = try await connection.createChannel(
                terminalSize: session.initialTerminalSize,
                command: command,
                onDataReceived: { [weak session] data in
                    Task { @MainActor in session?.handleDataReceived(data) }
                },
                onChannelInactive: { [weak self, weak session] in
                    Task { @MainActor in
                        session?.handleChannelInactive()
                        self?.status = "Disconnected"
                    }
                }
            )

            session.onDataReceived = { [weak view] data in view?.write(data) }
            view.onInput = { [weak session] data in session?.sendData(data) }
            view.onResize = { [weak session] columns, rows in
                session?.sendWindowChange(rows: rows, columns: columns)
            }
            session.attach(channel: channel, handler: handler, connection: connection, expectsRtach: true)
            status = "\(options.user)@\(options.host) · \(options.sessionName)"
        } catch {
            macLog.error("spike connect failed: \(String(reflecting: error), privacy: .public)")
            status = "Failed: \(error.localizedDescription)"
        }
    }
}
