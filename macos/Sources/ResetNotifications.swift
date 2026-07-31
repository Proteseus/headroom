import Foundation
import UserNotifications

/// Posts a Notification Center alert when a quota pool comes back early.
///
/// Off by default, and it asks for authorization only when the toggle is turned
/// on. A menu bar app that requests notification permission at first launch is
/// asking for something it has not yet earned, and the answer is remembered for
/// the life of the install — so the prompt waits until the reader has said they
/// want this.
///
/// The "is this new" rule lives in `ResetAnnouncer`, shared with the phone.
@MainActor
enum ResetNotifications {
    static let defaultsKey = "notifyOnQuotaReset"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// Announce any grant this Mac has not announced yet.
    ///
    /// A grant is marked only once the post is accepted. Marking on the way in
    /// would drop the event entirely whenever authorization is still pending,
    /// which is exactly the poll right after the toggle goes on.
    static func announce(_ snapshot: UsageSnapshot) async {
        guard isEnabled else { return }
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
        guard !pending.isEmpty else { return }

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
}
