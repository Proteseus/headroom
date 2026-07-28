import Foundation

struct UsageSnapshot: Decodable, Sendable {
    var updated: String?
    var plan: String?
    var quotaOK: Bool?
    var quotaError: String?
    var sessionPct: Double?
    var sessionPacePct: Double?
    var sessionResetsIn: String?
    var weekPct: Double?
    var weekPacePct: Double?
    var weekResetsIn: String?
    var today: TokenBucket?
    var byDay: [DailyBurnDay]?
    var codex: CodexUsage?
    var cursor: CursorUsage?
    /// Normalized quota providers from the host registry (additive).
    var providers: [QuotaProviderInfo]?
    var vercel: VercelUsage?
    var git: GitUsage?
    var github: GitHubUsage?
    var activity: [ActivityItem]?
    var local: LocalUsage?
    var supabase: SupabaseUsage?
    var plausible: PlausibleUsage?
    var sources: [SyncSource]?
    var attention: Attention?
    /// Provider ids the compact surfaces show, picked host-side so the menu
    /// bar, the widget, and the board never disagree about which three.
    var focus: [String]?
    /// Per-provider, per-pool burndown keyed as ["claude": ["week": …]].
    var burndown: [String: [String: Burndown]]?
    var burndownPrimary: Burndown?

    static let empty = UsageSnapshot()

    init(
        updated: String? = nil,
        plan: String? = nil,
        quotaOK: Bool? = nil,
        quotaError: String? = nil,
        sessionPct: Double? = nil,
        sessionPacePct: Double? = nil,
        sessionResetsIn: String? = nil,
        weekPct: Double? = nil,
        weekPacePct: Double? = nil,
        weekResetsIn: String? = nil,
        today: TokenBucket? = nil,
        byDay: [DailyBurnDay]? = nil,
        codex: CodexUsage? = nil,
        cursor: CursorUsage? = nil,
        providers: [QuotaProviderInfo]? = nil,
        vercel: VercelUsage? = nil,
        git: GitUsage? = nil,
        github: GitHubUsage? = nil,
        activity: [ActivityItem]? = nil,
        local: LocalUsage? = nil,
        supabase: SupabaseUsage? = nil,
        plausible: PlausibleUsage? = nil,
        sources: [SyncSource]? = nil,
        attention: Attention? = nil,
        burndown: [String: [String: Burndown]]? = nil,
        burndownPrimary: Burndown? = nil
    ) {
        self.updated = updated
        self.plan = plan
        self.quotaOK = quotaOK
        self.quotaError = quotaError
        self.sessionPct = sessionPct
        self.sessionPacePct = sessionPacePct
        self.sessionResetsIn = sessionResetsIn
        self.weekPct = weekPct
        self.weekPacePct = weekPacePct
        self.weekResetsIn = weekResetsIn
        self.today = today
        self.byDay = byDay
        self.codex = codex
        self.cursor = cursor
        self.providers = providers
        self.vercel = vercel
        self.git = git
        self.github = github
        self.activity = activity
        self.local = local
        self.supabase = supabase
        self.plausible = plausible
        self.sources = sources
        self.attention = attention
        self.burndown = burndown
        self.burndownPrimary = burndownPrimary
    }

    enum CodingKeys: String, CodingKey {
        case updated, plan, today, codex, cursor, providers, vercel, git, github, activity, local
        case supabase, plausible, sources, attention, focus, burndown
        case burndownPrimary = "burndown_primary"
        case byDay = "by_day"
        case quotaOK = "quota_ok"
        case quotaError = "quota_error"
        case sessionPct = "session_pct"
        case sessionPacePct = "session_pace_pct"
        case sessionResetsIn = "session_resets_in"
        case weekPct = "week_pct"
        case weekPacePct = "week_pace_pct"
        case weekResetsIn = "week_resets_in"
    }

    /// Enabled coding-quota providers from the host registry (string ids).
    ///
    /// CodexBar-style: Settings → Sources is the subset. Prefer `providers[]`
    /// intersected with enabled quota `sources[]`. Empty when the host has not
    /// advertised any — never invent Claude/Codex/Cursor.
    var visibleQuotaProviders: [QuotaProviderInfo] {
        let sourcesList = sources ?? []
        let hasKind = sourcesList.contains { $0.kind != nil }
        let known = Set(UsageProvider.allCases.map(\.rawValue))

        let quotaSourceRows = sourcesList.filter { row in
            if hasKind { return row.kind == "quota" }
            return known.contains(row.id)
        }
        let enabledQuotaIDs = Set(
            quotaSourceRows.filter { $0.enabled != false }.map(\.id)
        )
        // Sources listed quota rows but the user turned them all off.
        if !quotaSourceRows.isEmpty && enabledQuotaIDs.isEmpty {
            return []
        }

        let rows = providers ?? []
        if !rows.isEmpty {
            return rows.filter {
                $0.enabled != false
                    && (enabledQuotaIDs.isEmpty || enabledQuotaIDs.contains($0.id))
            }
        }

        // Older payloads without providers[]: synthesize from enabled sources.
        guard !enabledQuotaIDs.isEmpty else { return [] }
        var seen = Set<String>()
        return quotaSourceRows.compactMap { row in
            guard enabledQuotaIDs.contains(row.id),
                  seen.insert(row.id).inserted
            else { return nil }
            return QuotaProviderInfo(
                id: row.id,
                title: row.title,
                kind: row.kind ?? "quota",
                enabled: true
            )
        }
    }

