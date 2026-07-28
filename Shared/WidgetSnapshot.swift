import Foundation

struct HeadroomWidgetSnapshot: Codable, Sendable {
    struct Provider: Codable, Identifiable, Sendable {
        struct Layer: Codable, Sendable {
            var id: String
            var percent: Double?
            var pacePercent: Double?
        }

        var id: String
        var title: String
        var percent: Double
        var accent: String?
        /// Optional so widgets can still decode a cache written by an older app.
        var layers: [Layer]?
    }

    var updatedAt: Date
    var attentionLevel: String?
    var attentionSummary: String?
    var providers: [Provider]

    /// Unlike the app, a widget never learns that a fetch failed — it only ever
    /// sees the cache. So it judges by age, with a couple of refresh intervals
    /// of slack before it calls the numbers history.
    static let freshWindow: TimeInterval = 45 * 60

    var isStale: Bool {
        Date().timeIntervalSince(updatedAt) > Self.freshWindow
    }

    var age: TimeInterval {
        Date().timeIntervalSince(updatedAt)
    }

    static let placeholder = HeadroomWidgetSnapshot(
        updatedAt: .now,
        attentionLevel: nil,
        attentionSummary: HeadroomCopy.openToSync,
        providers: [
            Provider(
                id: "claude",
                title: "Claude",
                percent: 42,
                accent: "#D97757",
                layers: [
                    Provider.Layer(id: "Session", percent: 42, pacePercent: 35),
                    Provider.Layer(id: "Weekly", percent: 28, pacePercent: 31),
                ]
            ),
            Provider(
                id: "codex",
                title: "Codex",
                percent: 28,
                accent: "#10A37F",
                layers: [
                    Provider.Layer(id: "Session", percent: 28, pacePercent: 35),
                    Provider.Layer(id: "Weekly", percent: 18, pacePercent: 31),
                ]
            ),
        ]
    )
}
