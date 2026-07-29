import Foundation
#if os(macOS)
import Security
#endif

/// Where the app leaves the widget's cache, on both platforms.
///
/// The group id is not the same string everywhere. iOS provisions the bare
/// `group.…` name, while macOS requires the team id in front of it — including
/// for an app like this one that runs outside the sandbox. Hardcoding the team
/// would stop forks from signing as themselves (see `$HEADROOM_TEAM_ID`), so
/// the Mac reads its own signature for it instead.
enum HeadroomAppGroup {
    static let name = "group.com.centaur-labs.headroom"

    /// Nil on macOS only when the running copy has no team — an ad-hoc or
    /// unsigned build. The sandbox would deny that copy the container anyway,
    /// so the widget falls through to its placeholder rather than reading a
    /// suite that silently isn't shared.
    static let identifier: String? = {
        #if os(macOS)
        guard let team = signingTeamIdentifier() else { return nil }
        return "\(team).\(name)"
        #else
        return name
        #endif
    }()

    static func defaults() -> UserDefaults? {
        guard let identifier else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    static func containerURL() -> URL? {
        guard let identifier else { return nil }
        return FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        )
    }

    /// Key for the encoded `HeadroomWidgetSnapshot` inside the group defaults.
    static let snapshotKey = "widgetSnapshot"

    #if os(macOS)
    private static func signingTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        ) == errSecSuccess,
            let values = info as? [String: Any]
        else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }
    #endif
}

struct HeadroomWidgetSnapshot: Codable, Sendable {
    struct Provider: Codable, Identifiable, Sendable {
        struct Layer: Codable, Sendable {
            var id: String
            var percent: Double?
            var pacePercent: Double?
        }

        /// One provider's line on the combined burndown: what is left against
        /// time, plus the dashed forecast. Compact `[[epoch, remainingPct], …]`
        /// pairs, cropped and clipped to the chart's week before they are
        /// written, so the widget only has to scale them into a rect.
        struct Series: Codable, Sendable {
            var actual: [[Double]]
            var projected: [[Double]]
            /// When the pool renews, drawn as a dotted rule if it lands inside
            /// the week.
            var windowEnd: Double?
            var exhausted: Bool?
        }

        var id: String
        var title: String
        var percent: Double
        var accent: String?
        /// Optional so widgets can still decode a cache written by an older app.
        var layers: [Layer]?
        /// Also optional: a provider with no history yet has no line to draw,
        /// and the wide widget falls back to rings when none of them do.
        var burndown: Series?
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

    /// The last cache the app wrote, or nil when there is none to read — no
    /// group container, nothing written yet, or a payload this build can't
    /// decode. Every one of those reads the same to a widget: placeholder.
    static func cached() -> HeadroomWidgetSnapshot? {
        guard let data = HeadroomAppGroup.defaults()?
                .data(forKey: HeadroomAppGroup.snapshotKey)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Gallery preview only: a week-shaped series, so the widget picker shows
    /// the chart it will draw rather than an empty frame.
    private static func demoBurndown(
        remaining: Double,
        perDay: Double
    ) -> Provider.Series {
        let day: TimeInterval = 24 * 60 * 60
        let now = Date().timeIntervalSince1970
        let spent = 100 - remaining
        return Provider.Series(
            actual: stride(from: 0.0, through: 3.0, by: 0.25).map { offset in
                [now - (3 - offset) * day, 100 - spent * offset / 3]
            },
            projected: stride(from: 0.0, through: 4.0, by: 0.5).map { offset in
                [now + offset * day, max(0, remaining - perDay * offset)]
            },
            windowEnd: now + 4 * day,
            exhausted: false
        )
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
                ],
                burndown: demoBurndown(remaining: 72, perDay: 16)
            ),
            Provider(
                id: "codex",
                title: "Codex",
                percent: 28,
                accent: "#10A37F",
                layers: [
                    Provider.Layer(id: "Session", percent: 28, pacePercent: 35),
                    Provider.Layer(id: "Weekly", percent: 18, pacePercent: 31),
                ],
                burndown: demoBurndown(remaining: 82, perDay: 9)
            ),
        ]
    )
}
