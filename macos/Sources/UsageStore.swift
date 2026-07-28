import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var stoppingServerID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefresh: Date?
    /// Set when launchd is serving a host older than the one in this .app.
    @Published private(set) var hostSkew: HostSkew?
    /// What the running host calls itself, for the Setup card.
    @Published private(set) var hostVersionLabel: String?
    @Published private(set) var isUpdatingHost = false

    var onSnapshotChange: ((UsageSnapshot, Bool) -> Void)?

    /// The popover is closed most of the time, and a closed popover only feeds
    /// three bars in the menu bar. Polling the configured interval around the
    /// clock is battery spent on pixels nobody is looking at, so idle backs off
    /// to this and opening the popover refreshes immediately.
    private static let idleInterval: TimeInterval = 300
    private static let idleAfter: TimeInterval = 120

    private var refreshLoop: Task<Void, Never>?
    private var lastInteraction = Date()

    init() {}

    deinit {
        refreshLoop?.cancel()
    }

    private var client: HeadroomClient { HeadroomClient() }

    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.nextInterval()))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    /// Call when the user actually looks at the data — resumes the fast cadence.
    func noteInteraction() {
        lastInteraction = Date()
    }

    private func nextInterval() -> TimeInterval {
        let configured = UserDefaults.standard.integer(forKey: "refreshInterval")
        let active = TimeInterval(max(15, configured > 0 ? configured : 60))
        let idleFor = Date().timeIntervalSince(lastInteraction)
        return idleFor > Self.idleAfter ? max(active, Self.idleInterval) : active
    }

    /// Apply a decoded snapshot without hitting the network (README exports).
    func applySnapshot(_ value: UsageSnapshot, healthy: Bool = true) {
        snapshot = value
        lastRefresh = Date()
        errorMessage = healthy ? nil : "fixture"
        onSnapshotChange?(value, healthy)
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let value = try await client.fetchUsage()
            snapshot = value
            lastRefresh = Date()
            errorMessage = nil
            onSnapshotChange?(value, true)
        } catch {
            errorMessage = error.localizedDescription
            onSnapshotChange?(snapshot, false)
        }
    }

    func acknowledgeAttention() async {
        guard let attention = snapshot.attention, attention.isWarning else {
            return
        }
        do {
            try await client.acknowledgeAttention(attention.fingerprint)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Ask /health which host is actually answering. Deliberately not on the
    /// refresh path: the version only changes when something reinstalls the
    /// LaunchAgent, so launch and post-install are the moments worth spending a
    /// request on.
    func checkHostVersion() async {
        guard let report = try? await client.health() else { return }
        hostSkew = HostController.skew(against: report)
        if let version = report.version {
            hostVersionLabel = report.build.map { "Host \(version) (\($0))" }
                ?? "Host \(version)"
        } else {
            hostVersionLabel = "Host predates version reporting"
        }
    }

    /// Point the LaunchAgent back at the host bundled in this .app and restart
    /// it. Same call as first-run setup — launchctl bootout/bootstrap replaces
    /// whatever job was there, including one installed from a clone.
    func updateHost() async {
        guard !isUpdatingHost else { return }
        isUpdatingHost = true
        defer { isUpdatingHost = false }
        do {
            _ = try HostController.installAndStart()
            _ = await HostController.waitUntilReady()
            await checkHostVersion()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopServer(_ server: LocalServer) async {
        guard let pid = server.pid, let port = server.port,
              stoppingServerID == nil else { return }
        stoppingServerID = server.id
        defer { stoppingServerID = nil }

        do {
            try await client.stopServer(pid: pid, port: port)
            try? await Task.sleep(for: .milliseconds(300))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
