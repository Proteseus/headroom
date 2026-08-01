import Foundation
import UserNotifications

enum MobileNotifications {
    static let agentNotificationTapped = Notification.Name(
        "headroom.agent-notification-tapped"
    )

    static func installDelegate() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    static func agentEventID(
        from userInfo: [AnyHashable: Any]
    ) -> String? {
        userInfo["agent_event_id"] as? String
    }

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])
    }

    static func notifyIfNeeded(_ attention: Attention?) async {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled"),
              let attention,
              attention.isWarning else { return }
        let key = "lastNotifiedAttentionFingerprint"
        guard UserDefaults.standard.string(forKey: key) != attention.fingerprint else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = attention.isCritical ? "Headroom needs attention" : "Headroom warning"
        content.body = attention.summary ?? "Open Headroom for details."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "headroom-attention-\(attention.fingerprint.hashValue)",
            content: content,
            trigger: nil
        )
        if (try? await UNUserNotificationCenter.current().add(request)) != nil {
            UserDefaults.standard.set(attention.fingerprint, forKey: key)
        }
    }

    /// A quota pool that came back early — on Codex, usually a reset credit the
    /// reader spent. Shares the "is this new" rule with the Mac
    /// (`ResetAnnouncer`) so the two devices agree on which grants are news.
    ///
    /// Rides the same `notificationsEnabled` toggle as attention: a second
    /// switch for one event a week is a settings screen nobody can hold in
    /// their head.
    static func notifyIfNeeded(
        resets snapshot: UsageSnapshot
    ) async {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else {
            return
        }
        let defaults = UserDefaults.standard
        let titles = Dictionary(
            uniqueKeysWithValues: (snapshot.providers ?? []).map {
                ($0.id, $0.title ?? $0.id.capitalized)
            }
        )
        let pending = ResetAnnouncer.pending(
            burndown: snapshot.burndown,
            providerTitles: titles,
            seen: { defaults.bool(forKey: $0) }
        )
        for grant in pending {
            let content = UNMutableNotificationContent()
            content.title = ResetAnnouncer.title(grant)
            content.body = ResetAnnouncer.body(grant)
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: grant.key, content: content, trigger: nil
            )
            if (try? await UNUserNotificationCenter.current().add(request))
                != nil {
                defaults.set(true, forKey: grant.key)
            }
        }
    }

    static func notifyIfNeeded(_ events: [AgentAttentionEvent]) async {
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else {
            return
        }
        for event in events where event.state == "pending" {
            let key = "lastNotifiedAgentEvent-\(event.id)"
            guard !UserDefaults.standard.bool(forKey: key) else { continue }
            let content = UNMutableNotificationContent()
            content.title = event.displayTitle
            content.body = event.summary
            content.sound = .default
            var userInfo: [AnyHashable: Any] = ["agent_event_id": event.id]
            if let machineID = event.machineID {
                userInfo["machine_id"] = machineID
            }
            content.userInfo = userInfo
            let request = UNNotificationRequest(
                identifier: "headroom-agent-\(event.id)",
                content: content,
                trigger: nil
            )
            if (try? await UNUserNotificationCenter.current().add(request)) != nil {
                UserDefaults.standard.set(true, forKey: key)
            }
        }
    }

    // The singleton has no mutable state; callbacks are forwarded to
    // NotificationCenter on the main queue. NSObject protocol conformances
    // are not annotated Sendable, so state this invariant explicitly for
    // Swift 6's global-actor checking.
    private final class NotificationDelegate: NSObject,
        UNUserNotificationCenterDelegate, @unchecked Sendable {
        static let shared = NotificationDelegate()

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler:
                @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            // Keep the doorbell visible when the app is already open. The
            // Attention tab is still the place where a response is made.
            completionHandler([.banner, .sound])
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let userInfo = response.notification.request.content.userInfo
            if let eventID = MobileNotifications.agentEventID(from: userInfo) {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: MobileNotifications.agentNotificationTapped,
                        object: nil,
                        userInfo: ["agent_event_id": eventID]
                    )
                }
            }
            completionHandler()
        }
    }
}
