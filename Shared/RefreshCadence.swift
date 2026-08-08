import Foundation

/// Retry pacing after a failed poll, shared by both stores.
///
/// The Mac's popover loop and the phone's live loop back off the same way:
/// a failed poll most often means the host is mid-restart, which takes
/// seconds — so the next attempt comes fast and doubles up to `retryCeiling`
/// rather than sitting out a full cadence with dead meters. The two copies
/// this replaces had matched only because nobody had edited one of them yet.
struct RefreshCadence {
    /// Ceiling for the fast retry. Long enough that a machine with no host
    /// installed isn't spinning, short enough that a host which comes back
    /// is on screen before anyone reaches for the menu bar.
    static let retryCeiling: TimeInterval = 30

    private(set) var consecutiveFailures = 0

    mutating func noteSuccess() {
        consecutiveFailures = 0
    }

    mutating func noteFailure() {
        consecutiveFailures += 1
    }

    /// The backoff interval while polls are failing, or nil after a success —
    /// the caller's own cadence (configured interval, idle floor) applies.
    var retryInterval: TimeInterval? {
        guard consecutiveFailures > 0 else { return nil }
        return min(
            Self.retryCeiling,
            pow(2, Double(min(consecutiveFailures, 5)))
        )
    }
}
