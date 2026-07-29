import SwiftUI

/// One vocabulary for every row in the merged Activity feed.
///
/// Status arrives from the host as a bare string (`failure`, `ready`,
/// `pushed`, …) and each surface used to decide on its own what that meant:
/// the Mac card painted everything except failures grey, so a production
/// deploy and an unpushed local commit looked identical, while iOS called a
/// pushed commit green — the same colour it gave a healthy deploy. Both now
/// resolve here, so green means "finished well" on every surface and nothing
/// but a real problem is red.
///
/// Colour is never the only channel: every state also carries a glyph and a
/// word, which is what makes the feed readable in greyscale and to anyone who
/// doesn't separate red from grey.
struct ActivityStatusStyle {
    /// How loudly a row reads. The feed groups on `.attention`, so what is
    /// broken sits above what merely happened.
    enum Weight {
        /// Broken, and yours to fix.
        case attention
        /// In flight. Nothing to do but wait.
        case active
        /// Finished, and finished well.
        case good
        /// Routine bookkeeping — the bulk of the feed on a good day.
        case quiet
    }

    let label: String
    let symbol: String
    let tint: Color
    let weight: Weight

    var needsAttention: Bool { weight == .attention }

    static func resolve(_ status: String?) -> ActivityStatusStyle {
        switch status {
        case "error", "failure":
            ActivityStatusStyle(
                label: HeadroomCopy.activityFailed,
                symbol: "exclamationmark.triangle.fill",
                tint: HeadroomPalette.red,
                weight: .attention
            )
        case "building", "initializing":
            ActivityStatusStyle(
                label: HeadroomCopy.activityBuilding,
                symbol: "hammer.fill",
                tint: HeadroomPalette.amber,
                weight: .active
            )
        case "running":
            ActivityStatusStyle(
                label: HeadroomCopy.activityRunning,
                symbol: "arrow.triangle.2.circlepath",
                tint: HeadroomPalette.amber,
                weight: .active
            )
        case "queued", "pending":
            ActivityStatusStyle(
                label: HeadroomCopy.activityQueued,
                symbol: "clock",
                tint: HeadroomPalette.amber,
                weight: .active
            )
        case "ready":
            ActivityStatusStyle(
                label: HeadroomCopy.activityDeployed,
                symbol: "checkmark.circle.fill",
                tint: HeadroomPalette.green,
                weight: .good
            )
        case "success", "completed":
            ActivityStatusStyle(
                label: HeadroomCopy.activityPassed,
                symbol: "checkmark.circle.fill",
                tint: HeadroomPalette.green,
                weight: .good
            )
        // A quota handed back. Green and `good`, because it is the one row in
        // this feed that is unambiguously in your favour — and `quiet` would
        // sort it in with routine bookkeeping, which a week of budget is not.
        case "granted":
            ActivityStatusStyle(
                label: HeadroomCopy.activityReset,
                symbol: "arrow.clockwise.circle.fill",
                tint: HeadroomPalette.green,
                weight: .good
            )
        // Cancelled is not a failure — nobody has to go look at it — so it
        // stays out of the attention group and out of red.
        case "canceled", "cancelled":
            ActivityStatusStyle(
                label: HeadroomCopy.activityCanceled,
                symbol: "slash.circle",
                tint: HeadroomPalette.dim,
                weight: .quiet
            )
        case "pushed":
            ActivityStatusStyle(
                label: HeadroomCopy.activityPushed,
                symbol: "arrow.up.circle",
                tint: HeadroomPalette.dim,
                weight: .quiet
            )
        case "local":
            ActivityStatusStyle(
                label: HeadroomCopy.activityLocal,
                symbol: "circle.dotted",
                tint: HeadroomPalette.dim,
                weight: .quiet
            )
        case "committed":
            ActivityStatusStyle(
                label: HeadroomCopy.activityCommitted,
                symbol: "circle",
                tint: HeadroomPalette.dim,
                weight: .quiet
            )
        // A status this build has never heard of still gets a word rather
        // than an unexplained dot: the host may ship a new one first.
        default:
            ActivityStatusStyle(
                label: humanized(status),
                symbol: "circle",
                tint: HeadroomPalette.dim,
                weight: .quiet
            )
        }
    }

    private static func humanized(_ status: String?) -> String {
        guard let status, !status.isEmpty else {
            return HeadroomCopy.activityCommitted
        }
        return status.prefix(1).uppercased() + status.dropFirst()
    }
}
