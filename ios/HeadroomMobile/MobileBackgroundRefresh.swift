import BackgroundTasks

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
                HeadroomWidgetCache.save(snapshot)
                await MobileNotifications.notifyIfNeeded(snapshot.attention)
                if let permissions = try? await client.fetchMobilePermissions(),
                   permissions.read,
                   let events = try? await client.fetchAgentAttentionEvents() {
                    await MobileNotifications.notifyIfNeeded(events)
                }
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
