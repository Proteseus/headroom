import SwiftUI

struct RootView: View {
    @ObservedObject var store: MobileUsageStore
    @State private var showsConnection = false

    var body: some View {
        Group {
            if store.isConfigured {
                DashboardView(store: store, showsConnection: $showsConnection)
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

private struct DashboardView: View {
    @ObservedObject var store: MobileUsageStore
    @Binding var showsConnection: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    StatusCard(store: store)
                    QuotaGrid(providers: store.visibleProviders)
                    AttentionCard(attention: store.snapshot.attention)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Headroom")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connection", systemImage: "gearshape") {
                        showsConnection = true
                    }
                }
            }
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
}

private struct StatusCard: View {
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
        if store.errorMessage != nil { return "Mac unavailable" }
        if store.snapshot.attention?.needsAttention == true {
            return store.snapshot.attention?.summary ?? "Needs attention"
        }
        return "All systems clear"
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

private struct QuotaGrid: View {
    let providers: [MobileProvider]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coding quotas")
                .font(.headline)
            if providers.isEmpty {
                ContentUnavailableView(
                    "No quota data",
                    systemImage: "chart.donut",
                    description: Text("Refresh after the Mac host finishes its first sync.")
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(providers) { provider in
                    ProviderRow(provider: provider)
                    if provider.id != providers.last?.id {
                        Divider()
                    }
                }
            }
        }
        .headroomCard()
    }
}

private struct ProviderRow: View {
    let provider: MobileProvider

    var body: some View {
        HStack(spacing: 16) {
            QuotaRings(
                pools: Array(provider.visiblePools.prefix(3)),
                tint: Color(hex: provider.accent) ?? .cyan
            )
            .frame(width: 82, height: 82)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(provider.displayTitle)
                        .font(.headline)
                    if let plan = provider.plan {
                        Text(plan)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(provider.visiblePools.prefix(3).enumerated()), id: \.offset) {
                    item in
                    let pool = item.element
                    HStack {
                        Text(pool.title ?? "Quota")
                        Spacer()
                        Text(pool.pct.map { "\(Int($0.rounded()))%" } ?? "—")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let headline = provider.headline {
                    Text(headline)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                } else if provider.ok == false, let error = provider.error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct QuotaRings: View {
    let pools: [MobilePool]
    let tint: Color

    var body: some View {
        ZStack {
            ForEach(Array(pools.enumerated()), id: \.offset) { index, pool in
                let inset = CGFloat(index * 9)
                Circle()
                    .stroke(tint.opacity(0.12), lineWidth: 6)
                    .padding(inset)
                Circle()
                    .trim(from: 0, to: min(max((pool.pct ?? 0) / 100, 0), 1))
                    .stroke(
                        tint.opacity(1 - Double(index) * 0.2),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(inset)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            pools.map { "\($0.title ?? "Quota") \(Int(($0.pct ?? 0).rounded())) percent" }
                .joined(separator: ", ")
        )
    }
}

private struct AttentionCard: View {
    let attention: MobileAttention?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attention")
                .font(.headline)
            let reasons = attention?.reasons ?? []
            if reasons.isEmpty {
                Label("Nothing needs attention", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ForEach(reasons.prefix(5)) { reason in
                    HStack(alignment: .top, spacing: 9) {
                        Circle()
                            .fill(reason.level == "critical" ? .red : .orange)
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        Text(reason.summary ?? "Needs attention")
                            .font(.subheadline)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .headroomCard()
    }
}

private extension View {
    func headroomCard() -> some View {
        self
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private extension Color {
    init?(hex: String?) {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        value.removeAll(where: { $0 == "#" })
        guard value.count == 6, let rgb = Int(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }
}
