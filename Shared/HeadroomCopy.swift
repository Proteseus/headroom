import Foundation

/// User-facing chrome shared by macOS, iOS, and widgets.
///
/// Keep in sync with `docs/glossary.md`. Firmware mirrors the same words via
/// `LABEL_*` constants in `firmware/src/main.cpp`. Data titles (providers,
/// pools, verdicts) still come from the host API.
enum HeadroomCopy {
    static let product = "Headroom"

    // MARK: Navigation & sections

    static let overview = "Overview"
    static let quotas = "Quotas"
    static let codingQuotas = "Coding quotas"
    static let activity = "Activity"
    static let services = "Services"
    static let localServers = "Local servers"
    static let settings = "Settings"
    static let attention = "Attention"

    // MARK: Charts

    static let burndown = "Burndown"
    static let overallBurndown = "Overall burndown"
    static let overallBurndownSubtitle = "7 days"
    static let dailyBurn = "Daily burn"
    static let dailyBurnUnit = "pts / day"

    /// "Resets 3d" — same wording as pool detail captions.
    static func resets(_ label: String) -> String {
        "Resets \(label)"
    }

    /// "42% used" — the rings' reading. Rounded, because a ring drawn to a
    /// tenth of a percent is the same ring.
    static func percentUsed(_ percent: Double) -> String {
        "\(Int(percent.rounded()))% used"
    }

    /// "58% left" — the burndown's reading, which is remaining rather than
    /// used. Both words stay attached to their number wherever the two glyphs
    /// share a surface, so they never look like one figure disagreeing with
    /// itself.
    static func percentLeft(_ percent: Double) -> String {
        "\(Int(percent.rounded()))% left"
    }

    /// "Empty Thu" — the forecast reaches zero before the pool renews.
    ///
    /// The counterpart to `resets(_:)`, and the one that outranks it wherever
    /// only one fits: a pool that runs dry inside the week is the fact worth
    /// spending the wrist's single line on.
    static func empty(_ label: String) -> String {
        "Empty \(label)"
    }

    static func poolBurndown(_ poolTitle: String) -> String {
        "\(poolTitle) burndown"
    }

    /// "Reset granted · 42 pts back" — the caption under a chart whose curve
    /// restarts mid-week because the provider handed the budget back.
    static let resetGranted = "Reset granted"

    static func resetGranted(forgivenPct: Double?) -> String {
        guard let forgivenPct, forgivenPct >= 1 else { return resetGranted }
        return "\(resetGranted) · \(Int(forgivenPct.rounded())) pts back"
    }

    // MARK: Status

    /// Healthy attention summary from the host / Attention card fallback.
    static let allClear = "All clear"
    static let needsAttention = "Needs attention"
    /// iOS link health when the Mac host is reachable.
    static let connected = "Connected"
    static let macUnavailable = "Mac unavailable"
    static let collectingHistory = "Collecting history"
    /// Host just answered again; sources are being kicked so meters move.
    static let reconnecting = "Reconnecting…"
    /// In-flight poll / sync while the link is already healthy.
    static let refreshing = "Refreshing…"
    static let clearAttention = "Clear"
    static let refreshAll = "Refresh all"

    /// Shown when the phone is drawing its last saved payload because the Mac
    /// is not answering. The numbers are real, they are just not current, and
    /// the copy has to say which.
    static let recentHistory = "Recent history"
    static let recentHistoryHint = "Saved on this iPhone. Not live."
    static let nothingSavedYet = "Nothing saved yet"

    /// "Recent history · 2 hours ago" — one label, both facts.
    static func recentHistory(age: TimeInterval) -> String {
        "\(recentHistory) · \(ago(age))"
    }

    /// Coarse on purpose: "4 minutes ago" on a quota bar reads as precision
    /// the saved number does not have.
    static func ago(_ age: TimeInterval) -> String {
        let minutes = Int((age / 60).rounded())
        if minutes < 2 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = Int((age / 3600).rounded())
        if hours < 24 { return hours == 1 ? "1 hour ago" : "\(hours) hours ago" }
        let days = Int((age / 86_400).rounded())
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// A meter the Mac is replaying instead of fetching. The word alone reads
    /// as a hiccup you can wait out, so the age travels with it — "2 hours
    /// ago" is what turns it into something to go and fix.
    static let notUpdating = "Not updating"

    static func notUpdating(age: TimeInterval) -> String {
        "\(notUpdating) · \(ago(age))"
    }

    // MARK: Activity feed

    /// What a feed row's host status (`failure`, `ready`, `pushed`, …) is
    /// called out loud. Every row says its state in words as well as colour,
    /// so a red dot is never carrying the fact on its own.
    /// `Shared/ActivityStatus.swift` owns the mapping.
    static let activityFailed = "Failed"
    static let activityBuilding = "Building"
    static let activityRunning = "Running"
    static let activityQueued = "Queued"
    static let activityDeployed = "Deployed"
    static let activityPassed = "Passed"
    static let activityCanceled = "Canceled"
    /// Feed label for a quota the provider handed back early.
    static let activityReset = "Reset"
    static let activityPushed = "Pushed"
    static let activityLocal = "Local"
    static let activityCommitted = "Committed"

    /// "2 need attention" — the feed's own count, above the rows, so the
    /// answer to "is anything broken" doesn't depend on scanning dots.
    static func needsAttention(count: Int) -> String {
        count == 1 ? "1 needs attention" : "\(count) need attention"
    }

    // MARK: Empty states

    static let noHistoryYet = "No history yet"
    static let noBurnHistoryYet = "No burn history yet"
    static let noCodingSources = "No coding sources"
    static let noActivityYet = "No activity yet"
    static let noLocalServers = "No local servers"
    static let waitingForMacSync = "Waiting for Mac sync"
    static let searchingNearby = "Searching…"

    // MARK: Sources

    static let githubActions = "GitHub Actions"

    /// The two halves of Sources. AI tools meter a plan you're signed into;
    /// dev tools watch projects you connect with a key. Keep them apart.
    static let aiTools = "AI coding tools"
    static let aiToolsHint = "Signed in on this Mac. Nothing to paste."
    static let devTools = "Dev tools"
    static let devToolsHint = "Projects and pipelines. Some need a key."

    // MARK: Widget

    static let openToSync = "Open to sync"
    static let openHeadroom = "Open Headroom"

    // MARK: Watch

    /// The watch's empty state. It cannot reach the Mac itself — the phone
    /// forwards what it fetched — so "open Headroom" has to say where.
    static let openOnPhone = "Open Headroom on iPhone"
    /// Header above the combined dial on the watch app's one screen.
    static let onePerProvider = "One ring per source"
}
