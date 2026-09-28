import Foundation
import os.log
#if canImport(TailscaleKit)
import TailscaleKit
#endif

/// Embedded Tailscale node (userspace tsnet via libtailscale).
///
/// Only clauntty's own connections go through it: there is no VPN or Network
/// Extension, so the rest of the device is unaffected and the Tailscale app
/// isn't needed. SSH connections marked `useTailscale` dial through `dial()`.
@MainActor
final class TailscaleManager: ObservableObject {
    static let shared = TailscaleManager()

    enum State: Equatable {
        case stopped
        case starting
        case needsLogin(URL?)
        case running(ip: String?)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var tailnetName: String?
    /// Other machines on the tailnet, online first
    @Published private(set) var peers: [TailnetPeer] = []

    /// Set once the node has logged in; used to start the node at launch.
    private var hasLoggedIn: Bool {
        get { UserDefaults.standard.bool(forKey: "tailscaleLoggedIn") }
        set { UserDefaults.standard.set(newValue, forKey: "tailscaleLoggedIn") }
    }

    #if canImport(TailscaleKit)
    private var node: TailscaleNode?
    #endif
    private var pollTask: Task<Void, Never>?

    static let hostName = "clauntty"

    private static var stateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("tailscale", isDirectory: true)
    }

    private init() {}

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Start the node at launch if it was logged in before, so the first
    /// Tailscale connection doesn't wait for the node to come up.
    func startIfLoggedIn() {
        if hasLoggedIn { start() }
    }

    /// Start the node (idempotent). Watch `state` for login / running.
    func start() {
        #if canImport(TailscaleKit)
        guard node == nil else { return }
        state = .starting

        do {
            var dir = Self.stateDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)

            let config = Configuration(
                hostName: Self.hostName,
                path: dir.path,
                authKey: nil,
                controlURL: kDefaultControlURL,
                ephemeral: false
            )
            node = try TailscaleNode(config: config, logger: TailscaleLogSink())
            Logger.clauntty.debugOnly("Tailscale: node started")
        } catch {
            Logger.clauntty.error("Tailscale: failed to start node: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            return
        }

        startPolling()
        #else
        state = .failed("Tailscale is not available in this build")
        #endif
    }

    /// Stop the node and forget the login (removes the node's state).
    func logOut() async {
        pollTask?.cancel()
        pollTask = nil
        #if canImport(TailscaleKit)
        if let node {
            try? await node.close()
        }
        node = nil
        #endif
        try? FileManager.default.removeItem(at: Self.stateDirectory)
        hasLoggedIn = false
        tailnetName = nil
        peers = []
        state = .stopped
        Logger.clauntty.debugOnly("Tailscale: logged out")
    }

