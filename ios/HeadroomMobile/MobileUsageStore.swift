import Foundation

@MainActor
final class MobileUsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot.empty
    @Published private(set) var isLoading = false
    @Published private(set) var stoppingServerID: String?
    @Published private(set) var changingSourceID: String?
    @Published private(set) var mobilePermissions = MobilePermissions.allDisabled
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefresh: Date?

    var isConfigured: Bool { MobileConnection.isConfigured }

    var visibleProviders: [QuotaProviderInfo] {
        snapshot.visibleQuotaProviders
    }

    func refresh(forceServerSync: Bool = false) async {
        guard !isLoading, isConfigured else { return }
        isLoading = true
        defer { isLoading = false }

        let client = MobileHeadroomClient(
            endpoint: MobileConnection.endpoint,
            token: MobileTokenStore.read() ?? ""
        )
        do {
            if let permissions = try? await client.fetchMobilePermissions() {
                mobilePermissions = permissions
            }
            if forceServerSync {
                if mobilePermissions.refresh {
                    try await client.requestRefresh()
                    try await Task.sleep(for: .milliseconds(700))
                }
            }
            snapshot = try await client.fetchUsage()
            errorMessage = nil
            lastRefresh = Date()
            MobileWidgetCache.save(snapshot)
            await MobileNotifications.notifyIfNeeded(snapshot.attention)
        } catch {
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
        lastRefresh = Date()
        mobilePermissions = .allEnabled
        isLoading = false
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
