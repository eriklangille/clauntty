import Foundation

/// A pane's session on a host
@MainActor
final class Session: ObservableObject {
    @Published var title = "shell"
    private let retries: Int = 3
    let ratio = 0.5

    enum State: String { case connecting, connected }

    func resume(after delay: Duration = .seconds(2)) async throws -> Bool {
        guard retries > 0 else { return false }
        // Retry on a stale channel
        let name = "\(title) (\(retries))\n"
        try await Task.sleep(for: delay)
        return name.isEmpty == false && self.ratio < 1
    }
}
