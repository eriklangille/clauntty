import Foundation
import NIOCore
import NIOSSH
import os.log
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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
/// Connections waiting on the same host share one alert. On iOS it's a UIKit alert on
/// the topmost view controller so it shows over sheets like New Tab; on macOS a sheet
/// on the key window.
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
    #if canImport(UIKit)
    private weak var alert: UIAlertController?
    private static let didBecomeActive = UIApplication.didBecomeActiveNotification
    #else
    private var alert: NSAlert?
    private static let didBecomeActive = NSApplication.didBecomeActiveNotification
    #endif

    private init() {
        NotificationCenter.default.addObserver(
            forName: Self.didBecomeActive, object: nil, queue: .main
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
            dismissAlert()
            shownId = nil
            // Another connection may still be waiting; let it settle first in case one
            // sign-in let it through too
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                presentNext()
            }
        }
    }

    private func openLoginPage(_ prompt: Prompt) {
        shownId = nil
        #if canImport(UIKit)
        UIApplication.shared.open(prompt.url)
        #else
        NSWorkspace.shared.open(prompt.url)
        #endif
    }

    private func cancel(_ prompt: Prompt) {
        shownId = nil
        // Stop every connection waiting on this host
        let waiting = pending.filter { $0.prompt.host == prompt.host }
        pending.removeAll { $0.prompt.host == prompt.host }
        waiting.forEach { $0.prompt.cancel() }
        // Wait for this alert to finish dismissing before showing another host's
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            self.presentNext()
        }
    }

    #if canImport(UIKit)
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
            self.openLoginPage(prompt)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
            self.cancel(prompt)
        })
        shownId = id
        self.alert = alert
        presenter.present(alert, animated: true)
    }

    private func dismissAlert() {
        alert?.dismiss(animated: true)
    }
    #else
    private func presentNext() {
        guard alert == nil, let (id, prompt) = pending.first, NSApp.isActive else { return }

        let alert = NSAlert()
        alert.messageText = "Sign in to reach \(prompt.host)"
        alert.informativeText = Self.readable(prompt.message)
        alert.addButton(withTitle: "Open Login Page")
        alert.addButton(withTitle: "Cancel")
        shownId = id
        self.alert = alert
        let done: (NSApplication.ModalResponse) -> Void = { response in
            self.alert = nil
            switch response {
            case .alertFirstButtonReturn: self.openLoginPage(prompt)
            case .alertSecondButtonReturn: self.cancel(prompt)
            default: break  // dismissed by resolve()
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    private func dismissAlert() {
        guard let sheet = alert?.window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet, returnCode: .abort)
    }
    #endif

    /// Banner text without Tailscale's leading "# " comment markers
    private static func readable(_ message: String) -> String {
        message
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.hasPrefix("# ") ? String($0.dropFirst(2)) : String($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    #if canImport(UIKit)
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
    #endif
}
