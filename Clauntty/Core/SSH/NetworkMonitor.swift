import Foundation
import Network
import os.log

/// Watches the device's network path and reports when it settles on a different
/// network: Wi-Fi ↔ cellular, or back online after losing the network. Open TCP
/// connections aren't told when the interface they used goes away, so the app
/// checks them when this fires.
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// Called once the new path has settled and is usable
    var onChange: (() -> Void)?

    private let monitor = NWPathMonitor()
    private var lastSignature: String?
    private var settleTask: Task<Void, Never>?

    private init() {}

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = Self.signature(of: path)
            Task { @MainActor in
                self?.pathUpdated(signature: signature)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.clauntty.network-monitor"))
    }

    /// Status and interfaces in preference order. Other path updates (cost,
    /// constrained, DNS) don't affect open connections.
    nonisolated private static func signature(of path: NWPath) -> String? {
        guard path.status == .satisfied else { return nil }
        return path.availableInterfaces.map(\.name).joined(separator: ",")
    }

    private func pathUpdated(signature: String?) {
        let current = signature ?? "offline"
        guard current != lastSignature else { return }
        let previous = lastSignature
        lastSignature = current

        // The first update is the path at launch, not a change
        guard let previous else { return }
        Logger.clauntty.debugOnly("Network: path changed from \(previous) to \(current)")

        settleTask?.cancel()
        guard signature != nil else { return }
        // Joining Wi-Fi often reports several paths in a row; act on the last one
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}
