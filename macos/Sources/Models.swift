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
    var codex: CodexUsage?
    var cursor: CursorUsage?
    var vercel: VercelUsage?
    var git: GitUsage?
    var activity: [ActivityItem]?
    var local: LocalUsage?

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
        codex: CodexUsage? = nil,
        cursor: CursorUsage? = nil,
        vercel: VercelUsage? = nil,
        git: GitUsage? = nil,
        activity: [ActivityItem]? = nil,
        local: LocalUsage? = nil
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
        self.codex = codex
        self.cursor = cursor
        self.vercel = vercel
        self.git = git
        self.activity = activity
        self.local = local
    }

    enum CodingKeys: String, CodingKey {
        case updated, plan, today, codex, cursor, vercel, git, activity, local
        case quotaOK = "quota_ok"
        case quotaError = "quota_error"
        case sessionPct = "session_pct"
        case sessionPacePct = "session_pace_pct"
        case sessionResetsIn = "session_resets_in"
        case weekPct = "week_pct"
        case weekPacePct = "week_pace_pct"
        case weekResetsIn = "week_resets_in"
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
                )
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
                runsOutIn: codex?.runsOutIn
            )
        case .cursor:
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
                    title: "Auto",
                    percent: cursor?.autoPct,
                    pacePercent: cursor?.autoPacePct,
                    reset: cursor?.resetsIn
                ),
                tertiary: MeterWindow(
                    title: "API",
                    percent: cursor?.apiPct,
                    pacePercent: cursor?.apiPacePct,
                    reset: cursor?.resetsIn
                ),
                paceLabel: cursor?.paceLabel
            )
        }
    }
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

    init(
        provider: UsageProvider,
        ok: Bool,
        plan: String? = nil,
        error: String? = nil,
        primary: MeterWindow,
        secondary: MeterWindow,
        tertiary: MeterWindow? = nil,
        paceLabel: String? = nil,
        runsOutIn: String? = nil
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
    }
}

struct VercelUsage: Decodable, Sendable {
    var ok: Bool?
    var team: String?
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
    var commits: [Commit]?
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

struct LocalUsage: Decodable, Sendable {
    var ok: Bool?
    var host: String?
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