    /// The providers a compact surface shows: menu-bar tanks and the iOS
    /// widget.
    ///
    /// The host picks them (pinned order, enabled only) and ships the ids in
    /// `focus`, so every surface shows the same providers even when one of
    /// them is a poll behind. Falls back to the first `limit` visible
    /// providers when talking to a host that predates the field.
    func focusProviders(limit: Int = 3) -> [QuotaProviderInfo] {
        let visible = visibleQuotaProviders
        guard let focus, !focus.isEmpty else {
            return Array(visible.prefix(limit))
        }
        let byID = Dictionary(visible.map { ($0.id, $0) }) { first, _ in first }
        let picked = focus.compactMap { byID[$0] }
        // A focus id the client can't resolve (disabled between polls, or a
        // provider this build doesn't know) must not shrink the row.
        return picked.isEmpty ? Array(visible.prefix(limit))
                              : Array(picked.prefix(limit))
    }

    /// Known-enum view of `visibleQuotaProviders` for Mac chrome still typed
    /// on `UsageProvider`. Unknown registry ids are skipped until those
    /// surfaces take string ids.
    var activeQuotaProviders: [UsageProvider] {
        var seen = Set<String>()
        var out: [UsageProvider] = []
        for row in visibleQuotaProviders {
            guard let provider = UsageProvider(rawValue: row.id),
                  seen.insert(row.id).inserted
            else { continue }
            out.append(provider)
        }
        return out
    }


    func burndownRings(for provider: UsageProvider) -> [Burndown] {
        burndownRings(forProviderID: provider.rawValue)
    }

    /// Pools for one provider in the app-wide pool order: the same selection
    /// and sequence as the progress bars, so rings, bars and burndown charts
    /// can never disagree. Prefer host `ring` flags when the provider
    /// advertised pools; otherwise fall back to known Cursor filters.
    func burndownRings(forProviderID providerID: String) -> [Burndown] {
        let pools = burndown?[providerID] ?? [:]
        if let info = providers?.first(where: { $0.id == providerID }),
           !(info.pools ?? [:]).isEmpty {
            return info.orderedBurndown(from: pools)
        }
        let all = Array(pools.values)
        let visible = providerID == UsageProvider.cursor.rawValue
            ? all.filter { $0.pool == "total" || $0.pool == "api" }
            : all
        return visible.sorted { lhs, rhs in
            let lw = lhs.windowS ?? .greatestFiniteMagnitude
            let rw = rhs.windowS ?? .greatestFiniteMagnitude
            if lw != rw { return lw < rw }
            let li = QuotaProviderInfo.poolPrecedence.firstIndex(
                of: lhs.pool ?? "") ?? QuotaProviderInfo.poolPrecedence.count
            let ri = QuotaProviderInfo.poolPrecedence.firstIndex(
                of: rhs.pool ?? "") ?? QuotaProviderInfo.poolPrecedence.count
            return li < ri
        }
    }

    /// The single pool the combined burndown draws for a provider.
    ///
    /// The longest window, because that is the one a week-wide chart is about
    /// — except Cursor, whose Total is the billing cycle its API pool nests
    /// inside. Cursor's API pool keeps to the Cursor detail chart; four lines
    /// is more than an overview can usefully carry.
    func overviewBurndown(forProviderID providerID: String) -> Burndown? {
        let pools = burndownRings(forProviderID: providerID)
        if providerID == UsageProvider.cursor.rawValue,
           let total = pools.first(where: { $0.pool == "total" }) {
            return total
        }
        return pools.max { ($0.windowS ?? 0) < ($1.windowS ?? 0) }
    }

    func meter(for provider: UsageProvider) -> ProviderMeter {
        meter(forProviderID: provider.rawValue)
    }

    func meter(for info: QuotaProviderInfo) -> ProviderMeter {
        if !(info.pools ?? [:]).isEmpty {
            return meter(fromRegistry: info)
        }
        if let known = UsageProvider(rawValue: info.id) {
            return legacyMeter(for: known)
        }
        return ProviderMeter(
            id: info.id,
            title: info.displayTitle,
            ok: info.ok ?? false,
            plan: info.plan,
            error: info.error,
            primary: MeterWindow(title: "—", percent: nil),
            secondary: MeterWindow(title: "—", percent: nil),
            headlinePoolID: info.headline
        )
    }

    func meter(forProviderID providerID: String) -> ProviderMeter {
        if let info = providers?.first(where: { $0.id == providerID }) {
            return meter(for: info)
        }
        if let known = UsageProvider(rawValue: providerID) {
            return legacyMeter(for: known)
        }
        return ProviderMeter(
            id: providerID,
            title: providerID.capitalized,
            ok: false,
            primary: MeterWindow(title: "—", percent: nil),
            secondary: MeterWindow(title: "—", percent: nil)
        )
    }

    /// Schema-driven meter from `/usage` → `providers[]`. Cost / reset-credit
    /// extras still come from the legacy nested objects until the host folds
    /// them into the registry payload.
    private func meter(fromRegistry info: QuotaProviderInfo) -> ProviderMeter {
        let windows = info.visiblePools.map { entry in
            MeterWindow(
                id: entry.id,
                title: entry.pool.title ?? entry.id.capitalized,
                percent: entry.pool.pct,
                pacePercent: entry.pool.pacePct,
                reset: entry.pool.resetsIn
            )
        }
        let primary = windows.first ?? MeterWindow(title: "—", percent: nil)
        let secondary = windows.count > 1
            ? windows[1]
            : MeterWindow(title: "—", percent: nil)
        let tertiary = windows.count > 2 ? windows[2] : nil

        var paceLabel: String?
        var runsOutIn: String?
        var resetCreditsLabel: String?
        var resetCreditsExpiryLabel: String?
        var costLabel: String?
        switch info.id {
        case UsageProvider.claude.rawValue:
            costLabel = today?.costUSD.map { $0.dollarLabel + " today" }
        case UsageProvider.codex.rawValue:
            paceLabel = codex?.paceLabel
            runsOutIn = codex?.runsOutIn
            resetCreditsLabel = codex?.resetCreditsLabel
            resetCreditsExpiryLabel = codex?.resetCreditsExpiryLabel
            costLabel = codex?.costLabel
        case UsageProvider.cursor.rawValue:
            paceLabel = cursor?.paceLabel
            costLabel = cursorCostLabel
        default:
            break
        }

        return ProviderMeter(
            id: info.id,
            title: info.displayTitle,
            ok: info.ok ?? false,
            plan: info.plan,
            error: info.error,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            paceLabel: paceLabel,
            runsOutIn: runsOutIn,
            resetCreditsLabel: resetCreditsLabel,
            resetCreditsExpiryLabel: resetCreditsExpiryLabel,
            costLabel: costLabel,
            headlinePoolID: info.headline
        )
    }

