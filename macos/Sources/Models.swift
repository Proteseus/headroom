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
    var sources: [SyncSource]?
    var attention: Attention?
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
        self.sources = sources
        self.attention = attention
        self.burndown = burndown
        self.burndownPrimary = burndownPrimary
    }

    enum CodingKeys: String, CodingKey {
        case updated, plan, today, codex, cursor, providers, vercel, git, github, activity, local
        case supabase, sources, attention, burndown
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

    /// Enabled coding-quota providers in host registry order.
    ///
    /// CodexBar-style: only what the user turned on in Settings → Sources.
    /// Falls back to every known provider when the host omitted sources
    /// (offline / empty snapshot).
    var activeQuotaProviders: [UsageProvider] {
        guard let sources, !sources.isEmpty else {
            return UsageProvider.allCases
        }
        let known = Dictionary(uniqueKeysWithValues:
            UsageProvider.allCases.map { ($0.rawValue, $0) })
        let hasKind = sources.contains { $0.kind != nil }
        let quotaRows = sources.filter { row in
            if hasKind { return row.kind == "quota" }
            return known[row.id] != nil
        }
        var seen = Set<String>()
        var out: [UsageProvider] = []
        for row in quotaRows where row.enabled != false {
            guard let provider = known[row.id], seen.insert(row.id).inserted else {
                continue
            }
            out.append(provider)
        }
        // Host listed quota sources but none enabled — respect that.
        if !quotaRows.isEmpty { return out }
        return UsageProvider.allCases
    }


    /// Pools for one provider ordered fastest-window-first, so the shortest
    /// window becomes the outermost ring. Cursor's pools share a billing cycle
    /// and tie on length, so a fixed precedence breaks it — Total then API;
    /// Auto is sampled but not charted (always empty for most plans).
    func burndownRings(for provider: UsageProvider) -> [Burndown] {
        let precedence = ["session", "total", "api", "auto", "week"]
        let pools = burndown?[provider.rawValue]?.values ?? [:].values
        let visible = provider == .cursor
            ? pools.filter { $0.pool == "total" || $0.pool == "api" }
            : Array(pools)
        return visible.sorted { lhs, rhs in
            let lw = lhs.windowS ?? .greatestFiniteMagnitude
            let rw = rhs.windowS ?? .greatestFiniteMagnitude
            if lw != rw { return lw < rw }
            let li = precedence.firstIndex(of: lhs.pool ?? "") ?? precedence.count
            let ri = precedence.firstIndex(of: rhs.pool ?? "") ?? precedence.count
            return li < ri
        }
    }

    func meter(for provider: UsageProvider) -> ProviderMeter {
        switch provider {
        case .claude:
            ProviderMeter(
                provider: provider,
                ok: quotaOK ?? false,
                plan: plan,
                error: quotaError,
                primary: MeterWindow(
                    title: "Session",
                    percent: sessionPct,
                    pacePercent: sessionPacePct,
                    reset: sessionResetsIn
                ),
                secondary: MeterWindow(
                    title: "Weekly",
                    percent: weekPct,
                    pacePercent: weekPacePct,
                    reset: weekResetsIn
                ),
                costLabel: today?.costUSD.map {
                    $0.dollarLabel + " today"
                }
            )
        case .codex:
            ProviderMeter(
                provider: provider,
                ok: codex?.ok ?? false,
                plan: codex?.plan,
                error: codex?.error,
                primary: MeterWindow(
                    title: "Session",
                    percent: codex?.sessionPct,
                    pacePercent: codex?.sessionPacePct,
                    reset: codex?.sessionResetsIn
                ),
                secondary: MeterWindow(
                    title: "Weekly",
                    percent: codex?.weekPct,
                    pacePercent: codex?.weekPacePct,
                    reset: codex?.weekResetsIn
                ),
                paceLabel: codex?.paceLabel,
                runsOutIn: codex?.runsOutIn,
                costLabel: codex?.costLabel
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
                    title: "Total",
                    percent: cursor?.totalPct,
                    pacePercent: cursor?.totalPacePct,
                    reset: cursor?.resetsIn
                ),
                secondary: MeterWindow(
                    title: "API",
                    percent: cursor?.apiPct,
                    pacePercent: cursor?.apiPacePct,
                    reset: cursor?.resetsIn
                ),
                paceLabel: cursor?.paceLabel,
                costLabel: cursorCostLabel
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
    var headline: String?

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

    enum CodingKeys: String, CodingKey {
        case provider, pool, status, ideal, actual, projected, samples, headline
        case exhausted
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
    var provider: UsageProvider
    var ok: Bool
    var plan: String?
    var error: String?
    var primary: MeterWindow
    var secondary: MeterWindow
    var tertiary: MeterWindow?
    var paceLabel: String?
    var runsOutIn: String?
    var costLabel: String?

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
        costLabel: String? = nil
    ) {
        self.provider = provider
        self.ok = ok
        self.plan = plan
        self.error = error
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.paceLabel = paceLabel
        self.runsOutIn = runsOutIn
        self.costLabel = costLabel
    }

    /// Window shown as the provider's headline signal (menu bar + overview rings).
    var headline: MeterWindow {
        if provider == .cursor {
            return primary
        }
        return [primary, secondary, tertiary]
            .compactMap { $0 }
            .max { ($0.percent ?? -1) < ($1.percent ?? -1) }
            ?? primary
    }
}

struct MeterWindow: Sendable {
    var title: String
    var percent: Double?
    var pacePercent: Double?
    var reset: String?
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
        if let burns, let value = burns[provider.rawValue] {
            return value
        }
        switch provider {
        case .claude: return claude ?? 0
        case .codex: return codex ?? 0
        case .cursor: return cursor ?? 0
        }
    }

    /// Total across the given providers (enabled set), not every column.
    func total(for providers: [UsageProvider]) -> Double {
        if providers.isEmpty { return total ?? 0 }
        return providers.reduce(0) { $0 + burn(for: $1) }
    }
}

/// One coding-quota provider as advertised by the host registry.
struct QuotaProviderInfo: Decodable, Identifiable, Sendable {
    var id: String
    var title: String?
    var kind: String?
    var enabled: Bool?
    var ok: Bool?
    var plan: String?
    var error: String?
    var accent: String?
    var headline: String?
    var pools: [String: QuotaPoolInfo]?
}

struct QuotaPoolInfo: Decodable, Sendable {
    var title: String?
    var pct: Double?
    var pacePct: Double?
    var windowS: Double?
    var resetsInS: Double?
    var resetsIn: String?
    var ring: Bool?

    enum CodingKeys: String, CodingKey {
        case title, pct, ring
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
    var costUSD: Double?
    var costLimitUSD: Double?
    var costLabel: String?
    var costReached: Bool?

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

    enum CodingKeys: String, CodingKey {
        case ok, configured, error, projects, stale
        case projectCount = "project_count"
        case healthyCount = "healthy_count"
        case alertCount = "alert_count"
    }
}

struct SyncSource: Decodable, Identifiable, Sendable {
    var id: String
    var title: String?
    var hint: String?
    /// "quota" or "activity" — from the host registry.
    var kind: String?
    var enabled: Bool?
    var ok: Bool?
    var stale: Bool?
    var configured: Bool?
    var error: String?
    var detail: String?
    var ageS: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, hint, kind, enabled, ok, stale, configured, error, detail
        case ageS = "age_s"
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

    var id: String { ref }

    enum CodingKeys: String, CodingKey {
        case ref, name, region, status, healthy, services
        case organizationID = "organization_id"
        case unhealthyServices = "unhealthy_services"
        case healthError = "health_error"
        case dashboardURL = "dashboard_url"
    }
}

struct SupabaseService: Decodable, Identifiable, Sendable {
    var name: String
    var status: String?
    var healthy: Bool?

    var id: String { name }
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
