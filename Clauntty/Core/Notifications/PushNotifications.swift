import Foundation
import UIKit
import os.log

/// Push notifications, for when an agent finishes or needs the user after iOS has
/// suspended the app (local notifications only work for the ~30s it keeps running).
///
/// The phone registers its APNs token with Clauntty's push Worker (`push/`) and gets back
/// a device key: the token, encrypted, good for nothing but notifying this phone. Each
/// host gets a line in `~/.clauntty/push` with the Worker's URL, the key and this phone's
/// ID. rtach there posts to the Worker when an agent's state changes and no app is
/// looking (rtach's push.zig).
@MainActor
final class PushNotifications {
    static let shared = PushNotifications()

    static let workerURL = "https://clauntty-push.octerm.app"

    /// This phone in hosts' push files. Kept when the key changes, so its line is replaced.
    let phoneId: String

    /// From the Worker, for the current APNs token
    private(set) var deviceKey: String? {
        didSet { UserDefaults.standard.set(deviceKey, forKey: Keys.deviceKey) }
    }

    /// Hosts should push to this phone: notifications are allowed and it has a key
    var isActive: Bool {
        deviceKey != nil && NotificationManager.shared.isAuthorized && NotificationManager.shared.notificationMode != .none
    }

    private enum Keys {
        static let phoneId = "push_phone_id"
        static let deviceKey = "push_device_key"
    }

    private init() {
        if let id = UserDefaults.standard.string(forKey: Keys.phoneId) {
            phoneId = id
        } else {
            phoneId = UUID().uuidString
            UserDefaults.standard.set(phoneId, forKey: Keys.phoneId)
        }
        deviceKey = UserDefaults.standard.string(forKey: Keys.deviceKey)
    }

    /// Ask iOS for this launch's APNs token (Apple asks for it every launch); it arrives
    /// in `didRegister`. Call once notifications are authorized.
    func register() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(token: Data) async {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        var request = URLRequest(url: URL(string: "\(Self.workerURL)/register")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": hex, "env": environment])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let key = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["key"] as? String
            else {
                Logger.clauntty.error("Push: registering failed: \(String(decoding: data, as: UTF8.self))")
                return
            }
            // A new key for every registration; the old ones still work, so hosts only
            // need the new one when there was none
            let first = deviceKey == nil
            deviceKey = key
            Logger.clauntty.debugOnly("Push: registered (\(environment))")
            if first { hostsChanged() }
        } catch {
            Logger.clauntty.error("Push: registering failed: \(error.localizedDescription)")
        }
    }

    /// Something changed what hosts should have (a key, notifications on or off): the
    /// session manager rewrites the push file on each connected host
    func hostsChanged() {
        NotificationCenter.default.post(name: .pushHostsChanged, object: nil)
    }

    /// The shell command that puts this phone's line in a host's push file, or takes it
    /// out. Nil when there's nothing to do.
    func hostCommand() -> String? {
        let file = "$HOME/.clauntty/push"
        // Every line but this phone's (the key is base64url, the ID a UUID: no quoting needed)
        let others = "grep -v \" \(phoneId)$\" \"$f\" 2>/dev/null"
        if isActive, let deviceKey {
            let line = "\(Self.workerURL) \(deviceKey) \(phoneId)"
            return "sh -c 'f=\(file); umask 077; { \(others); echo \"\(line)\"; } > \"$f.tmp\" && mv \"$f.tmp\" \"$f\"'"
        }
        return "sh -c 'f=\(file); [ -f \"$f\" ] || exit 0; umask 077; \(others) > \"$f.tmp\"; mv \"$f.tmp\" \"$f\"'"
    }
}

/// For the APNs token, which iOS only hands to an app delegate
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await PushNotifications.shared.didRegister(token: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Logger.clauntty.error("Push: no APNs token: \(error.localizedDescription)")
    }
}

extension Notification.Name {
    static let pushHostsChanged = Notification.Name("pushHostsChanged")
}