    private func legacyMeter(for provider: UsageProvider) -> ProviderMeter {
        switch provider {
        case .claude:
            ProviderMeter(
                provider: provider,
                ok: quotaOK ?? false,
                plan: plan,
                error: quotaError,
                primary: MeterWindow(
                    id: "session",
                    title: "Session",
                    percent: sessionPct,
                    pacePercent: sessionPacePct,
                    reset: sessionResetsIn
                ),
                secondary: MeterWindow(
                    id: "week",
                    title: "Weekly",
                    percent: weekPct,
                    pacePercent: weekPacePct,
                    reset: weekResetsIn
                ),
                costLabel: today?.costUSD.map {
                    $0.dollarLabel + " today"
                },
                headlinePoolID: "week"
            )
        case .codex:
            ProviderMeter(
                provider: provider,
                ok: codex?.ok ?? false,
                plan: codex?.plan,
                error: codex?.error,
                primary: MeterWindow(
                    id: "session",
                    title: "Session",
                    percent: codex?.sessionPct,
                    pacePercent: codex?.sessionPacePct,
                    reset: codex?.sessionResetsIn
                ),
                secondary: MeterWindow(
                    id: "week",
                    title: "Weekly",
                    percent: codex?.weekPct,
                    pacePercent: codex?.weekPacePct,
                    reset: codex?.weekResetsIn
                ),
                paceLabel: codex?.paceLabel,
                runsOutIn: codex?.runsOutIn,
                resetCreditsLabel: codex?.resetCreditsLabel,
                resetCreditsExpiryLabel: codex?.resetCreditsExpiryLabel,
                costLabel: codex?.costLabel,
                headlinePoolID: "week"
            )
        case .cursor:
            // Total (included) and API (on-demand) are independent pools that
            // share a billing cycle. Auto is omitted — it sits at 0% for most
            // plans and used to steal the second ring from API.
            ProviderMeter(
                provider: provider,
                ok: cursor?.ok ?? false,
                plan: cursor?.plan,
                primary: MeterWindow(
                    id: "total",
                    title: "Total",
                    percent: cursor?.totalPct,
                    pacePercent: cursor?.totalPacePct,
                    reset: cursor?.resetsIn
                ),
                secondary: MeterWindow(
                    id: "api",
                    title: "API",
                    percent: cursor?.apiPct,
                    pacePercent: cursor?.apiPacePct,
                    reset: cursor?.resetsIn
                ),
                paceLabel: cursor?.paceLabel,
                costLabel: cursorCostLabel,
                headlinePoolID: "total"
            )
        }
    }

    private var cursorCostLabel: String? {
        let plan = cursor?.costLabel
        let onDemand = cursor?.onDemandLabel
        switch (plan, onDemand) {
        case let (plan?, onDemand?):
            return "\(plan) · \(onDemand)"
        case let (plan?, nil):
            return plan
        case let (nil, onDemand?):
            return onDemand
        default:
            return nil
        }
    }
}

/// One pool's burndown. Series arrive as compact [[epoch, remainingPct], …]
/// pairs rather than objects, because this rides the same document the board
/// pulls over USB CDC.
struct Burndown: Decodable, Sendable, Identifiable {
    var provider: String?
    var pool: String?
    var windowStart: Double?
    var windowEnd: Double?
    var windowS: Double?
    var remainingPct: Double?
    var usedPct: Double?
    var idealRemainingPct: Double?
    var deltaPct: Double?
    var inDeficit: Bool?
    var exhausted: Bool?
    var status: String?
    var resetsIn: String?
    var ideal: [[Double]]?
    var actual: [[Double]]?
    var projected: [[Double]]?
    var rateUnit: String?
    /// "measured" from real samples, "estimated" from token history, nil when
    /// there is nothing to go on yet.
    var rateSource: String?
    var burnRatePct: Double?
    var allowancePct: Double?
    var exhaustsAt: Double?
    var exhaustsIn: String?
    var exhaustsBeforeReset: Bool?
    var samples: Int?
    /// Prose, for VoiceOver and for surfaces with room for only one line.
    var headline: String?
    /// The same situation as a short phrase, for a card that shows the numbers
    /// in a stat row beside it rather than inside the sentence.
    var verdict: String?

    var id: String { "\(provider ?? "?").\(pool ?? "?")" }

    /// Rings and bars elsewhere in the app grow with consumption, so the ring
    /// draws used percent even though the chart itself is a burndown.
    var pacePercent: Double? { idealRemainingPct.map { 100 - $0 } }

    var kind: BurndownStatus {
        BurndownStatus(rawValue: status ?? "") ?? .ok
    }

    /// A fit needs history; until then every forecast field is nil by design.
    var hasForecast: Bool { burnRatePct != nil }

