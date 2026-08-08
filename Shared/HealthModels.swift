import Foundation

// Wire models for GET /health, decoded by both apps. These lived in the
// macOS client for a while, which left the iPhone re-typing the keys as raw
// dictionary lookups — a rename would have drifted the two silently.
// /usage models stay in HeadroomModels.swift; /health is its own document.

struct HealthReport: Decodable, Sendable {
    var ok: Bool?
    var uptimeS: Int?
    var updated: String?
    var sources: [String: SourceHealth]
    /// Absent on hosts older than the version handshake — see HostVersion.
    var version: String?
    var build: String?

    enum CodingKeys: String, CodingKey {
        case ok, updated, sources, version, build
        case uptimeS = "uptime_s"
    }
}

struct SourceHealth: Decodable, Sendable {
    var ok: Bool?
    var stale: Bool?
    var enabled: Bool?
    var ageS: Int?
    var error: String?
    var detail: String?

    enum CodingKeys: String, CodingKey {
        case ok, stale, enabled, error, detail
        case ageS = "age_s"
    }
}