    /// Wait until the node is running, starting it if needed.
    func waitUntilRunning(timeout: Duration = .seconds(20)) async throws {
        start()
        let deadline = ContinuousClock.now + timeout
        while true {
            switch state {
            case .running:
                return
            case .needsLogin:
                throw TailscaleConnectError.needsLogin
            case .failed(let message):
                throw TailscaleConnectError.failed(message)
            case .stopped, .starting:
                break
            }
            if ContinuousClock.now >= deadline {
                throw TailscaleConnectError.timedOut
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Open a TCP connection to `host:port` over the tailnet. Returns a
    /// connected socket fd owned by the caller. `host` may be a MagicDNS name
    /// or a tailnet IP.
    func dial(host: String, port: Int, timeout: Duration = .seconds(30)) async throws -> Int32 {
        try await waitUntilRunning()

        #if canImport(TailscaleKit)
        guard let node, let handle = await node.tailscale else {
            throw TailscaleConnectError.failed("Tailscale node is not running")
        }
        let address = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        Logger.clauntty.debugOnly("Tailscale: dialing \(address)")

        // tailscale_dial blocks and can't be cancelled, so run it detached and
        // stop waiting on timeout; a late fd is closed when it arrives.
        let dial = DialAttempt()
        Task.detached {
            var conn: tailscale_conn = 0
            let res = tailscale_dial(handle, "tcp", address, &conn)
            if res == 0 {
                dial.finish(.success(conn))
            } else {
                dial.finish(.failure(TailscaleConnectError.failed(Self.errorMessage(handle, code: res))))
            }
        }
        Task.detached {
            try? await Task.sleep(for: timeout)
            dial.finish(.failure(TailscaleConnectError.timedOut))
        }
        return try await dial.result()
        #else
        throw TailscaleConnectError.failed("Tailscale is not available in this build")
        #endif
    }

    // MARK: - Status polling

    #if canImport(TailscaleKit)
    /// Poll the node's in-memory status. tsnet starts interactive login on its
    /// own and reports the URL as AuthURL. Unlike the LocalAPI HTTP listener,
    /// statusJSON keeps working after iOS suspends and resumes the app.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                let interval: Duration = (self?.isRunning ?? false) ? .seconds(10) : .seconds(1)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func refreshStatus() async {
        guard let node else { return }
        let status: StatusJSON
        do {
            status = try JSONDecoder().decode(StatusJSON.self, from: await node.statusJSON())
        } catch {
            Logger.clauntty.debugOnly("Tailscale: status unavailable: \(error.localizedDescription)")
            return
        }

        let newState: State
        switch status.BackendState {
        case "Running":
            newState = .running(ip: status.TailscaleIPs?.first { !$0.contains(":") } ?? status.TailscaleIPs?.first)
            hasLoggedIn = true
        case "NeedsLogin", "NeedsMachineAuth":
            let authURL = status.AuthURL ?? ""
            newState = .needsLogin(authURL.isEmpty ? nil : URL(string: authURL))
        default:
            newState = .starting
        }
        tailnetName = status.CurrentTailnet?.Name
        let newPeers = (status.Peer ?? [:]).values
            .map(TailnetPeer.init)
            .sorted { ($0.online ? 0 : 1, $0.name.lowercased()) < ($1.online ? 0 : 1, $1.name.lowercased()) }
        if newPeers != peers {
            peers = newPeers
        }
        if newState != state {
            Logger.clauntty.debugOnly("Tailscale: state \(String(describing: newState))")
            state = newState
        }
    }

    nonisolated private static func errorMessage(_ handle: TailscaleHandle, code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        if tailscale_errmsg(handle, &buf, buf.count) == 0, buf[0] != 0 {
            return String(cString: buf)
        }
        return String(cString: strerror(code))
    }
    #endif
}

/// A machine on the tailnet, from the node's status
struct TailnetPeer: Identifiable, Equatable {
    let id: String
    let name: String
    /// MagicDNS name without the trailing dot, e.g. "mac-2.tail1234.ts.net"
    let dnsName: String
    let ip: String?
    let os: String
    let online: Bool
    let lastSeen: Date?

    /// Host to connect to: the MagicDNS name, falling back to the IP
    var host: String { dnsName.isEmpty ? (ip ?? name) : dnsName }

    /// Phones and tablets are rarely SSH servers
    var isLikelyServer: Bool {
        !["ios", "android", "tvos"].contains(os.lowercased())
    }

    fileprivate init(_ peer: StatusJSON.PeerJSON) {
        dnsName = peer.DNSName.hasSuffix(".") ? String(peer.DNSName.dropLast()) : peer.DNSName
        name = dnsName.split(separator: ".").first.map(String.init) ?? peer.HostName
        id = peer.ID ?? dnsName
        ip = peer.TailscaleIPs?.first { !$0.contains(":") } ?? peer.TailscaleIPs?.first
        os = peer.OS ?? ""
        online = peer.Online ?? false
        lastSeen = peer.LastSeen.flatMap(StatusJSON.parseTime)
    }
}

/// The parts of tsnet's status JSON (ipnstate.Status) that clauntty uses.
/// TailscaleKit's own Status type omits peer OS and LastSeen.
private struct StatusJSON: Decodable {
    struct TailnetJSON: Decodable {
        let Name: String?
    }

    struct PeerJSON: Decodable {
        let ID: String?
        let HostName: String
        let DNSName: String
        let OS: String?
        let TailscaleIPs: [String]?
        let Online: Bool?
        let LastSeen: String?
    }

    let BackendState: String
    let AuthURL: String?
    let TailscaleIPs: [String]?
    let CurrentTailnet: TailnetJSON?
    let Peer: [String: PeerJSON]?

    /// Go time.Time; the zero value (year 1) means unknown.
    static func parseTime(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        guard let date, date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }
}

enum TailscaleConnectError: Error, LocalizedError {
    case needsLogin
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .needsLogin:
            return "Tailscale needs you to log in. Open Settings → Tailscale."
        case .timedOut:
            return "Timed out connecting over Tailscale"
        case .failed(let message):
            return "Tailscale: \(message)"
        }
    }
}

/// First-result-wins handoff between the dial and its timeout.
private final class DialAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int32, Error>?
    private var pending: Result<Int32, Error>?
    private var done = false

    func finish(_ result: Result<Int32, Error>) {
        lock.lock()
        if done {
            lock.unlock()
            if case .success(let fd) = result { close(fd) }
            return
        }
        done = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pending = result
            lock.unlock()
        }
    }

    func result() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                continuation.resume(with: pending)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

#if canImport(TailscaleKit)
private struct TailscaleLogSink: LogSink {
    // Go-side logs are very chatty; keep them out of the app log.
    var logFileHandle: Int32? { nil }

    func log(_ message: String) {
        Logger.clauntty.debugOnly("Tailscale: \(message)")
    }
}
#endif