    /// Forecast rests on the token-history prior, not on measured samples.
    var isEstimated: Bool { rateSource == "estimated" }

    var poolTitle: String {
        switch pool {
        case "session": "Session"
        case "week": "Weekly"
        case "total": "Total"
        case "auto": "Auto"
        case "api": "API"
        default: pool?.capitalized ?? "—"
        }
    }

    /// Projected [[t, remaining], …] stopped at the held reset and at empty.
    ///
    /// The host already crops this way; clients re-apply so a stale or demo
    /// payload cannot draw a forecast through a renewal (or under the floor).
    var croppedProjected: [[Double]] {
        Self.cropProjection(projected, windowEnd: windowEnd)
    }

    /// Crop a pool's forecast at its reset and at empty. The implementation
    /// lives with the rest of the chart geometry, in `BurndownChartMath`.
    static func cropProjection(
        _ pairs: [[Double]]?,
        windowEnd: Double?
    ) -> [[Double]] {
        OverallBurndownChartMath.cropProjection(pairs, windowEnd: windowEnd)
    }

    enum CodingKeys: String, CodingKey {
        case provider, pool, status, ideal, actual, projected, samples, headline
        case exhausted, verdict
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case windowS = "window_s"
        case remainingPct = "remaining_pct"
        case usedPct = "used_pct"
        case idealRemainingPct = "ideal_remaining_pct"
        case deltaPct = "delta_pct"
        case inDeficit = "in_deficit"
        case resetsIn = "resets_in"
        case rateUnit = "rate_unit"
        case rateSource = "rate_source"
        case burnRatePct = "burn_rate_pct"
        case allowancePct = "allowance_pct"
        case exhaustsAt = "exhausts_at"
        case exhaustsIn = "exhausts_in"
        case exhaustsBeforeReset = "exhausts_before_reset"
    }
}

enum BurndownStatus: String, Sendable {
    case ok
    case ahead
    case critical
    case exhausted
}

enum UsageProvider: String, CaseIterable, Sendable {
    case claude
    case codex
    case cursor

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
}

struct ProviderMeter: Sendable {
    var id: String
    var title: String
    var ok: Bool
    var plan: String?
    var error: String?
    var primary: MeterWindow
    var secondary: MeterWindow
    var tertiary: MeterWindow?
    var paceLabel: String?
    var runsOutIn: String?
    /// Codex limit-reset credit inventory, e.g. "2 reset credits".
    var resetCreditsLabel: String?
    /// Joined expiry countdowns for those credits, e.g. "6d 5h · 18d 3h".
    var resetCreditsExpiryLabel: String?
    var costLabel: String?
    /// Host registry headline pool id (`week`, `total`, …) for menu-bar tanks.
    var headlinePoolID: String?

    var knownProvider: UsageProvider? { UsageProvider(rawValue: id) }

    init(
        id: String,
        title: String,
        ok: Bool,
        plan: String? = nil,
        error: String? = nil,
        primary: MeterWindow,
        secondary: MeterWindow,
        tertiary: MeterWindow? = nil,
        paceLabel: String? = nil,
        runsOutIn: String? = nil,
        resetCreditsLabel: String? = nil,
        resetCreditsExpiryLabel: String? = nil,
        costLabel: String? = nil,
        headlinePoolID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.ok = ok
        self.plan = plan
        self.error = error
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.paceLabel = paceLabel
        self.runsOutIn = runsOutIn
        self.resetCreditsLabel = resetCreditsLabel
        self.resetCreditsExpiryLabel = resetCreditsExpiryLabel
        self.costLabel = costLabel
        self.headlinePoolID = headlinePoolID
    }

    /// Compatibility for call sites still typed on the known-provider enum.
    init(
        provider: UsageProvider,
        ok: Bool,
        plan: String? = nil,
        error: String? = nil,
        primary: MeterWindow,
        secondary: MeterWindow,
        tertiary: MeterWindow? = nil,
        paceLabel: String? = nil,
        runsOutIn: String? = nil,
        resetCreditsLabel: String? = nil,
        resetCreditsExpiryLabel: String? = nil,
        costLabel: String? = nil,
        headlinePoolID: String? = nil
    ) {
        self.init(
            id: provider.rawValue,
            title: provider.title,
            ok: ok,
            plan: plan,
            error: error,
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            paceLabel: paceLabel,
            runsOutIn: runsOutIn,
            resetCreditsLabel: resetCreditsLabel,
            resetCreditsExpiryLabel: resetCreditsExpiryLabel,
            costLabel: costLabel,
            headlinePoolID: headlinePoolID
        )
    }

    private var allWindows: [MeterWindow] {
        [primary, secondary, tertiary].compactMap { $0 }
    }

    /// Window shown as the provider's headline signal (menu bar + overview rings).
    var headline: MeterWindow {
        if let headlinePoolID,
           let match = allWindows.first(where: { $0.id == headlinePoolID }) {
            return match
        }
        if id == UsageProvider.cursor.rawValue {
            return primary
        }
        return allWindows.max { ($0.percent ?? -1) < ($1.percent ?? -1) }
            ?? primary
    }

    /// Long-window tank for the menu-bar icon (Weekly / Total / host headline).
    var menuBarWindow: MeterWindow {
        if let headlinePoolID,
           let match = allWindows.first(where: { $0.id == headlinePoolID }) {
            return match
        }
        return id == UsageProvider.cursor.rawValue ? primary : secondary
    }
}

struct MeterWindow: Sendable {
    var id: String?
    var title: String
    var percent: Double?
    var pacePercent: Double?
    var reset: String?

