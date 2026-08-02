import Foundation

/// Settings navigation graph shared by macOS and iOS.
///
/// Root order mirrors user intent (General → what you watch → what you connect
/// to → agents → phone → About). Nested leaves sit under General (Other Macs)
/// and Integrations (every external service, see `SettingsIntegration`).
///
/// Integrations is the single home for connection settings. `Coding agents`
/// survives as a root because starting a task is an action rather than a
/// preference; the Claude Code and Codex *connections* live under Integrations
/// with everything else.
///
/// Onboarding (`WelcomePane`) maps onto the same ideas where it can:
/// - Sources ↔ Welcome “What to watch” (same symbol)
/// - iPhone ↔ Welcome “On your phone”
/// - General ↔ Welcome “Background helper” (the host this Mac runs)
enum SettingsDestination: Hashable, Sendable {
    case general
    case sources
    case codingAgents
    case iPhone
    case integrations
    case about

    /// Nested under General.
    case otherMacs
    /// Nested under Integrations.
    case integration(SettingsIntegration)

    /// iOS-only roots / leaves (Mac grants live under `.iPhone`).
    case connection
    case permissions

    /// Mac sidebar roots — short, fixed, progressive disclosure below.
    static let macRoots: [SettingsDestination] = [
        .general, .sources, .integrations, .codingAgents, .iPhone, .about,
    ]

    /// iPhone Settings tab roots. Connection is the phone’s view of pairing;
    /// Mac’s General covers host endpoint on the Mac itself.
    ///
    /// Integrations earns a root here for the same reason it has one on the
    /// Mac: Sources lists what you watch, Integrations lists what Headroom is
    /// connected to. The phone's version is on/off and status only — keys are
    /// entered on the Mac and the phone never sees them.
    static let iOSRoots: [SettingsDestination] = [
        .connection, .sources, .integrations, .iPhone, .about,
    ]

    var title: String {
        switch self {
        case .general: return HeadroomCopy.settingsGeneral
        case .sources: return HeadroomCopy.settingsSources
        case .codingAgents: return HeadroomCopy.codingAgents
        case .iPhone: return HeadroomCopy.settingsiPhone
        case .integrations: return HeadroomCopy.settingsIntegrations
        case .about: return HeadroomCopy.about
        case .otherMacs: return HeadroomCopy.otherMacs
        case .integration(let kind): return kind.title
        case .connection: return HeadroomCopy.settingsConnection
        case .permissions: return HeadroomCopy.settingsPermissions
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .sources: return "checklist"
        case .codingAgents: return "cpu"
        case .iPhone: return "iphone"
        case .integrations: return "link"
        case .about: return "info.circle"
        case .otherMacs: return "laptopcomputer.and.iphone"
        case .integration(let kind): return kind.symbol
        case .connection: return "network"
        case .permissions: return "lock.shield"
        }
    }

    /// True when this destination only makes sense on the Mac host UI.
    ///
    /// `integrations` is on both now — the phone lists the same connections
    /// read-only-ish (on/off and status, no credential fields). The
    /// per-integration leaf stays Mac-only, because configuring one means
    /// typing a key, and keys are never entered on the phone.
    var isMacOnly: Bool {
        switch self {
        case .general, .codingAgents, .otherMacs, .integration:
            return true
        case .integrations, .sources, .iPhone, .about, .connection,
             .permissions:
            return false
        }
    }
}

/// One external thing Headroom connects to, and the leaf that configures it.
///
/// Membership is deliberately not "has a Keychain token" — that was the old
/// line, and it scattered connection settings across three roots by the
/// accident of how each service authenticates. If Headroom has to be told
/// something to reach it, it belongs here.
///
/// Raw values match `sources_config` ids where a source exists, so a status
/// lookup against `/usage` needs no second mapping table.
enum SettingsIntegration: String, Hashable, CaseIterable, Sendable {
    case claudeCode = "claude"
    case codex
    case git
    case github
    case vercel
    case openrouter
    case aiGateway = "ai-gateway"
    case supabase
    case plausible
    case posthog

    /// Hub grouping. Agents can run code, the rest only report — worth a
    /// visible line between them in a list someone scans for "what did I
    /// give this thing access to".
    enum Group: String, CaseIterable, Sendable {
        case agents
        case code
        case balances
        case services

        var title: String {
            switch self {
            case .agents: return HeadroomCopy.codingAgents
            case .code: return HeadroomCopy.integrationsCode
            case .balances: return HeadroomCopy.integrationsBalances
            case .services: return HeadroomCopy.integrationsServices
            }
        }
    }

    var group: Group {
        switch self {
        case .claudeCode, .codex: return .agents
        case .git, .github, .vercel: return .code
        case .openrouter, .aiGateway: return .balances
        case .supabase, .plausible, .posthog: return .services
        }
    }

    static func members(of group: Group) -> [SettingsIntegration] {
        allCases.filter { $0.group == group }
    }

    var title: String {
        switch self {
        case .claudeCode: return HeadroomCopy.claudeCode
        case .codex: return "Codex"
        case .git: return "Git"
        case .github: return HeadroomCopy.githubActions
        case .vercel: return "Vercel"
        case .openrouter: return HeadroomCopy.openRouter
        case .aiGateway: return HeadroomCopy.aiGateway
        case .supabase: return "Supabase"
        case .plausible: return "Plausible"
        case .posthog: return HeadroomCopy.posthog
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .codex: return "cpu"
        case .git: return "arrow.triangle.branch"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .vercel: return "triangle"
        case .openrouter: return "arrow.triangle.swap"
        case .aiGateway: return "bolt.horizontal"
        case .supabase: return "cylinder.split.1x2"
        case .plausible: return "chart.xyaxis.line"
        case .posthog: return "chart.bar.doc.horizontal"
        }
    }

    /// True when the leaf can start or steer a local executable. Drives the
    /// hub's caption, and is the reason `docs/trust.md` treats these routes as
    /// Class 4 rather than ordinary config.
    var runsCode: Bool {
        switch self {
        case .claudeCode, .codex: return true
        case .git, .github, .vercel, .openrouter, .aiGateway,
             .supabase, .plausible, .posthog:
            return false
        }
    }
}
