import Foundation
import os.log
import UIKit
import WebKit

/// Represents a web tab that displays a forwarded port via WKWebView
@MainActor
class WebTab: ObservableObject, Identifiable {
    // MARK: - Identity

    let id: UUID
    let remotePort: RemotePort
    let createdAt: Date

    /// Connection config for reconnection
    let connectionConfig: SavedConnection

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

    /// Cached screenshot for tab selector (captured when switching away)
    var cachedScreenshot: UIImage?

    /// The actual local port (may differ from requested if using port 0)
    @Published private(set) var localPort: Int

    /// Current page title from WebView
    @Published var pageTitle: String?

    /// Current URL being displayed
    @Published var currentURL: URL?

    /// Whether the page is currently loading
    @Published var isLoading: Bool = false

    /// Whether the web view can navigate back
    @Published var canGoBack: Bool = false

    /// Whether the web view can navigate forward
    @Published var canGoForward: Bool = false

    /// Reference to the WKWebView for navigation control
    weak var webView: WKWebView?

    // MARK: - Navigation

    /// Navigate back in history
    func goBack() {
        webView?.goBack()
    }

    /// Navigate forward in history
    func goForward() {
        webView?.goForward()
    }

    /// Reload the current page
    func reload() {
        webView?.reload()
    }

    /// Navigate to a path (relative to localhost:port)
    func navigate(to path: String) {
        guard let webView = webView else { return }

        var finalPath = path.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ensure path starts with /
        if !finalPath.hasPrefix("/") && !finalPath.hasPrefix(":") {
            finalPath = "/" + finalPath
        }

        // If path starts with : it's port:path format
        let urlString: String
        if finalPath.hasPrefix(":") {
            urlString = "http://localhost\(finalPath)"
        } else {
            urlString = "http://localhost:\(localPort)\(finalPath)"
        }

        guard let url = URL(string: urlString) else { return }
        let request = URLRequest(url: url)
        webView.load(request)
    }

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

    /// Server display name for grouping in tabs view
    var serverDisplayName: String? {
        return sshConnection?.host
    }

    /// URL string for display in expanded tab bar (port + path)
    var urlDisplayString: String {
        if let url = currentURL {
            var path = url.path
            if let query = url.query {
                path += "?\(query)"
            }
            if path.isEmpty { path = "/" }
            return ":\(localPort)\(path)"
        }
        return ":\(localPort)/"
    }

    /// Local URL for WebView to load
    var localURL: URL {
        URL(string: "http://localhost:\(localPort)")!
    }

    // MARK: - Initialization

    init(remotePort: RemotePort, connectionConfig: SavedConnection, sshConnection: SSHConnection? = nil) {
        self.id = UUID()
        self.remotePort = remotePort
        self.connectionConfig = connectionConfig
        self.localPort = remotePort.port  // Will be updated after forwarding starts
        self.createdAt = Date()
        self.sshConnection = sshConnection
    }

    /// Initialize from persisted state (for restoring after app restart)
    init(id: UUID, remotePort: RemotePort, connectionConfig: SavedConnection, createdAt: Date, lastPath: String?, cachedPageTitle: String?) {
        self.id = id
        self.remotePort = remotePort
        self.connectionConfig = connectionConfig
        self.localPort = remotePort.port
        self.createdAt = createdAt
        self.pageTitle = cachedPageTitle
        self.state = .closed  // Will reconnect on demand
        self.lastPath = lastPath
    }

    /// Last visited path for restoration
    var lastPath: String?

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
        Logger.clauntty.debugOnly("WebTab: starting forwarding for port \(self.remotePort.port)")

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
            Logger.clauntty.debugOnly("WebTab: forwarding started on localhost:\(actualPort)")
        } catch {
            Logger.clauntty.error("WebTab: forwarding failed: \(error)")
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Stop port forwarding and close the tab
    func close() async {
        Logger.clauntty.debugOnly("WebTab: closing port \(self.remotePort.port)")

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

    /// Reconnect and restart port forwarding (used when restoring persisted tabs)
    /// - Parameter connection: The SSH connection to use for forwarding
    func reconnect(with connection: SSHConnection) async throws {
        Logger.clauntty.debugOnly("WebTab: reconnecting port \(self.remotePort.port)")
        self.sshConnection = connection
        try await startForwarding()

        // Restore to last path if we have one
        if let lastPath = lastPath, !lastPath.isEmpty, lastPath != "/" {
            Logger.clauntty.debugOnly("WebTab: restoring last path: \(lastPath)")
            // The webView will be set when the view appears and will load this path
        }
    }

    /// Track the current path for persistence
    func updateLastPath() {
        if let url = currentURL {
            var path = url.path
            if let query = url.query {
                path += "?\(query)"
            }
            if path.isEmpty { path = "/" }
            lastPath = path
        }
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