    init(
        id: String? = nil,
        title: String,
        percent: Double?,
        pacePercent: Double? = nil,
        reset: String? = nil
    ) {
        self.id = id
        self.title = title
        self.percent = percent
        self.pacePercent = pacePercent
        self.reset = reset
    }
}

struct TokenBucket: Decodable, Sendable {
    var total: Int?
    var costUSD: Double?

    enum CodingKeys: String, CodingKey {
        case total
        case costUSD = "cost_usd"
    }
}

struct DailyBurnDay: Decodable, Sendable, Identifiable {
    var date: String
    var claude: Double?
    var codex: Double?
    var cursor: Double?
    var total: Double?
    /// Dynamic map mirroring host `by_day[].burns` (preferred when present).
    var burns: [String: Double]?

    var id: String { date }

    func burn(for provider: UsageProvider) -> Double {
        burn(forProviderID: provider.rawValue)
    }

    func burn(forProviderID providerID: String) -> Double {
        if let burns, let value = burns[providerID] {
            return value
        }
        switch providerID {
        case UsageProvider.claude.rawValue: return claude ?? 0
        case UsageProvider.codex.rawValue: return codex ?? 0
        case UsageProvider.cursor.rawValue: return cursor ?? 0
        default: return 0
        }
    }

    /// Total across the given providers (enabled set), not every column.
    func total(for providers: [UsageProvider]) -> Double {
        total(forProviderIDs: providers.map(\.rawValue))
    }

    func total(forProviderIDs providerIDs: [String]) -> Double {
        if providerIDs.isEmpty { return total ?? 0 }
        return providerIDs.reduce(0) { $0 + burn(forProviderID: $1) }
    }
}

/// One coding-quota provider as advertised by the host registry.
struct QuotaProviderInfo: Decodable, Identifiable, Sendable {
    var id: String
    var title: String?
    var kind: String?
    /// Position in the user's pinned order. The host already sorted
    /// `providers[]`; this is here so a client that re-sorts can't drift.
    var rank: Int?
    var enabled: Bool?
    var ok: Bool?
    var plan: String?
    var error: String?
    var accent: String?
    /// The registry's own color, before any Settings override. Settings marks
    /// this swatch "Default"; everything else just paints `accent`.
    var accentDefault: String?
    var headline: String?
    var pools: [String: QuotaPoolInfo]?

    init(
        id: String,
        title: String? = nil,
        kind: String? = nil,
        rank: Int? = nil,
        enabled: Bool? = nil,
        ok: Bool? = nil,
        plan: String? = nil,
        error: String? = nil,
        accent: String? = nil,
        accentDefault: String? = nil,
        headline: String? = nil,
        pools: [String: QuotaPoolInfo]? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.rank = rank
        self.enabled = enabled
        self.ok = ok
        self.plan = plan
        self.error = error
        self.accent = accent
        self.accentDefault = accentDefault
        self.headline = headline
        self.pools = pools
    }

    enum CodingKeys: String, CodingKey {
        case id, title, kind, rank, enabled, ok, plan, error, accent
        case headline, pools
        case accentDefault = "accent_default"
    }

    var displayTitle: String { title ?? id.capitalized }

    /// Fallback pool order for hosts that predate `pools[].rank`. It only
    /// names the pools those hosts could serve — Copilot, Gemini, JetBrains
    /// and Zed all arrived with the rank field, so they never land here.
    static let poolPrecedence = ["session", "total", "api", "auto", "week"]

    /// Rank a pool for sorting: the host's declared order when it sent one,
    /// otherwise the legacy precedence list, otherwise last.
    static func poolRank(id: String, pool: QuotaPoolInfo) -> Int {
        if let rank = pool.rank { return rank }
        return poolPrecedence.firstIndex(of: id) ?? poolPrecedence.count
    }

    /// Ring pools in the host's declared order — the single sequence rings,
    /// progress bars and burndown charts all draw in.
    var visiblePools: [(id: String, pool: QuotaPoolInfo)] {
        (pools ?? [:])
            .filter { $0.value.ring != false }
            .sorted {
                let lhs = Self.poolRank(id: $0.key, pool: $0.value)
                let rhs = Self.poolRank(id: $1.key, pool: $1.value)
                // Ids break ties so an unranked pair can't shuffle between
                // refreshes — Swift's sort is not stable.
                if lhs != rhs { return lhs < rhs }
                return $0.key < $1.key
            }
            .map { (id: $0.key, pool: $0.value) }
    }

    /// This provider's burndown pools in exactly the selection and order of
    /// `visiblePools`, so a provider's charts line up one-for-one with the
    /// progress bars above them. Pools the host hid from the rings get no
    /// chart, and a pool with no history yet simply drops out.
    ///
    /// - Parameter burndown: the provider's slice of `snapshot.burndown`,
    ///   keyed by pool id.
    func orderedBurndown(from burndown: [String: Burndown]?) -> [Burndown] {
        let byPool = burndown ?? [:]
        guard !(pools ?? [:]).isEmpty else {
            return byPool.values.sorted {
                let lhs = Self.poolPrecedence.firstIndex(of: $0.pool ?? "")
                    ?? Self.poolPrecedence.count
                let rhs = Self.poolPrecedence.firstIndex(of: $1.pool ?? "")
                    ?? Self.poolPrecedence.count
                if lhs != rhs { return lhs < rhs }
                return ($0.pool ?? "") < ($1.pool ?? "")
            }
        }
        return visiblePools.compactMap { byPool[$0.id] }
    }
}

struct QuotaPoolInfo: Decodable, Sendable {
    var title: String?
    /// Position in the host's declared pool order. Nil from hosts older than
    /// the field, which is why `poolPrecedence` survives as the fallback.
    var rank: Int?
    var pct: Double?
    var pacePct: Double?
    var windowS: Double?
    var resetsInS: Double?
    var resetsIn: String?
    var ring: Bool?

