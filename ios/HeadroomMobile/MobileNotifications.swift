import UserNotifications

enum MobileNotifications {
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
}
