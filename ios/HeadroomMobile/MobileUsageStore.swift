import Foundation

@MainActor
final class MobileUsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot.empty
    @Published private(set) var isLoading = false
    @Published private(set) var stoppingServerID: String?
    @Published private(set) var changingSourceID: String?
    @Published private(set) var mobilePermissions = MobilePermissions.allDisabled
    @Published private(set) var errorMessage: String?
    /// When the Mac handed us the snapshot on screen — live this session, or
    /// read back from the archive on a cold launch.
    @Published private(set) var capturedAt: Date?
    /// The snapshot on screen came off disk; nothing has reached the Mac yet.
    @Published private(set) var isShowingArchive = false

    init() {
        guard let entry = MobileSnapshotArchive.load() else { return }
        snapshot = entry.snapshot
        capturedAt = entry.capturedAt
        isShowingArchive = true
    }

    var isConfigured: Bool { MobileConnection.isConfigured }

    var visibleProviders: [QuotaProviderInfo] {
        snapshot.visibleQuotaProviders
    }

    /// True once we are drawing numbers the Mac has not confirmed this session,
    /// whether that is a cold launch with the Mac asleep or a refresh that
    /// failed after one succeeded.
    var isStale: Bool { isShowingArchive || errorMessage != nil }

    /// Whether there is anything real on screen, live or archived.
    var hasSnapshot: Bool { capturedAt != nil }

    /// How old the numbers on screen are, for the copy that says so.
    var age: TimeInterval? {
        capturedAt.map { Date().timeIntervalSince($0) }
    }

    func refresh(forceServerSync: Bool = false) async {
        guard !isLoading, isConfigured else { return }
        isLoading = true
        defer { isLoading = false }

        // Stale / archived / errored: a plain GET can succeed with the same
        // pre-outage document and look like nothing happened. Force sources
        // when recovering so Connected lands with fresh meters.
        let recovering = isStale
        let client = MobileHeadroomClient(
            endpoint: MobileConnection.endpoint,
            token: MobileTokenStore.read() ?? ""
        )
        do {
            if let permissions = try? await client.fetchMobilePermissions() {
                mobilePermissions = permissions
            }
            if forceServerSync || recovering {
                if mobilePermissions.refresh {
                    try await client.requestRefresh()
                    await client.waitForRefresh()
                }
            }
            snapshot = try await client.fetchAndArchiveUsage()
            errorMessage = nil
            capturedAt = Date()
            isShowingArchive = false
            MobileWidgetCache.save(snapshot)
            await MobileNotifications.notifyIfNeeded(snapshot.attention)
        } catch {
            // Keep whatever is on screen. Losing a week of burndown because the
            // Mac went to sleep is worse than showing it with its age attached.
            errorMessage = error.localizedDescription
        }
    }

    func configured() async {
        objectWillChange.send()
        await refresh()
    }

    /// Fixture path for README / marketing screenshots (no network).
    func applySnapshot(_ value: UsageSnapshot) {
        snapshot = value
        errorMessage = nil
        capturedAt = Date()
        isShowingArchive = false
        mobilePermissions = .allEnabled
        isLoading = false
    }

    /// Called when the connection is re-pointed. The archive describes the Mac
    /// we just stopped talking to, so it goes with it.
    func forgetArchive() {
        MobileSnapshotArchive.clear()
        snapshot = .empty
        capturedAt = nil
        isShowingArchive = false
    }

    func setSource(_ id: String, enabled: Bool) async {
        guard changingSourceID == nil, mobilePermissions.sources else { return }
        changingSourceID = id
        defer { changingSourceID = nil }
        do {
            let client = mobileClient
            _ = try await client.setSources([id: enabled])
            await refresh(forceServerSync: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func acknowledgeAttention() async {
        guard let attention = snapshot.attention, attention.isWarning,
              mobilePermissions.read else { return }
        do {
            try await mobileClient.acknowledgeAttention(attention.fingerprint)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopServer(_ server: LocalServer) async {
        guard let pid = server.pid, let port = server.port,
              stoppingServerID == nil, mobilePermissions.servers else { return }
        stoppingServerID = server.id
        defer { stoppingServerID = nil }
        do {
            try await mobileClient.stopServer(pid: pid, port: port)
            try? await Task.sleep(for: .milliseconds(300))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var mobileClient: MobileHeadroomClient {
        MobileHeadroomClient(
            endpoint: MobileConnection.endpoint,
            token: MobileTokenStore.read() ?? ""
        )
    }
}