    enum CodingKeys: String, CodingKey {
        case title, rank, pct, ring
        case pacePct = "pace_pct"
        case windowS = "window_s"
        case resetsInS = "resets_in_s"
        case resetsIn = "resets_in"
    }
}

struct CodexUsage: Decodable, Sendable {
    var ok: Bool?
    var plan: String?
    var error: String?
    var sessionPct: Double?
    var sessionPacePct: Double?
    var sessionResetsIn: String?
    var weekPct: Double?
    var weekPacePct: Double?
    var weekResetsIn: String?
    var paceLabel: String?
    var runsOutIn: String?
    var resetCreditsAvailable: Int?
    var resetCreditsExpiries: [String]?
    var costUSD: Double?
    var costLimitUSD: Double?
    var costLabel: String?
    var costReached: Bool?

    /// Matches the ESP32 line: "N reset credits". Nil when the host omitted the field.
    var resetCreditsLabel: String? {
        guard let available = resetCreditsAvailable else { return nil }
        return "\(available) reset credits"
    }

    /// Expiry countdowns joined the same way the board does (" · ").
    var resetCreditsExpiryLabel: String? {
        let parts = (resetCreditsExpiries ?? []).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey {
        case ok, plan, error
        case sessionPct = "session_pct"
        case sessionPacePct = "session_pace_pct"
        case sessionResetsIn = "session_resets_in"
        case weekPct = "week_pct"
        case weekPacePct = "week_pace_pct"
        case weekResetsIn = "week_resets_in"
        case paceLabel = "pace_label"
        case runsOutIn = "runs_out_in"
        case resetCreditsAvailable = "reset_credits_available"
        case resetCreditsExpiries = "reset_credits_expiries"
        case costUSD = "cost_usd"
        case costLimitUSD = "cost_limit_usd"
        case costLabel = "cost_label"
        case costReached = "cost_reached"
    }
}

struct CursorUsage: Decodable, Sendable {
    var ok: Bool?
    var plan: String?
    var totalPct: Double?
    var totalPacePct: Double?
    var autoPct: Double?
    var autoPacePct: Double?
    var apiPct: Double?
    var apiPacePct: Double?
    var resetsIn: String?
    var paceLabel: String?
    var costUSD: Double?
    var costLimitUSD: Double?
    var costLabel: String?
    var onDemandLabel: String?
    var onDemandRemainingUSD: Double?
    var onDemandLimitUSD: Double?
    var onDemandUsedUSD: Double?

    enum CodingKeys: String, CodingKey {
        case ok, plan
        case totalPct = "total_pct"
        case totalPacePct = "total_pace_pct"
        case autoPct = "auto_pct"
        case autoPacePct = "auto_pace_pct"
        case apiPct = "api_pct"
        case apiPacePct = "api_pace_pct"
        case resetsIn = "resets_in"
        case paceLabel = "pace_label"
        case costUSD = "cost_usd"
        case costLimitUSD = "cost_limit_usd"
        case costLabel = "cost_label"
        case onDemandLabel = "on_demand_label"
        case onDemandRemainingUSD = "on_demand_remaining_usd"
        case onDemandLimitUSD = "on_demand_limit_usd"
        case onDemandUsedUSD = "on_demand_used_usd"
    }
}

struct Attention: Decodable, Sendable {
    var level: String?
    var score: Int?
    var summary: String?
    var reasons: [AttentionReason]?
    var acknowledged: Bool?

    var isWarning: Bool {
        switch level {
        case "warn", "critical": true
        default: false
        }
    }

    var isCritical: Bool {
        level == "critical"
    }

    /// Stable identity for acknowledge-until-new. Changes when reasons change.
    var fingerprint: String {
        let parts = (reasons ?? []).map(\.id).sorted()
        return parts.isEmpty ? (level ?? "ok") : parts.joined(separator: "\n")
    }
}

struct AttentionReason: Decodable, Sendable, Identifiable {
    var level: String?
    var kind: String?
    var summary: String?

    var id: String {
        [level, kind, summary].compactMap { $0 }.joined(separator: "|")
    }
}

/// Persists a cleared attention fingerprint so the menu-bar pip stays off
/// until a different (new) attention set appears.
enum AttentionAck {
    static let defaultsKey = "dismissedAttentionFingerprint"

