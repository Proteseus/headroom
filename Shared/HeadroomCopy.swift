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

    static func poolBurndown(_ poolTitle: String) -> String {
        "\(poolTitle) burndown"
    }

    // MARK: Status

    /// Healthy attention summary from the host / Attention card fallback.
    static let allClear = "All clear"
    static let needsAttention = "Needs attention"
    /// iOS link health when the Mac host is reachable.
    static let connected = "Connected"
    static let macUnavailable = "Mac unavailable"
    static let collectingHistory = "Collecting history"
    static let clearAttention = "Clear"
    static let refreshAll = "Refresh all"

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
}
