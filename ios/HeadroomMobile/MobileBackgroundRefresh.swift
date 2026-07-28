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
                let snapshot = try await client.fetchUsage()
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
        let providers = (snapshot.providers ?? [])
            .filter { $0.enabled != false }
            .prefix(3)
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
                    }
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
}
