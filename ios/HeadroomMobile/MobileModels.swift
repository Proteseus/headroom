import Foundation

struct MobileUsageSnapshot: Decodable, Sendable {
    var updated: String?
    var providers: [MobileProvider]?
    var sources: [MobileSource]?
    var attention: MobileAttention?

    static let empty = MobileUsageSnapshot()
}

struct MobileProvider: Decodable, Identifiable, Sendable {
    var id: String
    var title: String?
    var enabled: Bool?
    var ok: Bool?
    var plan: String?
    var error: String?
    var accent: String?
    var headline: String?
    var pools: [String: MobilePool]?

    var visiblePools: [MobilePool] {
        let precedence = ["session", "total", "api", "auto", "week"]
        return (pools ?? [:])
            .filter { $0.value.ring != false }
            .sorted {
                let lhs = precedence.firstIndex(of: $0.key) ?? precedence.count
                let rhs = precedence.firstIndex(of: $1.key) ?? precedence.count
                return lhs < rhs
            }
            .map(\.value)
    }

    var displayTitle: String { title ?? id.capitalized }
}

struct MobilePool: Decodable, Sendable {
    var title: String?
    var pct: Double?
    var pacePct: Double?
    var resetsIn: String?
    var ring: Bool?

    enum CodingKeys: String, CodingKey {
        case title, pct, ring
        case pacePct = "pace_pct"
        case resetsIn = "resets_in"
    }
}

struct MobileSource: Decodable, Identifiable, Sendable {
    var id: String
    var kind: String?
    var enabled: Bool?
}

struct MobileAttention: Decodable, Sendable {
    var level: String?
    var summary: String?
    var reasons: [MobileAttentionReason]?

    var needsAttention: Bool {
        level == "warn" || level == "critical"
    }
}

struct MobileAttentionReason: Decodable, Identifiable, Sendable {
    var level: String?
    var kind: String?
    var summary: String?

    var id: String {
        [level, kind, summary].compactMap { $0 }.joined(separator: "|")
    }
}
