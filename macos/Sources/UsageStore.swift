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
    /// Ceiling for the fast retry after a failed poll. Long enough that a Mac
    /// with no host installed isn't spinning, short enough that a host which
    /// comes back is on screen before anyone reaches for the menu bar.
    private static let retryCeiling: TimeInterval = 30

    private var refreshLoop: Task<Void, Never>?
    private var lastInteraction = Date()
    private var consecutiveFailures = 0

    /// Who answered /health last. launchd hands the same port to whatever host
    /// it just started, so "still 200 on :8737" proves nothing — the build
    /// fingerprint and uptime are what tell us the process changed underneath.
    private var lastHostBuild: String?
    private var lastHostUptime: Int?

    /// Running builds we already tried to replace. If the reinstall doesn't
    /// take — a clone's LaunchAgent that keeps winning the port — this must not
    /// become a bootout/bootstrap loop every minute.
    private var autoUpdatedBuilds: Set<String> = []

    init() {}

    deinit {
        refreshLoop?.cancel()
    }

    private var client: HeadroomClient { HeadroomClient() }

    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            await self.tick()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self.nextInterval()))
                guard !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    /// One pass of the loop: ask who is answering before believing what it says.
    /// A host that restarted between polls gets a forced sync, so the popover
    /// stops showing the document the previous process left behind.
    private func tick() async {
        let restarted = await checkHostVersion()
        await refresh(forceSync: restarted)
    }

    /// Call when the user actually looks at the data — resumes the fast cadence.
    func noteInteraction() {
        lastInteraction = Date()
    }

    private func nextInterval() -> TimeInterval {
        // Nothing answered last time — the host is mid-restart, or launchd is
        // between agents. Sitting out a full minute (or five, when idle) leaves
        // dead meters long after it is back, so retry fast and back off.
        if consecutiveFailures > 0 {
            return min(Self.retryCeiling,
                       pow(2, Double(min(consecutiveFailures, 5))))
        }
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

    /// - Parameter forceSync: Ask the host to re-poll every source before
    ///   reading `/usage`. Used after wake and by callers that want fresh
    ///   numbers, not just the last published document.
    func refresh(forceSync: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // Coming back from a failed poll: the host may be up again while its
        // sources are still sitting on pre-outage ages. A plain GET looks like
        // nothing happened — kick a sync so the dashboard actually moves.
        let recovering = errorMessage != nil
        do {
            var value = try await client.fetchUsage()
            snapshot = value
            errorMessage = nil
            onSnapshotChange?(value, true)

            if recovering || forceSync {
                try? await client.refresh(sources: nil)
                await client.waitForRefresh(sources: nil)
                value = try await client.fetchUsage()
                snapshot = value
                onSnapshotChange?(value, true)
            }

            lastRefresh = Date()
            consecutiveFailures = 0
            // Written once per successful pass, after any forced re-sync, so
            // the widget never picks up the pre-sync document. The Mac is the
            // source here — this cache is current, unlike the phone's.
            HeadroomWidgetCache.save(snapshot)
        } catch {
            consecutiveFailures += 1
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

    /// Ask /health which host is actually answering; true when that is a
    /// different process than the one we last talked to.
    ///
    /// On the refresh path on purpose. An update landing underneath a running
    /// app — a reinstalled LaunchAgent, a Release .app replacing a clone's
    /// host — used to sit unnoticed until the next launch or wake, which is the
    /// whole window in which the popover renders fields the running host never
    /// learned to emit. It costs one loopback GET against a cached document.
    ///
    /// - Parameter autoUpdate: false from `updateHost()`, which is already the
    ///   update and must not stack a second install on the same skew.
    @discardableResult
    func checkHostVersion(autoUpdate: Bool = true) async -> Bool {
        guard let report = try? await client.health() else { return false }

        let restarted = (lastHostBuild != nil && report.build != lastHostBuild)
            || (lastHostUptime.map { (report.uptimeS ?? 0) < $0 } ?? false)
        lastHostBuild = report.build
        lastHostUptime = report.uptimeS

        hostSkew = HostController.skew(against: report)
        if let version = report.version {
            hostVersionLabel = report.build.map { "Host \(version) (\($0))" }
                ?? "Host \(version)"
        } else {
            hostVersionLabel = "Host predates version reporting"
        }
        if autoUpdate, let hostSkew {
            await installBundledHost(replacing: hostSkew)
        }
        return restarted
    }

    /// This .app ships a host and launchd is serving a different one. Replace it
    /// on sight rather than parking an offer behind a button: until someone
    /// clicks, every number on screen came out of a host this app can't fully
    /// decode. Once per running build — see `autoUpdatedBuilds`.
    private func installBundledHost(replacing skew: HostSkew) async {
        let key = skew.runningBuild ?? "pre-1.0"
        guard !autoUpdatedBuilds.contains(key) else { return }
        autoUpdatedBuilds.insert(key)
        await updateHost()
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
            await checkHostVersion(autoUpdate: false)
            // The host it replaced published a document; a plain GET would hand
            // us that one back with its pre-restart ages.
            await refresh(forceSync: true)
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
