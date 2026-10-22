import AppKit
import UserNotifications

/// An agent that needs you or finished: a chime for each (ClaunttyMac/Sounds, made by
/// scripts/make-chimes.py), and a notification as the phone shows them, except for a pane
/// on screen while the app is in front: the window shows it already. The app plays the
/// chime itself, so it's heard whatever the notification settings or Focus say about
/// banners. Clicking a notification brings the app forward on that pane. The Dock icon
/// counts the panes waiting for you.
@MainActor
final class MacNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacNotifications()

    private let center = UNUserNotificationCenter.current()
    private weak var sessionManager: SessionManager?

    /// Pane > Chime When Agents Finish, Settings > Sounds (on unless turned off)
    static let chimeKey = "agentChime"
    static var chimes: Bool { flag(chimeKey) }
    /// Each chime on its own (Settings > Sounds)
    static let doneChimeKey = "agentChimeDone"
    static let needsYouChimeKey = "agentChimeNeedsYou"
    /// 0–1, the chimes' own volume, under the Mac's
    static let chimeVolumeKey = "agentChimeVolume"
    static var chimeVolume: Float { Float(UserDefaults.standard.object(forKey: chimeVolumeKey) as? Double ?? 1) }
    /// Banners for agents out of sight (Settings > Notifications); the chime doesn't need them
    static let bannersKey = "agentBanners"

    private static func flag(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// Kept, so a chime isn't let go while it plays
    private let doneChime = NSSound(named: "agent-done")
    private let needsYouChime = NSSound(named: "agent-needs-you")

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
        if Self.chimes, Self.flag(needsYou ? Self.needsYouChimeKey : Self.doneChimeKey) {
            playChime(needsYou: needsYou)
        }
        // On screen with the app in front: the window shows it already
        let onScreen = NSApp.isActive && sessionManager?.isPaneOnScreen(paneId) == true
        macLog.info("Notifications: \(needsYou ? "needs you" : "done", privacy: .public), chime \(Self.chimes, privacy: .public), on screen \(onScreen, privacy: .public)")
        if onScreen || !Self.flag(Self.bannersKey) { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["paneId": paneId]
        // One per pane: a newer one replaces it
        let request = UNNotificationRequest(identifier: Self.identifier(paneId), content: content, trigger: nil)
        center.add(request) { error in
            if let error { macLog.warning("Notifications: couldn't post: \(error.localizedDescription)") }
        }
    }

    /// A chime at the set volume (Settings plays them to try)
    func playChime(needsYou: Bool) {
        guard let chime = needsYou ? needsYouChime : doneChime else { return }
        // Another agent's, just before: start it again
        chime.stop()
        chime.volume = Self.chimeVolume
        chime.play()
    }

    /// Whether macOS lets the app post banners (Settings shows it)
    func bannersAllowed() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
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

    /// In front, but the pane is elsewhere (another workspace): a banner
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
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
