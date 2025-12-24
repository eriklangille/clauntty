import Foundation
import os.log

/// Represents a web tab that displays a forwarded port via WKWebView
@MainActor
class WebTab: ObservableObject, Identifiable {
    // MARK: - Identity

    let id: UUID
    let remotePort: RemotePort
    let createdAt: Date

    // MARK: - State

    enum State: Equatable {
        case connecting
        case connected
        case error(String)
        case closed

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.connecting, .connecting),
                 (.connected, .connected),
                 (.closed, .closed):
                return true
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published var state: State = .connecting

    /// The actual local port (may differ from requested if using port 0)
    @Published private(set) var localPort: Int

    /// Current page title from WebView
    @Published var pageTitle: String?

    /// Current URL being displayed
    @Published var currentURL: URL?

    /// Whether the page is currently loading
    @Published var isLoading: Bool = false

    // MARK: - Port Forwarding

    private var portForwarder: PortForwardingManager?

    /// Reference to the SSH connection this tab is tied to
    weak var sshConnection: SSHConnection?

    // MARK: - Computed Properties

    /// Display title for tab
    var title: String {
        if let pageTitle = pageTitle, !pageTitle.isEmpty {
            return pageTitle
        }
        if let process = remotePort.process {
            return ":\(remotePort.port) - \(process)"
        }
        return ":\(remotePort.port)"
    }

    /// Local URL for WebView to load
    var localURL: URL {
        URL(string: "http://localhost:\(localPort)")!
    }

    // MARK: - Initialization

    init(remotePort: RemotePort, sshConnection: SSHConnection) {
        self.id = UUID()
        self.remotePort = remotePort
        self.localPort = remotePort.port  // Will be updated after forwarding starts
        self.createdAt = Date()
        self.sshConnection = sshConnection
    }

    // MARK: - Port Forwarding

    /// Start port forwarding for this tab
    func startForwarding() async throws {
        guard let connection = sshConnection,
              let eventLoop = connection.nioEventLoopGroup,
              let channel = connection.nioChannel else {
            state = .error("SSH connection not available")
            throw WebTabError.noConnection
        }

        state = .connecting
        Logger.clauntty.info("WebTab: starting forwarding for port \(self.remotePort.port)")

        let forwarder = PortForwardingManager(
            localPort: remotePort.port,
            remoteHost: "127.0.0.1",
            remotePort: remotePort.port,
            eventLoopGroup: eventLoop,
            sshChannel: channel
        )

        do {
            let actualPort = try await forwarder.start()
            self.localPort = actualPort
            self.portForwarder = forwarder
            self.state = .connected
            Logger.clauntty.info("WebTab: forwarding started on localhost:\(actualPort)")
        } catch {
            Logger.clauntty.error("WebTab: forwarding failed: \(error)")
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Stop port forwarding and close the tab
    func close() async {
        Logger.clauntty.info("WebTab: closing port \(self.remotePort.port)")

        if let forwarder = portForwarder {
            do {
                try await forwarder.stop()
            } catch {
                Logger.clauntty.error("WebTab: error stopping forwarder: \(error)")
            }
        }

        portForwarder = nil
        state = .closed
    }
}

// MARK: - Hashable

extension WebTab: Hashable {
    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    nonisolated static func == (lhs: WebTab, rhs: WebTab) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Errors

enum WebTabError: Error, LocalizedError {
    case noConnection
    case forwardingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noConnection:
            return "SSH connection not available for port forwarding"
        case .forwardingFailed(let reason):
            return "Port forwarding failed: \(reason)"
        }
    }
}
