import AppKit
import SwiftUI

/// The popover shell: header, tab switcher, footer, and the stack of sections.
/// Each section owns its own rendering and preferences — see QuotaSection,
/// ActivitySection, SupabaseSection, ServersSection.
struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("selectedProvider")
    private var selectedProviderRaw = UsageProvider.codex.rawValue
    @AppStorage("selectedDashboard")
    private var selectedDashboardRaw = DashboardSelection.overview.rawValue
    @AppStorage("setupCompleted")
    private var setupCompleted = false
    @State private var serverToStop: LocalServer?

    private var selectedProvider: UsageProvider {
        UsageProvider(rawValue: selectedProviderRaw) ?? .codex
    }

    private var selectedDashboard: DashboardSelection {
        DashboardSelection(rawValue: selectedDashboardRaw) ?? .overview
    }

    private var needsSetup: Bool {
        !setupCompleted || store.errorMessage != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    if needsSetup {
                        SetupView(
                            store: store,
                            isFirstRun: !setupCompleted
                        ) {
                            setupCompleted = true
                            Task { await store.refresh() }
                        }
                    } else {
                        providerSwitcher
                        if selectedDashboard == .overview {
                            QuotaOverviewCard(snapshot: store.snapshot) { provider in
                                selectedProviderRaw = provider.rawValue
                                selectedDashboardRaw = provider.rawValue
                            }
                            OverviewBurndownCard(snapshot: store.snapshot)
                            DailyBurnCard(
                                days: store.snapshot.byDay ?? [],
                                providers: store.snapshot.activeQuotaProviders,
                                tintFor: store.snapshot.tint(for:)
                            )
                            AttentionCard(snapshot: store.snapshot)
                        } else {
                            ProviderQuotaCard(
                                provider: selectedProvider,
                                meter: store.snapshot.meter(for: selectedProvider),
                                tint: store.snapshot.tint(for: selectedProvider)
                            )
                            BurndownCard(
                                provider: selectedProvider,
                                rings: store.snapshot.burndownRings(for: selectedProvider),
                                tint: store.snapshot.tint(for: selectedProvider)
                            )
                        }
                        ActivitySection(items: store.snapshot.activity ?? [])
                        SupabaseSection(data: store.snapshot.supabase)
                        ServersSection(store: store, pendingStop: $serverToStop)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 390, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(item: $serverToStop) { server in
            Alert(
                title: Text("Stop \(server.name ?? "server")?"),
                message: Text("This terminates the local process."),
                primaryButton: .destructive(Text("Stop")) {
                    Task { await store.stopServer(server) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Headroom")
                    .font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Circle()
                    .fill(headerDotColor)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(16)
    }

    private var headerDotColor: Color {
        if store.errorMessage != nil { return HeadroomPalette.amber }
        if AttentionAck.shouldShowPip(for: store.snapshot.attention) {
            if store.snapshot.attention?.isCritical == true {
                return HeadroomPalette.red
            }
            return HeadroomPalette.amber
        }
        return HeadroomPalette.green
    }

    private var providerSwitcher: some View {
        let tabs = DashboardSelection.tabs(for: store.snapshot.activeQuotaProviders)
        return HStack(spacing: 2) {
            ForEach(tabs, id: \.rawValue) { selection in
                let isSelected = selectedDashboardRaw == selection.rawValue
                Button {
                    selectedDashboardRaw = selection.rawValue
                    if let provider = selection.provider {
                        selectedProviderRaw = provider.rawValue
                    }
                } label: {
                    Text(selection.title)
                        .font(.caption.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            Color(nsColor: .separatorColor).opacity(0.35),
            in: Capsule(style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard")
        .onChange(of: store.snapshot.activeQuotaProviders.map(\.rawValue)) { _, ids in
            // Drop onto Overview if the selected provider was disabled.
            if selectedDashboard != .overview,
               !ids.contains(selectedDashboardRaw) {
                selectedDashboardRaw = DashboardSelection.overview.rawValue
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("Refresh")
            .accessibilityLabel("Refresh")
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit")
            .accessibilityLabel("Quit")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var statusLine: String {
        if let error = store.errorMessage {
            return error
        }
        if let attention = store.snapshot.attention,
           AttentionAck.shouldShowPip(for: attention) {
            return attention.summary ?? "Needs attention"
        }
        if let stale = worstStaleSource {
            let age = stale.ageS ?? 0
            let minutes = max(1, age / 60)
            let title = stale.title ?? stale.id
            return "\(title) · \(minutes)m stale"
        }
        if let lastRefresh = store.lastRefresh {
            return "Updated \(lastRefresh.formatted(.relative(presentation: .named)))"
        }
        return "Connecting to \(HeadroomClient.displayEndpoint)"
    }

    private var worstStaleSource: SyncSource? {
        (store.snapshot.sources ?? [])
            .filter { ($0.enabled ?? true) && $0.stale == true }
            .sorted { ($0.ageS ?? 0) > ($1.ageS ?? 0) }
            .first
    }
}
