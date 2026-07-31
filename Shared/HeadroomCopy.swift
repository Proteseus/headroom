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
    static let otherMacs = "Other Macs"
    static let settings = "Settings"
    static let about = "About"
    static let attention = "Attention"

    // MARK: Settings panes
    //
    // Shared taxonomy for the Mac sidebar / iOS Settings stack. Welcome uses
    // friendlier rail titles for the same ideas (see `SettingsDestination`).

    static let settingsGeneral = "General"
    static let settingsSources = "Sources"
    static let settingsiPhone = "iPhone"
    static let settingsIntegrations = "Integrations"
    static let settingsConnection = "Connection"
    static let settingsPermissions = "Permissions"
    /// macOS Settings → General. Matches System Settings → Login Items wording.
    static let openAtLogin = "Open at Login"
    static let openLoginItemsSettings = "Open Login Items…"
    /// Welcome rail / first-run heading for the Sources step.
    static let welcomeWhatToWatch = "What to watch"
    /// Welcome rail for the iPhone step — Settings keeps the short “iPhone”.
    static let welcomeOnYourPhone = "On your phone"

    /// Person who made it (LICENSE copyright holder).
    static let createdBy = "Created by Michell Zappa"
    /// App Store / signing entity — secondary to the personal credit.
    static let publisher = "Centaur Labs"

    // MARK: Charts

    static let burndown = "Burndown"
    static let overallBurndown = "Overall burndown"

    // Every burndown says which frame it draws, because there are two and they
    // disagree on purpose. The overview is anchored to the clock (it has no
    // single window to anchor to, which is also why it has no budget line); a
    // provider chart is anchored to its window. Unlabelled, the pair reads as
    // one chart that keeps changing its mind. `frameLabel` on each Domain
    // picks the string, so no surface writes these words itself.

    /// Overview subtitle. Says the anchor, not just the span: the old "7 days"
    /// left a reader guessing whether that meant the week behind, the week
    /// ahead, or the one around them. The domain is three days either side of
    /// today, so say so — see `OverallBurndownChartMath.lookbackDays`.
    static let overallBurndownSubtitle = "7 days around today"
    /// Duration form of the same fact, for the watch, where the long form
    /// wraps to two lines under a chart 62pt tall.
    static let overallBurndownSubtitleShort = "±3d"
    /// Provider-chart subtitle: the plot spans this pool's whole window, from
    /// its start to its reset, which is what the budget diagonal measures.
    static let windowFrame = "This window"
    /// Provider-chart subtitle for a monthly pool, where the whole window will
    /// not fit seven weekday columns and the plot is a slice inside it. Not
    /// "around today" — the slice is clamped by the window's edges, so at the
    /// start and end of a month it is not centred on today at all.
    static let windowSliceFrame = "7 days of this window"

    static let dailyBurn = "Daily burn"

    /// The token-value card. "Spend" and not "Cost", because on a
    /// subscription this is what the same work would have cost on the API,
    /// which is a value and not a bill.
    static let spend = "Spend"
    /// Every figure on that card is derived from local token counts and a
    /// price table, never from a provider's billing. It says so on the card
    /// rather than in a tooltip: nobody audits a percentage against a card
    /// statement, and everybody audits a dollar. See docs/metering.md.
    static let spendEstimated = "Estimated"
    static let spendToday = "today"
    static let spendPerActiveDay = "per active day"
    /// Shown only when a model burned tokens that `pricing.py` has no rates
    /// for, so part of the figure came from the fallback rate. The names are
    /// the fix, so the names are what it shows.
    static let spendUnpriced = "Unpriced"
    /// Percentage points of a quota window, per day — the same quantity the
    /// host writes as `%/day`. Never "pts": every provider bills in a real
    /// unit of its own called points, credits, or premium requests, and a
    /// reader with those numbers open in another tab will take this for one
    /// of them. Percent is the only unit Headroom claims.
    static let dailyBurnUnit = "% / day"

    /// "Resets 3d" — duration form, for surfaces too narrow for a weekday and
    /// a clock. Host prose says the same instant as "resets Thu 14:00"; see
    /// docs/glossary.md, "Telling time", for which surface gets which.
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

    /// "Reset granted · 42% back" — caption on the Codex burndown when a
    /// mid-window grant restarted the curve. Not shown on Overview.
    ///
    /// Percent, not "pts", even though Codex itself grants credits: the number
    /// here is a share of the window this chart draws, and borrowing the
    /// provider's unit for a figure that isn't in it is the worse lie.
    static let resetGranted = "Reset granted"

    static func resetGranted(forgivenPct: Double?) -> String {
        guard let forgivenPct, forgivenPct >= 1 else { return resetGranted }
        return "\(resetGranted) · \(Int(forgivenPct.rounded()))% back"
    }

    static func resetCreditExpires(_ label: String) -> String {
        "Reset credit expires \(label)"
    }

    /// Header over the list of past grants on a pool's detail card. "Recent"
    /// rather than "All": the list only reaches as far back as the sample log
    /// was kept, and promising a complete record would be a lie the first time
    /// retention drops something off the end.
    static let resetHistory = "Recent resets"

    /// The amount half of a reset history row — the date carries the rest.
    /// Falls back to the bare noun when a grant handed back too little to
    /// round to a point, which happens when a window rolls near empty.
    static func resetPointsBack(_ forgivenPct: Double?) -> String {
        guard let forgivenPct, forgivenPct >= 1 else { return "reset" }
        return "\(Int(forgivenPct.rounded())) pts back"
    }

    /// Shown in place of the list before any grant has been seen. Codex resets
    /// are something you spend a credit on, so an empty list is the normal
    /// state, not a missing-data state.
    static let noResetsYet = "No resets yet"

    /// Settings toggle, both platforms.
    static let notifyOnQuotaReset = "Notify when a quota resets"

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
    static let answerCodingAgents = "Answer coding agents"
    static let codingAgents = "Coding agents"
    static let claudeCodeHooks = "Claude Code hooks"
    static let installHooks = "Install hooks"
    static let reinstallHooks = "Reinstall hooks"
    static let removeHooks = "Remove hooks"
    /// Adds one harmless Claude row to the common feed. Named for what it
    /// does: "attention" is the card's name and the API's table, not a thing
    /// you can have one of and send.
    static let sendTestAttention = "Add a test row"
    static func usingCodex(at path: String) -> String {
        "Using Codex at \(path)"
    }

    /// The agent's own request, shown before you answer it. An approval you
    /// cannot read is not an approval, so these labels sit above the actual
    /// fields rather than a paraphrase of them.
    static let agentRequest = "Request"
    static let agentWhyAsking = "Why"
    static let showFullRequest = "Show request"
    static let hideFullRequest = "Hide request"
    /// Said plainly: the value on screen is a prefix, not the whole thing.
    static let agentValueShortened = "Shortened to fit"
    /// Shown beside an always-allow answer. A durable grant made from a phone
    /// should say exactly what it will write before you tap it.
    static let agentWouldSaveRule = "Saves the rule"
    /// The free-text answer. None of the fixed buttons is ever quite the
    /// thing you want to say, so every request that has a channel for words
    /// offers one.
    static let agentReplyPlaceholder = "Reply to the agent…"
    /// A question shows in both places and is answered where it was asked.
    static let answerInTheTerminal = "Answer in the terminal"

    /// Giving an agent work, rather than answering work it already started.
    static let startTask = "Start task"
    static let startTaskAgent = "Agent"
    static let startTaskFolder = "Folder"
    static let startTaskPromptPlaceholder = "What should it do?"
    static let chooseFolder = "Choose folder…"
    /// A phone cannot browse the Mac's disk, so it waits for the Mac to use
    /// one first. Says that, rather than showing an empty picker.
    static let noFoldersYet = "Start one on the Mac first to pick a folder here"
    static let noAgentCanTakeWork = "No agent is connected to take work"

    /// Said after a start succeeds. Both providers answer `ok` and then work
    /// quietly, so without this the surface looked like it had done nothing.
    static func agentIsWorking(_ agent: String, in folder: String) -> String {
        "\(agent) is working in \(folder)"
    }
    /// The Mac has no feed of its own, so it says where the answers arrive.
    static let watchOnPhone = "Requests appear on your iPhone"
    static func agentFieldsOmitted(_ count: Int) -> String {
        count == 1 ? "1 more field not shown" : "\(count) more fields not shown"
    }

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

    /// Compact age for dense rows: "just now", "4m ago", "18h ago", "3d ago".
    /// `ago(_:)` spells the units out, which is right on a card and wrong in
    /// a table column that has to hold eight of them.
    static func agoShort(_ age: TimeInterval) -> String {
        let minutes = Int((age / 60).rounded())
        if minutes < 2 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int((age / 3600).rounded())
        if hours < 24 { return "\(hours)h ago" }
        return "\(Int((age / 86_400).rounded()))d ago"
    }

    // MARK: Sources pane (design 2a "Active vs. Library")

    /// Enabled sources, rich rows with live usage.
    static let sourcesActive = "Active"
    /// Everything available but off, as compact chips.
    static let sourcesLibrary = "Library"
    static let sourcesActiveHint = "Drag to reorder · ①②③ show in the menu bar"
    static let sourcesLibraryHint = "Turn one on to move it up to Active"
    /// Sends a service from Active back to the Library. Tracking stops;
    /// credentials are never touched — Headroom has no sign-ins to revoke.
    static let moveToLibrary = "Move to Library"
    /// A paused row: configured, still in Active, not polled.
    static let sourcePaused = "Off"
    /// The inline add link under a multi-account-capable service.
    static let addAccount = "Add account…"
    /// A Library chip whose credential has no local trace to import.
    static let notDetected = "not detected"
    /// Row-subtitle category labels. The Library groups use `aiProvidersGroup`
    /// / `devTools`; in Active the category is metadata riding the subtitle.
    static let aiProviderCategory = "AI provider"
    static let devToolCategory = "Dev tool"
    /// Library group header for the coding side. Distinct from `aiTools`
    /// ("AI coding tools"), which titles onboarding's checklist.
    static let aiProvidersGroup = "AI providers"

    /// A meter the Mac is replaying instead of fetching. The word alone reads
    /// as a hiccup you can wait out, so the age travels with it — "2 hours
    /// ago" is what turns it into something to go and fix.
    static let notUpdating = "Not updating"

    static func notUpdating(age: TimeInterval) -> String {
        "\(notUpdating) · \(ago(age))"
    }

    /// A meter whose login is gone or refused. "Not updating" is true of this
    /// too, and useless: it reads as a connection to wait out, when the fetch
    /// will keep failing until someone signs in. The age still travels with
    /// it, because how long the numbers have been fiction is the part that
    /// decides whether this matters now.
    static let needsSignIn = "Needs sign-in"

    static func needsSignIn(age: TimeInterval) -> String {
        "\(needsSignIn) · \(ago(age))"
    }

    // MARK: Service health
    //
    // Supabase, Plausible, and the Supabase advisors, on the same axis as
    // source health above: does the reader wait, or go and do something.
    //
    // These three used to say "Supabase unavailable". That word was carrying
    // a missing key, a failed fetch, and a Mac that wasn't answering, and it
    // named none of them — a reader who has not pasted a token and a reader
    // whose network blipped got the same sentence. The host's own `error`
    // string still wins when there is one; this is the fallback for when
    // there isn't.

    /// No credential yet. `configured == false` on the service payload.
    static func serviceNeedsKey(_ service: String) -> String {
        "\(service) needs a key"
    }

    /// Configured, and it did not answer. Nothing for the reader to do.
    static func serviceNotReporting(_ service: String) -> String {
        "\(service) not reporting"
    }

    /// Picks between the two so no surface has to, the way `statusNote` does
    /// for sources.
    static func serviceStatus(_ service: String, configured: Bool?) -> String {
        configured == false ? serviceNeedsKey(service) : serviceNotReporting(service)
    }

    /// The provider didn't name the plan. Not a failure and not actionable —
    /// the status label beside it already says whether anything is wrong — so
    /// it says what it knows rather than borrowing an alarm word.
    static let planUnknown = "Plan unknown"

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
    static let noSpendYet = "No spend recorded yet"
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

    // MARK: Welcome

    /// First-run chrome. Only the names that appear in more than one place
    /// live here — the pane prose is macOS-only and stays in `WelcomeView`,
    /// which keeps forty strings out of the watch and widget binaries.
    static let welcomeTitle = "Welcome to Headroom"
    static let welcomeFinish = "Start using Headroom"
    static let showWelcome = "Show welcome"
    /// The callout that points at the menu bar icon on first run.
    static let welcomeCoachMark = "Headroom lives here"

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
