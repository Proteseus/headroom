import Foundation
import WidgetKit

/// The app half of the widget: turn a full `UsageSnapshot` into the small
/// Codable the extension draws, and leave it in the shared group.
///
/// Both apps write it. On iOS the phone has just fetched from the Mac; on the
/// Mac the app is the source itself, which is why its widget is current while
/// the phone's is up to a background-refresh interval behind.
///
/// `save` hands the payload back so the phone can forward the very same bytes
/// to the watch (`WatchBridge`) rather than building a second, drifting wire
/// for it — the watch complications draw the widget's snapshot verbatim.
enum HeadroomWidgetCache {
    @discardableResult
    static func save(_ snapshot: UsageSnapshot) -> HeadroomWidgetSnapshot {
        // Clip the series here rather than in the extension: the widget gets a
        // week of chart and nothing else, and it redraws from a cache it can
        // hold in memory. It clips again on its own clock, which has moved on
        // by up to a refresh interval by the time it draws.
        let domain = OverallBurndownChartMath.domain(now: .now)

        // Same three the menu bar draws — the host picked them.
        let providers = snapshot.focusProviders()
            .map { provider in
                let percent = provider.pools?.values
                    .filter { $0.ring != false }
                    .compactMap(\.pct)
                    .max() ?? 0
                return HeadroomWidgetSnapshot.Provider(
                    id: provider.id,
                    title: provider.title ?? provider.id.capitalized,
                    percent: percent,
                    accent: provider.accent,
                    layers: provider.ringLayers(
                        burndown: snapshot.burndownRings(
                            forProviderID: provider.id
                        )
                    ).map {
                        HeadroomWidgetSnapshot.Provider.Layer(
                            id: $0.id,
                            percent: $0.percent,
                            pacePercent: $0.pacePercent
                        )
                    },
                    burndown: series(
                        for: provider.id, in: snapshot, domain: domain
                    )
                )
            }
        let value = HeadroomWidgetSnapshot(
            updatedAt: .now,
            attentionLevel: snapshot.attention?.level,
            attentionSummary: snapshot.attention?.summary,
            providers: Array(providers)
        )
        guard let data = try? JSONEncoder().encode(value),
              let defaults = HeadroomAppGroup.defaults()
        else { return value }
        defaults.set(data, forKey: HeadroomAppGroup.snapshotKey)
        WidgetCenter.shared.reloadAllTimelines()
        return value
    }

    /// One provider's line on the wide widget's combined burndown, from the
    /// same pool the Mac card and the phone's own overview chart draw.
    private static func series(
        for providerID: String,
        in snapshot: UsageSnapshot,
        domain: OverallBurndownChartMath.Domain
    ) -> HeadroomWidgetSnapshot.Provider.Series? {
        guard let pool = snapshot.overviewBurndown(forProviderID: providerID)
        else { return nil }
        let actual = OverallBurndownChartMath.preparedActual(
            pool.actual, domain: domain
        )
        // A single point is a dot, not a line. Leave it out and let the widget
        // fall back to rings until there is history worth charting.
        guard actual.count >= 2 else { return nil }
        return HeadroomWidgetSnapshot.Provider.Series(
            actual: actual,
            projected: OverallBurndownChartMath.preparedProjection(
                pool.projected, windowEnd: pool.windowEnd, domain: domain
            ),
            windowEnd: pool.windowEnd,
            exhausted: pool.kind == .exhausted
        )
    }
}
