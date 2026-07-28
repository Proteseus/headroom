import Foundation

@MainActor
final class MobileUsageStore: ObservableObject {
    @Published private(set) var snapshot = MobileUsageSnapshot.empty
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefresh: Date?

    var isConfigured: Bool { MobileConnection.isConfigured }

    var visibleProviders: [MobileProvider] {
        let enabledQuotaIDs = Set(
            (snapshot.sources ?? [])
                .filter { $0.kind == "quota" && $0.enabled != false }
                .map(\.id)
        )
        return (snapshot.providers ?? []).filter {
            $0.enabled != false
                && (enabledQuotaIDs.isEmpty || enabledQuotaIDs.contains($0.id))
        }
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
            if forceServerSync {
                try await client.requestRefresh()
                try await Task.sleep(for: .milliseconds(700))
            }
            snapshot = try await client.fetchUsage()
            errorMessage = nil
            lastRefresh = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func configured() async {
        objectWillChange.send()
        await refresh()
    }
}