    static var dismissedFingerprint: String? {
        get { UserDefaults.standard.string(forKey: defaultsKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    static func acknowledge(_ attention: Attention) {
        dismissedFingerprint = attention.fingerprint
    }

    static func shouldShowPip(
        for attention: Attention?,
        dismissedFingerprint: String? = AttentionAck.dismissedFingerprint
    ) -> Bool {
        guard let attention, attention.isWarning else { return false }
        return attention.fingerprint != dismissedFingerprint
    }
}

struct VercelUsage: Decodable, Sendable {
    var ok: Bool?
    var team: String?
    var error: String?
    var stale: Bool?
    var deployments: [Deployment]?
}

struct Deployment: Decodable, Identifiable, Sendable {
    var deploymentID: String?
    var project: String?
    var state: String?
    var status: String?
    var target: String?
    var ago: String?
    var branch: String?
    var sha: String?
    var shortSHA: String?
    var repo: String?
    var commitMessage: String?
    var errorMessage: String?
    var inspectorURL: String?
    var url: String?

    var id: String {
        deploymentID ?? [project, branch, ago, url]
            .compactMap { $0 }.joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case project, state, status, target, ago, branch, sha, repo, url
        case deploymentID = "id"
        case shortSHA = "short_sha"
        case commitMessage = "commit_message"
        case errorMessage = "error_message"
        case inspectorURL = "inspector_url"
    }
}

struct GitUsage: Decodable, Sendable {
    var ok: Bool?
    var error: String?
    var stale: Bool?
    var commits: [Commit]?
}

struct GitHubUsage: Decodable, Sendable {
    var ok: Bool?
    var configured: Bool?
    var error: String?
    var stale: Bool?
    var failCount: Int?
    var runningCount: Int?
    var runs: [GitHubRun]?
    var repos: [String]?

    enum CodingKeys: String, CodingKey {
        case ok, configured, error, stale, runs, repos
        case failCount = "fail_count"
        case runningCount = "running_count"
    }
}

struct GitHubRun: Decodable, Identifiable, Sendable {
    var id: String
    var repo: String?
    var name: String?
    var displayTitle: String?
    var status: String?
    var conclusion: String?
    var branch: String?
    var sha: String?
    var shortSHA: String?
    var url: String?
    var ago: String?

    enum CodingKeys: String, CodingKey {
        case id, repo, name, status, conclusion, branch, sha, url, ago
        case displayTitle = "display_title"
        case shortSHA = "short_sha"
    }
}

struct Commit: Decodable, Identifiable, Sendable {
    var repo: String?
    var subject: String?
    var ago: String?
    var branch: String?
    var sha: String?
    var shortSHA: String?
    var pushed: Bool?
    var path: String?
    var repoURL: String?

    var id: String {
        sha ?? [repo, subject, ago].compactMap { $0 }.joined(separator: "|")
    }

    enum CodingKeys: String, CodingKey {
        case repo, subject, ago, branch, sha, pushed, path
        case shortSHA = "short_sha"
        case repoURL = "repo_url"
    }
}

struct ActivityItem: Decodable, Identifiable, Sendable {
    var id: String
    var kind: String?
    var status: String?
    var subject: String?
    var repo: String?
    var project: String?
    var branch: String?
    var sha: String?
    var shortSHA: String?
    var target: String?
    var ago: String?
    var errorMessage: String?
    var url: String?
    var inspectorURL: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, status, subject, repo, project, branch, sha, target, ago, url
        case shortSHA = "short_sha"
        case errorMessage = "error_message"
        case inspectorURL = "inspector_url"
    }
}

struct SupabaseUsage: Decodable, Sendable {
    var ok: Bool?
    var configured: Bool?
    var error: String?
    var stale: Bool?
    var projects: [SupabaseProject]?
    var projectCount: Int?
    var healthyCount: Int?
    var alertCount: Int?
    /// Portfolio-wide advisor totals. Health and lints are separate signals:
    /// `alertCount` is "something is down", these are "something is unsafe".
    var lintErrorCount: Int?
    var lintWarnCount: Int?
    var lintTotal: Int?

    enum CodingKeys: String, CodingKey {
        case ok, configured, error, projects, stale
        case projectCount = "project_count"
        case healthyCount = "healthy_count"
        case alertCount = "alert_count"
        case lintErrorCount = "lint_error_count"
        case lintWarnCount = "lint_warn_count"
        case lintTotal = "lint_total"
    }
}

struct SyncSource: Decodable, Identifiable, Sendable {
    var id: String
    var title: String?
    var hint: String?
    /// "quota" or "activity" — from the host registry.
    var kind: String?
    /// "ai" or "devtools" — which Settings section this row belongs to.
    var group: String?
    /// Brand accent `#RRGGBB` — the Settings override when one is set,
    /// otherwise the registry's. Nil for rows with no brand.
    var accent: String?
    /// The registry's own color, so the picker can offer "Default" and tell
    /// an overridden row from a shipped one.
    var accentDefault: String?
    var enabled: Bool?
    var ok: Bool?
    var stale: Bool?
    var configured: Bool?
    var error: String?
    var detail: String?
    var ageS: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, hint, kind, group, accent, enabled, ok, stale
        case configured, error, detail
        case accentDefault = "accent_default"
        case ageS = "age_s"
    }

    var sourceGroup: SourceGroup { SourceGroup(group: group, kind: kind) }
}

/// AI coding tools vs. dev tools: two different jobs, so onboarding and
/// Settings list them apart instead of one undifferentiated pile of toggles.
///
/// Membership comes from the host registry (`sources[].group`); titles are
/// chrome and live in `HeadroomCopy`.
enum SourceGroup: String, CaseIterable, Sendable {
    case ai
    case devtools

    /// Hosts predating `group` only sent `kind`, where quota == a coding tool.
    init(group: String?, kind: String?) {
        if let group, let known = SourceGroup(rawValue: group) {
            self = known
        } else {
            self = kind == "quota" ? .ai : .devtools
        }
    }

    var title: String {
        switch self {
        case .ai: return HeadroomCopy.aiTools
        case .devtools: return HeadroomCopy.devTools
        }
    }

    var subtitle: String {
        switch self {
        case .ai: return HeadroomCopy.aiToolsHint
        case .devtools: return HeadroomCopy.devToolsHint
        }
    }
}

extension Array where Element == SyncSource {
    /// Rows split into `SourceGroup` order, dropping groups with no rows.
    /// Registry order is preserved inside each group.
    func groupedBySourceGroup() -> [(group: SourceGroup, sources: [SyncSource])] {
        SourceGroup.allCases.compactMap { group in
            let rows = filter { $0.sourceGroup == group }
            return rows.isEmpty ? nil : (group, rows)
        }
    }
}

struct SupabaseProject: Decodable, Identifiable, Sendable {
    var ref: String
    var name: String?
    var organizationID: String?
    var region: String?
    var status: String?
    var healthy: Bool?
    var services: [SupabaseService]?
    var unhealthyServices: [String]?
    var healthError: String?
    var dashboardURL: String?
    /// Security advisor findings, ERROR first. Capped host-side; `lintTotal`
    /// is the real count.
    var lints: [SupabaseLint]?
    var lintTruncated: Bool?
    var lintErrorCount: Int?
    var lintWarnCount: Int?
    var lintInfoCount: Int?
    var lintTotal: Int?
    /// Set when the advisors endpoint failed; health is still trustworthy.
    var advisorError: String?

