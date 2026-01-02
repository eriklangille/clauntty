import Foundation
import UIKit
import UserNotifications
import os.log

/// Notification mode for terminal input alerts
enum NotificationMode: String, CaseIterable, Codable {
    case none = "None"
    case claudeOnly = "Claude only"
    case allTerminals = "All terminals"
}

/// Manages iOS notifications for terminal input readiness
@MainActor
class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    // MARK: - Published State

    @Published var isAuthorized = false
    @Published private(set) var hasPromptedForPermission: Bool {
        didSet {
            UserDefaults.standard.set(hasPromptedForPermission, forKey: Keys.hasPromptedForPermission)
        }
    }
    @Published var notificationMode: NotificationMode {
        didSet {
            UserDefaults.standard.set(notificationMode.rawValue, forKey: Keys.notificationMode)
        }
    }

    /// Whether the app is currently backgrounded
    var appIsBackgrounded = false

    /// Session to switch to when app becomes active (set by notification tap)
    var pendingSessionSwitch: UUID?

    /// Background task identifier for continuing SSH processing
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Private

    private let notificationCenter = UNUserNotificationCenter.current()

    /// Track pending notifications to avoid duplicates
    private var pendingSessionIds = Set<UUID>()

    /// UserDefaults keys
    private enum Keys {
        static let hasPromptedForPermission = "notification_has_prompted"
        static let notificationMode = "notification_mode"
    }

    // MARK: - Initialization

    override init() {
        // Load saved preferences
        self.hasPromptedForPermission = UserDefaults.standard.bool(forKey: Keys.hasPromptedForPermission)
        if let savedMode = UserDefaults.standard.string(forKey: Keys.notificationMode),
           let mode = NotificationMode(rawValue: savedMode) {
            self.notificationMode = mode
        } else {
            self.notificationMode = .claudeOnly  // Default
        }
        super.init()

        // Check current authorization status
        Task {
            await checkAuthorizationStatus()
        }
    }

    // MARK: - Authorization

    /// Request notification authorization if not already prompted
    /// Call this on first session connect
    func requestAuthorizationIfNeeded() async {
        Logger.clauntty.debugOnly("NotificationManager.requestAuthorizationIfNeeded called, hasPrompted=\(self.hasPromptedForPermission)")

        guard !hasPromptedForPermission else {
            Logger.clauntty.debugOnly("NotificationManager: already prompted for permission, skipping")
            return
        }

        Logger.clauntty.debugOnly("NotificationManager: requesting notification authorization NOW")

        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            hasPromptedForPermission = true
            isAuthorized = granted
            Logger.clauntty.debugOnly("NotificationManager: authorization \(granted ? "granted" : "denied")")
        } catch {
            hasPromptedForPermission = true
            isAuthorized = false
            Logger.clauntty.error("NotificationManager: authorization error: \(error.localizedDescription)")
        }
    }

    /// Check current authorization status (call on app launch)
    func checkAuthorizationStatus() async {
        let settings = await notificationCenter.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
        Logger.clauntty.debugOnly("NotificationManager: authorization status = \(settings.authorizationStatus.rawValue)")
    }

    // MARK: - Notification Scheduling

    /// Check if a notification should be sent for this session
    func shouldNotify(for session: Session) -> Bool {
        Logger.clauntty.debugOnly("NotificationManager.shouldNotify: backgrounded=\(self.appIsBackgrounded), authorized=\(self.isAuthorized), mode=\(self.notificationMode.rawValue), isClaudeSession=\(session.isClaudeSession)")

        // Must be backgrounded
        guard appIsBackgrounded else {
            Logger.clauntty.debugOnly("NotificationManager: not backgrounded, skipping notification")
            return false
        }

        // Must be authorized
        guard isAuthorized else {
            Logger.clauntty.debugOnly("NotificationManager: not authorized, skipping notification")
            return false
        }

        // Check mode
        switch notificationMode {
        case .none:
            Logger.clauntty.debugOnly("NotificationManager: mode is none, skipping notification")
            return false
        case .claudeOnly:
            let should = session.isClaudeSession
            Logger.clauntty.debugOnly("NotificationManager: claudeOnly mode, isClaudeSession=\(should)")
            return should
        case .allTerminals:
            Logger.clauntty.debugOnly("NotificationManager: allTerminals mode, sending notification")
            return true
        }
    }

    /// Schedule a notification for a session that's ready for input
    func scheduleInputReady(session: Session) async {
        // Avoid duplicate notifications for same session
        guard !pendingSessionIds.contains(session.id) else {
            Logger.clauntty.debug("NotificationManager: notification already pending for session \(session.id.uuidString.prefix(8))")
            return
        }

        pendingSessionIds.insert(session.id)

        let content = UNMutableNotificationContent()
        content.title = "Input ready"
        content.body = "\(session.title) is waiting for input"
        content.sound = .default
        content.userInfo = ["sessionId": session.id.uuidString]

        // Deliver immediately
        let request = UNNotificationRequest(
            identifier: "input-ready-\(session.id.uuidString)",
            content: content,
            trigger: nil  // nil = deliver immediately
        )

        do {
            try await notificationCenter.add(request)
            Logger.clauntty.debugOnly("NotificationManager: scheduled notification for \(session.title)")
        } catch {
            pendingSessionIds.remove(session.id)
            Logger.clauntty.error("NotificationManager: failed to schedule notification: \(error.localizedDescription)")
        }
    }

    /// Clear pending notification for a session (call when user returns to app)
    func clearPendingNotification(for sessionId: UUID) {
        pendingSessionIds.remove(sessionId)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: ["input-ready-\(sessionId.uuidString)"])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: ["input-ready-\(sessionId.uuidString)"])
    }

    /// Clear all pending notifications (call when app returns to foreground)
    func clearAllPendingNotifications() {
        pendingSessionIds.removeAll()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
    }

    // MARK: - Notification Tap Handling

    /// Handle a notification tap - returns the session ID to switch to
    func handleNotificationTap(userInfo: [AnyHashable: Any]) -> UUID? {
        guard let sessionIdString = userInfo["sessionId"] as? String,
              let sessionId = UUID(uuidString: sessionIdString) else {
            Logger.clauntty.warning("NotificationManager: invalid session ID in notification")
            return nil
        }

        // Clear from pending
        pendingSessionIds.remove(sessionId)

        Logger.clauntty.debugOnly("NotificationManager: notification tapped for session \(sessionIdString.prefix(8))")
        return sessionId
    }

    // MARK: - Background Task Management

    /// Start a background task to continue SSH processing for ~30 seconds
    func startBackgroundTask() {
        guard backgroundTaskId == .invalid else {
            Logger.clauntty.debugOnly("NotificationManager: background task already running")
            return
        }

        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "SSHProcessing") { [weak self] in
            // Called when time is about to expire
            Logger.clauntty.debugOnly("NotificationManager: background task time expired")
            self?.endBackgroundTask()
        }

        if backgroundTaskId != .invalid {
            let remaining = UIApplication.shared.backgroundTimeRemaining
            // backgroundTimeRemaining can be Double.greatestFiniteMagnitude when not truly backgrounded
            let remainingStr = remaining > 1000 ? "unlimited" : "\(Int(remaining))s"
            Logger.clauntty.debugOnly("NotificationManager: started background task, remaining time: \(remainingStr)")
        } else {
            Logger.clauntty.warning("NotificationManager: failed to start background task")
        }
    }

    /// End the background task
    func endBackgroundTask() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
        Logger.clauntty.debugOnly("NotificationManager: ended background task")
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Handle notification when app is in foreground (shouldn't happen, but just in case)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Don't show notifications when app is in foreground
        return []
    }

    /// Handle notification tap - stores pending session, app handles switch when ready
    /// Using completion handler version to avoid async conflicts with state restoration
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // Extract session ID synchronously
        guard let sessionIdString = userInfo["sessionId"] as? String,
              let sessionId = UUID(uuidString: sessionIdString) else {
            completionHandler()
            return
        }

        // Schedule the storage for after state restoration completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Task { @MainActor in
                self.pendingSessionSwitch = sessionId
                self.pendingSessionIds.remove(sessionId)
                Logger.clauntty.debugOnly("NotificationManager: stored pending session switch to \(sessionId.uuidString.prefix(8))")
            }
        }

        completionHandler()
    }

    /// Process pending session switch (call when app becomes active)
    func processPendingSessionSwitch() {
        guard let sessionId = pendingSessionSwitch else { return }
        pendingSessionSwitch = nil

        Logger.clauntty.debugOnly("NotificationManager: processing pending switch to session \(sessionId.uuidString.prefix(8))")
        NotificationCenter.default.post(
            name: .switchToSession,
            object: nil,
            userInfo: ["sessionId": sessionId]
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let switchToSession = Notification.Name("switchToSession")
}
