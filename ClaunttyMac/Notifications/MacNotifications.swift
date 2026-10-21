import AppKit
import UserNotifications

/// An agent that needs you or finished, as a notification, as the phone shows them,
/// with a chime for each (ClaunttyMac/Sounds, made by scripts/make-chimes.py). For a
/// pane on screen while the app is in front, only the chime: the window shows it
/// already. Clicking one brings the app forward on that pane. The Dock icon counts the
/// panes waiting for you.
@MainActor
final class MacNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacNotifications()

    private let center = UNUserNotificationCenter.current()
    private weak var sessionManager: SessionManager?

    /// Pane > Chime When Agents Finish (on unless turned off)
    static let chimeKey = "agentChime"
    static var chimes: Bool { UserDefaults.standard.object(forKey: chimeKey) as? Bool ?? true }

    func start(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        center.delegate = self
        sessionManager.onPaneAttention = { [weak self] title, body, paneId, needsYou in
            self?.paneChanged(title: title, body: body, paneId: paneId, needsYou: needsYou)
        }
        Task {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                macLog.warning("Notifications: authorization failed: \(error.localizedDescription)")
            }
        }
    }

    /// The pane was shown: what was said about it has been seen
    func seen(paneId: String) {
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(paneId)])
    }

    private func paneChanged(title: String, body: String?, paneId: String, needsYou: Bool) {
        updateBadge()
        // Working again (answered here or on another device): its notice is old news
        guard let body else { return seen(paneId: paneId) }
        // On screen with the app in front: just the chime (see willPresent)
        let onScreen = NSApp.isActive && sessionManager?.isPaneOnScreen(paneId) == true
        if onScreen && !Self.chimes { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Through the notification, so Focus and the app's sound setting apply
        content.sound = Self.chimes
            ? UNNotificationSound(named: UNNotificationSoundName(needsYou ? "agent-needs-you.wav" : "agent-done.wav"))
            : nil
        content.userInfo = ["paneId": paneId, "onScreen": onScreen]
        macLog.info("Notifications: \(needsYou ? "needs you" : "done", privacy: .public), chime \(Self.chimes, privacy: .public), on screen \(onScreen, privacy: .public)")
        // One per pane: a newer one replaces it
        let request = UNNotificationRequest(identifier: Self.identifier(paneId), content: content, trigger: nil)
        center.add(request) { error in
            if let error { macLog.warning("Notifications: couldn't post: \(error.localizedDescription)") }
        }
    }

    /// The Dock icon: how many panes are waiting at a menu or question
    func updateBadge() {
        guard let sessionManager else { return }
        let panes = Set(sessionManager.sessionGroups.flatMap { $0.panes.map(\.id) })
        let waiting = sessionManager.paneStates.filter { panes.contains($0.key) && $0.value.hasAgent && $0.value.state == "blocked" }.count
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
    }

    private static func identifier(_ paneId: String) -> String { "pane-\(paneId)" }

    // MARK: UNUserNotificationCenterDelegate

    /// In front, but the pane is elsewhere (another workspace): a banner. On screen: the
    /// chime only, gone from Notification Center once it has played.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard notification.request.content.userInfo["onScreen"] as? Bool == true else { return [.banner, .sound] }
        let id = notification.request.identifier
        Task {
            try? await Task.sleep(for: .seconds(3))
            center.removeDeliveredNotifications(withIdentifiers: [id])
        }
        return [.sound]
    }

    /// Clicked: the app comes forward on the pane
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let paneId = response.notification.request.content.userInfo["paneId"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            guard let sessionManager,
                  let group = sessionManager.sessionGroups.first(where: { $0.panes.contains { $0.id == paneId } }) else { return }
            MainView.show(PaneSelection(groupId: group.id, paneId: paneId), sessionManager)
        }
    }
}
