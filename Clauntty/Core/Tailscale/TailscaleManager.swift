import Foundation
import os.log
import UIKit
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
    /// Closing the old node during `restart`; nothing may start a node until it's done
    private var restartTask: Task<Void, Never>?
    /// The node left the DERP relays for the app's suspension (`suspend`), until it's back
    private var suspended = false

    static let hostName = "clauntty"

    private static var stateDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("tailscale", isDirectory: true)
    }

    private init() {
        // As early as iOS says the app is coming back: `scenePhase` turns `.active` only
        // after the opening animation, ~300 ms after the node is running again
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TailscaleManager.shared.resume() }
        }
    }

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
        guard node == nil, restartTask == nil else { return }
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

    /// The app is about to be suspended (its background time is up). While it's frozen,
    /// the Mac's WireGuard handshake attempts queue in the relay connection; on resume the
    /// oldest is answered, which voids the phone's own handshake, and the next try waits
    /// 5 s, and so does the terminal. Leaving the relays first makes the relay drop them.
    /// The Mac can't reach the phone until `resume()`; the phone can still dial out.
    /// `done` runs once the node is off them; the app may be suspended after it.
    func suspend(then done: @escaping () -> Void) {
        #if canImport(TailscaleKit)
        guard let node else { return done() }
        suspended = true
        TailscaleDebugLog.note("about to be suspended, leaving the relays")
        Task {
            do {
                try await node.suspend()
            } catch {
                TailscaleDebugLog.note("telling the node it's suspended failed: \(error)")
            }
            done()
        }
        #else
        done()
        #endif
    }

    /// Back in the foreground after `suspend`: the node rejoins its home relay. Before the
    /// node's next network check finishes, or it reports no home relay to control and the
    /// Mac can't answer the phone until it hears otherwise (5 s, the next handshake).
    func resume() {
        guard suspended else { return }
        suspended = false
        #if canImport(TailscaleKit)
        guard let node else { return }
        TailscaleDebugLog.note("resumed, rejoining the relays")
        Task {
            do {
                try await node.resume()
            } catch {
                TailscaleDebugLog.note("telling the node it resumed failed: \(error)")
            }
        }
        #endif
    }

    /// Tell the node the device's network changed, so it rebinds to the current
    /// interface; its connections survive. tsnet watches the routing table itself, but
    /// on iOS that watch dies while the app is suspended ("error from link monitor:
    /// socket is not connected") and it then keeps binding to an interface that's gone.
    /// With no Network Extension to tell it, the app passes on NWPathMonitor's changes.
    func networkChanged() {
        #if canImport(TailscaleKit)
        guard let node else { return }
        TailscaleDebugLog.note("telling the node the network changed")
        Task {
            do {
                try await node.networkChanged()
            } catch {
                TailscaleDebugLog.note("telling the node failed: \(error)")
            }
        }
        #endif
    }

    /// Replace the node with a fresh one that keeps the login. Used after a dial times
    /// out: the node is stuck somehow, and a new one starts on the current network.
    /// Tailnet connections through the old node close.
    func restart(reason: String) {
        #if canImport(TailscaleKit)
        guard let oldNode = node, restartTask == nil else { return }
        Logger.clauntty.debugOnly("Tailscale: restarting node (\(reason))")
        TailscaleDebugLog.note("restarting node (\(reason))")
        pollTask?.cancel()
        pollTask = nil
        node = nil
        state = .starting
        restartTask = Task { [weak self] in
            try? await oldNode.close()
            self?.restartTask = nil
            self?.start()
        }
        #endif
    }

    /// Stop the node and forget the login (removes the node's state).
    func logOut() async {
        await restartTask?.value
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
        await restartTask?.value
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
                throw TailscaleConnectError.nodeTimedOut
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Open a TCP connection to `host:port` over the tailnet. Returns a
    /// connected socket fd owned by the caller. `host` may be a MagicDNS name
    /// or a tailnet IP. If the node doesn't come up or the dial times out, the node
    /// may be stuck: it's restarted and the dial tried once more. Not when the tailnet
    /// says the host is offline, since then the timeout is expected and a restart
    /// would only drop the other tailnet connections.
    func dial(host: String, port: Int) async throws -> Int32 {
        do {
            return try await dialOnce(host: host, port: port, timeout: .seconds(15))
        } catch TailscaleConnectError.timedOut {
            if let peer = peer(for: host), !peer.online {
                TailscaleDebugLog.note("\(host) is offline, not restarting")
                throw TailscaleConnectError.peerOffline(peer.name)
            }
            restart(reason: "dial to \(host) timed out")
            return try await dialOnce(host: host, port: port, timeout: .seconds(20))
        } catch TailscaleConnectError.nodeTimedOut {
            restart(reason: "node didn't start")
            return try await dialOnce(host: host, port: port, timeout: .seconds(20))
        }
    }

    /// The peer `host` names: its MagicDNS name, short name, or tailnet IP
    private func peer(for host: String) -> TailnetPeer? {
        let host = (host.hasSuffix(".") ? String(host.dropLast()) : host).lowercased()
        return peers.first { peer in
            peer.dnsName.lowercased() == host || peer.name.lowercased() == host || peer.ip == host
        }
    }

    private func dialOnce(host: String, port: Int, timeout: Duration) async throws -> Int32 {
        try await waitUntilRunning()

        #if canImport(TailscaleKit)
        guard let node, let handle = await node.tailscale else {
            throw TailscaleConnectError.failed("Tailscale node is not running")
        }
        let address = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        Logger.clauntty.debugOnly("Tailscale: dialing \(address)")
        TailscaleDebugLog.note("dialing \(address)")

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
        do {
            let fd = try await dial.result()
            TailscaleDebugLog.note("dialed \(address)")
            return fd
        } catch {
            TailscaleDebugLog.note("dial \(address) failed: \(error.localizedDescription)")
            throw error
        }
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
            TailscaleDebugLog.note("state \(String(describing: newState))")
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
    /// The node didn't reach Running
    case nodeTimedOut
    /// The dial timed out and the tailnet lists the host as offline
    case peerOffline(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .needsLogin:
            return "Tailscale needs you to log in. Open Settings → Tailscale."
        case .timedOut:
            return "Timed out connecting over Tailscale"
        case .nodeTimedOut:
            return "Tailscale didn't connect to the tailnet in time"
        case .peerOffline(let name):
            return "Timed out connecting to \(name): Tailscale shows it as offline"
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
    // Go-side logs are very chatty; keep them out of the app log. Debug builds
    // write them to a file instead (see TailscaleDebugLog).
    var logFileHandle: Int32? { TailscaleDebugLog.newWriter() }

    func log(_ message: String) {
        Logger.clauntty.debugOnly("Tailscale: \(message)")
    }
}
#endif

/// Debug builds: the Go side's logs, timestamped, in Library/Caches/tailscale.log, the
/// one before it in tailscale.log.1. Read them from the Mac with `scripts/device.sh log`.
enum TailscaleDebugLog {
    #if DEBUG
    private static let lock = NSLock()

    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("tailscale.log")
    /// Past this the file becomes tailscale.log.1 and a new one starts. Kept small enough
    /// to copy off the phone without a cable: bigger files time out over Wi-Fi.
    private static let maxSize: UInt64 = 2_000_000

    nonisolated(unsafe) private static var file: FileHandle? = openFile()
    nonisolated(unsafe) private static var size: UInt64 = 0

    private static func openFile() -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
        return handle
    }

    private static func rotate() {
        try? file?.close()
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        file = openFile()
    }

    /// Lines written this minute, and how many more of each were held back. Some Go lines
    /// repeat every second for hours (`error from link monitor`); after a few, the rest
    /// of the minute's become one count.
    nonisolated(unsafe) private static var thisMinute: [String: Int] = [:]
    nonisolated(unsafe) private static var minuteStart = Date()
    private static let repeatsWritten = 3

    /// Write end of a pipe whose lines are stamped and appended to the file. Go
    /// doesn't timestamp them, and it closes the fd when the node goes away, so
    /// each node gets its own copy.
    private static let pipeWriteFd: Int32? = {
        guard file != nil else { return nil }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        let thread = Thread {
            var pending = Data()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { return }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...newline)
                    append(line)
                }
            }
        }
        thread.name = "tailscale-log"
        thread.start()
        return fds[1]
    }()

    static func newWriter() -> Int32? {
        guard let fd = pipeWriteFd else { return nil }
        let copy = dup(fd)
        return copy >= 0 ? copy : nil
    }

    /// App events (network changes, restarts) next to the Go logs
    static func note(_ message: String) {
        append("clauntty: \(message)")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static func append(_ line: String) {
        guard !line.isEmpty else { return }  // Go writes blank ones between some entries
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(minuteStart) >= 60 {
            for (held, count) in thisMinute where count > repeatsWritten {
                write("(\(count - repeatsWritten) more in the last minute) \(held)", at: now)
            }
            thisMinute = [:]
            minuteStart = now
        }
        let count = thisMinute[line, default: 0] + 1
        thisMinute[line] = count
        if count <= repeatsWritten {
            write(line, at: now)
        }
    }

    private static func write(_ line: String, at time: Date) {
        let data = Data("\(timeFormatter.string(from: time)) \(line)\n".utf8)
        file?.write(data)
        size += UInt64(data.count)
        if size > maxSize {
            rotate()
        }
    }
    #else
    static func newWriter() -> Int32? { nil }
    static func note(_ message: String) {}
    #endif
}