    var id: String { ref }

    /// Deep link to the project's advisor page, where these get fixed.
    var advisorsURL: String {
        "https://supabase.com/dashboard/project/\(ref)/advisors/security"
    }

    enum CodingKeys: String, CodingKey {
        case ref, name, region, status, healthy, services, lints
        case organizationID = "organization_id"
        case unhealthyServices = "unhealthy_services"
        case healthError = "health_error"
        case dashboardURL = "dashboard_url"
        case lintTruncated = "lint_truncated"
        case lintErrorCount = "lint_error_count"
        case lintWarnCount = "lint_warn_count"
        case lintInfoCount = "lint_info_count"
        case lintTotal = "lint_total"
        case advisorError = "advisor_error"
    }
}

/// One security advisor finding — `rls_disabled_in_public` and friends.
struct SupabaseLint: Decodable, Identifiable, Sendable {
    var name: String
    var title: String?
    /// "ERROR", "WARN", or "INFO". Unknown severities arrive as "WARN".
    var level: String?
    var categories: [String]?
    var description: String?
    var detail: String?
    /// Docs URL for the fix, when Supabase supplies one.
    var remediation: String?
    /// The table or view the finding is about, e.g. "public.posts".
    var entity: String?

    var id: String { "\(name)|\(entity ?? "")" }

    var isError: Bool { (level ?? "").uppercased() == "ERROR" }
}

struct SupabaseService: Decodable, Identifiable, Sendable {
    var name: String
    var status: String?
    var healthy: Bool?

    var id: String { name }
}

struct PlausibleUsage: Decodable, Sendable {
    var ok: Bool?
    var configured: Bool?
    var error: String?
    var stale: Bool?
    var sites: [PlausibleSite]?
    var siteCount: Int?
    var visitorsToday: Int?
    var realtime: Int?
    /// Primary window id from the host (`day`, `24h`, `7d`, `30d`).
    var range: String?
    var rangeLabel: String?

    var windowLabel: String {
        rangeLabel ?? range ?? "today"
    }

    enum CodingKeys: String, CodingKey {
        case ok, configured, error, sites, stale, realtime, range
        case siteCount = "site_count"
        case visitorsToday = "visitors_today"
        case rangeLabel = "range_label"
    }
}

struct PlausibleSite: Decodable, Identifiable, Sendable {
    var domain: String
    var visitorsToday: Int?
    var pageviewsToday: Int?
    var visitors7d: Int?
    var pageviews7d: Int?
    var bounceRate7d: Double?
    var visitDuration7d: Int?
    var realtime: Int?
    var dashboardURL: String?
    var error: String?
    var range: String?
    var rangeLabel: String?

    var id: String { domain }

    var windowLabel: String {
        rangeLabel ?? range ?? "today"
    }

    enum CodingKeys: String, CodingKey {
        case domain, realtime, error, range
        case visitorsToday = "visitors_today"
        case pageviewsToday = "pageviews_today"
        case visitors7d = "visitors_7d"
        case pageviews7d = "pageviews_7d"
        case bounceRate7d = "bounce_rate_7d"
        case visitDuration7d = "visit_duration_7d"
        case dashboardURL = "dashboard_url"
        case rangeLabel = "range_label"
    }
}

struct LocalUsage: Decodable, Sendable {
    var ok: Bool?
    var host: String?
    var error: String?
    var stale: Bool?
    var servers: [LocalServer]?
}

struct LocalServer: Decodable, Identifiable, Sendable {
    var name: String?
    var port: Int?
    var pid: Int?
    var cmd: String?
    var cwd: String?
    var bind: String?
    var reachable: Bool?
    var latencyMS: Int?

    var id: String { "\(name ?? "server"):\(port ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case name, port, pid, cmd, cwd, bind, reachable
        case latencyMS = "latency_ms"
    }
}

extension Double {
    /// Always whole dollars with `$`, never cents or locale currency codes.
    var dollarLabel: String {
        String(format: "$%.0f", rounded())
    }
}

enum MobilePermission: String, CaseIterable, Codable, Sendable {
    case read
    case refresh
    case sources
    case servers

    var title: String {
        switch self {
        case .read: "Read dashboard"
        case .refresh: "Refresh data"
        case .sources: "Manage sources"
        case .servers: "Stop local servers"
        }
    }
}

struct MobilePermissions: Codable, Sendable, Equatable {
    var read = false
    var refresh = false
    var sources = false
    var servers = false

    static let allEnabled = MobilePermissions(
        read: true, refresh: true, sources: true, servers: true)
    static let allDisabled = MobilePermissions()

    subscript(_ permission: MobilePermission) -> Bool {
        get {
            switch permission {
            case .read: read
            case .refresh: refresh
            case .sources: sources
            case .servers: servers
            }
        }
        set {
            switch permission {
            case .read: read = newValue
            case .refresh: refresh = newValue
            case .sources: sources = newValue
            case .servers: servers = newValue
            }
        }
    }

    var dictionary: [String: Bool] {
        Dictionary(uniqueKeysWithValues: MobilePermission.allCases.map {
            ($0.rawValue, self[$0])
        })
    }
}

struct MobilePermissionsResponse: Codable, Sendable {
    var ok: Bool
    var permissions: MobilePermissions
}
