import SwiftUI

struct RootView: View {
    @ObservedObject var store: MobileUsageStore
    @State private var showsConnection = false

    var body: some View {
        Group {
            if store.isConfigured {
                TabView {
                    NavigationStack {
                        OverviewScreen(store: store)
                    }
                    .tabItem { Label(HeadroomCopy.overview, systemImage: "circle.grid.2x2") }

                    NavigationStack {
                        QuotasScreen(store: store)
                    }
                    .tabItem { Label(HeadroomCopy.quotas, systemImage: "chart.pie.fill") }

                    NavigationStack {
                        ActivityScreen(store: store)
                    }
                    .tabItem { Label(HeadroomCopy.activity, systemImage: "bolt.horizontal.circle") }

                    NavigationStack {
                        ServicesScreen(store: store)
                    }
                    .tabItem { Label(HeadroomCopy.services, systemImage: "server.rack") }

                    NavigationStack {
                        MobileSettingsScreen(
                            store: store,
                            showsConnection: $showsConnection
                        )
                    }
                    .tabItem { Label(HeadroomCopy.settings, systemImage: "gearshape") }
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
            if store.lastRefresh == nil {
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
        if store.errorMessage != nil { return HeadroomCopy.macUnavailable }
        if store.snapshot.attention?.isWarning == true {
            return HeadroomCopy.needsAttention
        }
        return HeadroomCopy.connected
    }

    private var statusSubtitle: String {
        if let error = store.errorMessage { return error }
        if let date = store.lastRefresh {
            return "Updated \(date.formatted(date: .omitted, time: .shortened))"
        }
        return MobileConnection.endpoint
    }

    private var statusColor: Color {
        if store.errorMessage != nil { return .orange }
        switch store.snapshot.attention?.level {
        case "critical": return .red
        case "warn": return .orange
        default: return .green
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
                    .foregroundStyle(.green)
            } else {
                ForEach(reasons.prefix(5)) { reason in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(reason.level == "critical" ? .red : .orange)
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
