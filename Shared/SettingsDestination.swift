import Foundation

/// Settings navigation graph shared by macOS and iOS.
///
/// Root order mirrors user intent (General → what you watch → agents → phone →
/// SaaS keys → About). Nested leaves sit under General (Other Macs) and
/// Integrations (Supabase / Plausible / GitHub).
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
        .general, .sources, .codingAgents, .iPhone, .integrations, .about,
    ]

    /// iPhone Settings tab roots. Connection is the phone’s view of pairing;
    /// Mac’s General covers host endpoint on the Mac itself.
    static let iOSRoots: [SettingsDestination] = [
        .connection, .sources, .iPhone, .about,
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
    var isMacOnly: Bool {
        switch self {
        case .general, .codingAgents, .integrations, .otherMacs, .integration:
            return true
        case .sources, .iPhone, .about, .connection, .permissions:
            return false
        }
    }
}

enum SettingsIntegration: String, Hashable, CaseIterable, Sendable {
    case supabase
    case plausible
    case github

    var title: String {
        switch self {
        case .supabase: return "Supabase"
        case .plausible: return "Plausible"
        case .github: return HeadroomCopy.githubActions
        }
    }

    var symbol: String {
        switch self {
        case .supabase: return "cylinder.split.1x2"
        case .plausible: return "chart.xyaxis.line"
        case .github: return "chevron.left.forwardslash.chevron.right"
        }
    }
}
