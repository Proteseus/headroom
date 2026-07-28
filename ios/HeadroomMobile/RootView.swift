import SwiftUI

enum MobileTab: String, CaseIterable, Hashable {
    case overview
    case quotas
    case activity
    case services
    case settings
}

struct RootView: View {
    @ObservedObject var store: MobileUsageStore
    /// When set, cycle tabs and drop `.ios-shot-ready-<tab>` markers for the
    /// screenshot script (see `scripts/generate_screenshots.sh`).
    var exportDirectory: String? = nil

    @State private var showsConnection = false
    @State private var selectedTab: MobileTab = .overview

    var body: some View {
        Group {
            if store.isConfigured {
                TabView(selection: $selectedTab) {
                    NavigationStack {
                        OverviewScreen(store: store)
                    }
                    .tabItem { Label(HeadroomCopy.overview, systemImage: "circle.grid.2x2") }
                    .tag(MobileTab.overview)

                    NavigationStack {
                        QuotasScreen(store: store)
                    }
                    .tabItem { Label(HeadroomCopy.quotas, systemImage: "chart.pie.fill") }
                    .tag(MobileTab.quotas)

                    NavigationStack {
                        ActivityScreen(store: store)
                    }
                    .tabItem { Label(HeadroomCopy.activity, systemImage: "bolt.horizontal.circle") }
                    .tag(MobileTab.activity)

                    NavigationStack {
                        ServicesScreen(store: store)
                    }
                    .tabItem { Label(HeadroomCopy.services, systemImage: "server.rack") }
                    .tag(MobileTab.services)

                    NavigationStack {
                        MobileSettingsScreen(
                            store: store,
                            showsConnection: $showsConnection
                        )
                    }
                    .tabItem { Label(HeadroomCopy.settings, systemImage: "gearshape") }
                    .tag(MobileTab.settings)
                }
            } else {
                NavigationStack {
                    PairingView(store: store)
                }
            }
        }
        .sheet(isPresented: $showsConnection) {
            NavigationStack {
                PairingView(store: store, isEditing: true)
            }
        }
        .task(id: exportDirectory) {
            guard let exportDirectory else { return }
            await runScreenshotExport(to: exportDirectory)
        }
    }

    /// Signal each tab after Charts settle so `simctl io screenshot` can grab it.
    @MainActor
    private func runScreenshotExport(to directory: String) async {
        let root = URL(fileURLWithPath: directory)
        for tab in MobileTab.allCases where tab != .settings {
            selectedTab = tab
            // Layout + chart settle.
            try? await Task.sleep(for: .milliseconds(1100))
            let ready = root.appendingPathComponent(".ios-shot-ready-\(tab.rawValue)")
            try? Data().write(to: ready)
            fputs("ios fixture ready \(tab.rawValue)\n", stderr)
            // Wait until the script removes the marker (or timeout).
            for _ in 0..<80 {
                if !FileManager.default.fileExists(atPath: ready.path) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        // Legacy marker so older scripts still unblock on overview alone.
        let legacy = root.appendingPathComponent(".ios-shot-ready")
        try? Data().write(to: legacy)
    }
}

private struct OverviewScreen: View {
    @ObservedObject var store: MobileUsageStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                MobileStatusCard(store: store)
                QuotaOverviewCard(
                    providers: store.visibleProviders,
                    burndown: store.snapshot.burndown ?? [:]
                )
                OverallBurndownChart(
                    providers: store.visibleProviders,
                    burndown: store.snapshot.burndown ?? [:]
                )
                MobileAttentionCard(store: store)
                DailyBurnChart(
                    days: store.snapshot.byDay ?? [],
                    providers: store.visibleProviders
                )
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(HeadroomCopy.product)
        .refreshable {
            await store.refresh(forceServerSync: true)
        }
        .task {
            // Archived content still counts as "nothing fetched yet".
            if store.capturedAt == nil || store.isShowingArchive {
                await store.refresh()
            }
        }
    }
}

struct MobileStatusCard: View {
    @ObservedObject var store: MobileUsageStore

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.headline)
                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isLoading {
                ProgressView()
            } else {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await store.refresh(forceServerSync: true) }
                }
                .labelStyle(.iconOnly)
            }
        }
        .headroomCard()
    }

    private var statusTitle: String {
        if store.isLoading, store.isStale {
            return HeadroomCopy.reconnecting
        }
        if store.isStale {
            return store.hasSnapshot
                ? HeadroomCopy.recentHistory
                : HeadroomCopy.macUnavailable
        }
        if store.isLoading {
            return HeadroomCopy.refreshing
        }
        if store.snapshot.attention?.isWarning == true {
            return HeadroomCopy.needsAttention
        }
        return HeadroomCopy.connected
    }

    private var statusSubtitle: String {
        if let error = store.errorMessage {
            guard let age = store.age else { return error }
            return "\(HeadroomCopy.ago(age)) · \(error)"
        }
        // Archived and not yet contradicted: the fetch is still in flight.
        if store.isShowingArchive, let age = store.age {
            return HeadroomCopy.ago(age)
        }
        if let date = store.capturedAt {
            return "Updated \(date.formatted(date: .omitted, time: .shortened))"
        }
        return MobileConnection.endpoint
    }

    private var statusColor: Color {
        HeadroomPalette.status(
            level: store.snapshot.attention?.level,
            isStale: store.isStale
        )
    }
}

/// The one-line "this is saved, not live" marker for the screens that have no
/// status card of their own. Every screen that draws numbers needs to say when
/// they stopped being current, or the Quotas tab quietly lies for a day.
struct ArchivedDataNotice: View {
    @ObservedObject var store: MobileUsageStore

    var body: some View {
        if store.isStale, let age = store.age {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(HeadroomCopy.recentHistory(age: age))
                        .font(.footnote.weight(.medium))
                    Text(HeadroomCopy.recentHistoryHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(HeadroomPalette.amber)
            }
        }
    }
}

private struct MobileAttentionCard: View {
    @ObservedObject var store: MobileUsageStore

    var body: some View {
        let attention = store.snapshot.attention
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(HeadroomCopy.attention)
                    .font(.headline)
                Spacer()
                if attention?.isWarning == true {
                    Button(HeadroomCopy.clearAttention, systemImage: "xmark.circle") {
                        Task { await store.acknowledgeAttention() }
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            let reasons = attention?.reasons ?? []
            if reasons.isEmpty {
                Label(HeadroomCopy.allClear, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(HeadroomPalette.green)
            } else {
                ForEach(reasons.prefix(5)) { reason in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(HeadroomPalette.attention(reason.level))
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        Text(reason.summary ?? HeadroomCopy.needsAttention)
                            .font(.subheadline)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .headroomCard()
    }
}

extension View {
    func headroomCard() -> some View {
        self
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
