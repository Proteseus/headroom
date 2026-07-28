import SwiftUI

@main
struct HeadroomMobileApp: App {
    @StateObject private var store = MobileUsageStore()
    @Environment(\.scenePhase) private var scenePhase

    private let exportDirectory = Self.argValue("--export-screenshots")

    init() {
        if CommandLine.arguments.contains("--export-screenshots") {
            // Skip BGTask registration during headless screenshot export.
            // Mark paired before the first frame so RootView shows Overview,
            // not the pairing sheet.
            UserDefaults.standard.set(true, forKey: MobileConnection.configuredKey)
            UserDefaults.standard.set(
                MobileConnection.defaultEndpoint,
                forKey: MobileConnection.endpointKey
            )
            return
        }
        MobileBackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            if let exportDirectory {
                RootView(store: store, exportDirectory: exportDirectory)
                    .task {
                        await Self.prepareExportFixture(
                            fixture: Self.argValue("--fixture"),
                            store: store
                        )
                    }
            } else {
                RootView(store: store)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard exportDirectory == nil else { return }
            switch phase {
            case .active:
                Task { await store.refresh() }
                store.startLiveUpdates()
            case .background:
                // .inactive is the app switcher and Control Center — keep
                // polling through those, stop only once we're really away.
                store.stopLiveUpdates()
                MobileBackgroundRefresh.schedule()
            default:
                break
            }
        }
    }

    private static func argValue(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: flag), args.indices.contains(idx + 1)
        else { return nil }
        return args[idx + 1]
    }

    @MainActor
    private static func prepareExportFixture(
        fixture: String?,
        store: MobileUsageStore
    ) async {
        UserDefaults.standard.set(true, forKey: MobileConnection.configuredKey)
        UserDefaults.standard.set(
            MobileConnection.defaultEndpoint,
            forKey: MobileConnection.endpointKey
        )

        if let fixture {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
                let snapshot = try JSONDecoder().decode(
                    UsageSnapshot.self, from: data)
                store.applySnapshot(snapshot)
            } catch {
                fputs("fixture decode failed: \(error)\n", stderr)
                return
            }
        } else {
            await store.refresh()
        }

        try? await Task.sleep(for: .milliseconds(900))
    }
}
