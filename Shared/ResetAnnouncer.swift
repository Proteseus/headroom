import Foundation

/// Decides which granted resets are worth announcing, and remembers which ones
/// already were.
///
/// The host reports every grant it can still see in the sample log — a fortnight
/// of them — on every poll. Announcing that list would fire a notification every
/// ten seconds, so the decision is "which of these is new to *this* device",
/// and it has to survive a relaunch: a menu bar app restarts often enough that
/// keeping the answer in memory would re-announce a week-old reset every time.
///
/// Deliberately free of UserNotifications and of SwiftUI, so the Mac and the
/// phone share one rule about what counts as new and one place to change it.
enum ResetAnnouncer {
    /// Stops a fresh install from announcing a fortnight of history at once.
    /// A grant older than this is something the reader lived through already.
    static let maxAge: TimeInterval = 6 * 60 * 60

    /// Stable per-event key. The grant's own instant, which the host derives
    /// from the sample bucket — so the same reset keys the same on every poll,
    /// and on both devices.
    static func key(provider: String, pool: String, at t: Double) -> String {
        "reset-announced-\(provider).\(pool).\(Int(t))"
    }

    struct Pending: Equatable, Sendable {
        var key: String
        var providerTitle: String
        var poolTitle: String
        var forgivenPct: Double?
        var at: Date
    }

    /// Grants worth announcing right now, oldest first.
    ///
    /// `seen` is asked about each candidate rather than handed a set, so the
    /// caller can back it with whatever it already has — `UserDefaults` on both
    /// platforms today. Nothing is marked here: the caller marks a grant only
    /// once the notification was actually accepted, so a failed post is retried
    /// on the next poll instead of being silently swallowed.
    static func pending(
        burndown: [String: [String: Burndown]]?,
        providerTitles: [String: String] = [:],
        now: Date = Date(),
        seen: (String) -> Bool
    ) -> [Pending] {
        var out: [Pending] = []
        for (providerID, pools) in burndown ?? [:] {
            for (poolID, pool) in pools {
                for reset in pool.resets ?? [] {
                    guard let t = reset.t else { continue }
                    let at = Date(timeIntervalSince1970: t)
                    guard now.timeIntervalSince(at) <= maxAge,
                          at <= now else { continue }
                    let key = key(provider: providerID, pool: poolID, at: t)
                    guard !seen(key) else { continue }
                    out.append(
                        Pending(
                            key: key,
                            providerTitle: providerTitles[providerID]
                                ?? providerID.capitalized,
                            poolTitle: pool.poolTitle,
                            forgivenPct: reset.forgivenPct,
                            at: at
                        )
                    )
                }
            }
        }
        return out.sorted { $0.at < $1.at }
    }

    /// "Codex weekly limits reset" — matches the Activity feed row the host
    /// builds for the same event, so the two never describe it differently.
    static func title(_ pending: Pending) -> String {
        "\(pending.providerTitle) \(pending.poolTitle.lowercased()) limits reset"
    }

    static func body(_ pending: Pending) -> String {
        HeadroomCopy.resetPointsBack(pending.forgivenPct)
    }
}
