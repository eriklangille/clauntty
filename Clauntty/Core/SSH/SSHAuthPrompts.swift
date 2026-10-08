import Foundation
import NIOCore
import NIOSSH
import UIKit
import os.log

/// Passes the server's user-auth banner and auth success up from the NIO pipeline.
/// Tailscale SSH in check mode sends its sign-in link as a banner, then holds
/// authentication until the user signs in.
final class SSHAuthBannerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let onBanner: (String) -> Void
    private let onAuthSucceeded: () -> Void

    init(onBanner: @escaping (String) -> Void, onAuthSucceeded: @escaping () -> Void) {
        self.onBanner = onBanner
        self.onAuthSucceeded = onAuthSucceeded
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let banner as NIOUserAuthBannerEvent:
            onBanner(banner.message)
        case is UserAuthSuccessEvent:
            onAuthSucceeded()
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }
}

/// Sign-in prompts from SSH banners that carry a link (Tailscale SSH check mode).
/// Connections waiting on the same host share one alert. It's a UIKit alert on the
/// topmost view controller so it shows over sheets like New Tab.
@MainActor
final class SSHAuthPrompts {
    static let shared = SSHAuthPrompts()

    private struct Prompt {
        let host: String
        let message: String
        let url: URL
        let cancel: () -> Void
    }

    /// Waiting connections, in arrival order
    private var pending: [(id: ObjectIdentifier, prompt: Prompt)] = []
    private var shownId: ObjectIdentifier?
    private weak var alert: UIAlertController?

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            // Back from Safari: give a finished sign-in a moment to arrive before asking again
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                SSHAuthPrompts.shared.presentNext()
            }
        }
    }

    /// The first http(s) link in a banner, if any
    static func link(in message: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(message.startIndex..., in: message)
        return detector.matches(in: message, range: range)
            .compactMap(\.url)
            .first { $0.scheme == "https" || $0.scheme == "http" }
    }

    func show(for connection: AnyObject, host: String, message: String, url: URL, cancel: @escaping () -> Void) {
        let id = ObjectIdentifier(connection)
        pending.removeAll { $0.id == id }
        pending.append((id, Prompt(host: host, message: message, url: url, cancel: cancel)))
        presentNext()
    }

    /// The connection signed in, failed or closed
    func resolve(_ connection: AnyObject) {
        let id = ObjectIdentifier(connection)
        guard pending.contains(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        if shownId == id {
            alert?.dismiss(animated: true)
            shownId = nil
            // Another connection may still be waiting; let it settle first in case one
            // sign-in let it through too
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                presentNext()
            }
        }
    }

    private func presentNext() {
        guard alert == nil, let (id, prompt) = pending.first,
              UIApplication.shared.applicationState == .active,
              let presenter = Self.topViewController()
        else { return }

        let alert = UIAlertController(
            title: "Sign in to reach \(prompt.host)",
            message: Self.readable(prompt.message),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Open Login Page", style: .default) { _ in
            self.shownId = nil
            UIApplication.shared.open(prompt.url)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.shownId = nil
            // Stop every connection waiting on this host
            let waiting = self.pending.filter { $0.prompt.host == prompt.host }
            self.pending.removeAll { $0.prompt.host == prompt.host }
            waiting.forEach { $0.prompt.cancel() }
            // Wait for this alert to finish dismissing before showing another host's
            Task {
                try? await Task.sleep(for: .seconds(0.5))
                self.presentNext()
            }
        })
        shownId = id
        self.alert = alert
        presenter.present(alert, animated: true)
    }

    /// Banner text without Tailscale's leading "# " comment markers
    private static func readable(_ message: String) -> String {
        message
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.hasPrefix("# ") ? String($0.dropFirst(2)) : String($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
