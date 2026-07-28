import BackgroundTasks
import WidgetKit

enum MobileBackgroundRefresh {
    static let identifier = "com.centaur-labs.headroom.refresh"

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    static func schedule() {
        guard UserDefaults.standard.object(forKey: "backgroundRefreshEnabled") == nil
                || UserDefaults.standard.bool(forKey: "backgroundRefreshEnabled")
        else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let boxedTask = SendableRefreshTask(task)
        let work = Task {
            do {
                let client = MobileHeadroomClient(
                    endpoint: MobileConnection.endpoint,
                    token: MobileTokenStore.read() ?? ""
                )
                let snapshot = try await client.fetchAndArchiveUsage()
                MobileWidgetCache.save(snapshot)
                await MobileNotifications.notifyIfNeeded(snapshot.attention)
                boxedTask.value.setTaskCompleted(success: true)
            } catch {
                boxedTask.value.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = {
            work.cancel()
        }
    }
}

private final class SendableRefreshTask: @unchecked Sendable {
    let value: BGAppRefreshTask

    init(_ value: BGAppRefreshTask) {
        self.value = value
    }
}

enum MobileWidgetCache {
    static let suite = "group.com.centaur-labs.headroom"
    private static let key = "widgetSnapshot"

    static func save(_ snapshot: UsageSnapshot) {
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
                    layers: provider.ringLayers.map {
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
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults(suiteName: suite)?.set(data, forKey: key)
        WidgetCenter.shared.reloadAllTimelines()
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
