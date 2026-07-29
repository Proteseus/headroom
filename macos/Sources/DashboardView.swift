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
    private var selectedDashboardRaw = DashboardSelection.overview
    @State private var serverToStop: LocalServer?

    private var visibleProviders: [QuotaProviderInfo] {
        store.snapshot.visibleQuotaProviders
    }

    private var isOverview: Bool {
        selectedDashboardRaw == DashboardSelection.overview
    }

    /// The setup card is for "there is no host to talk to", not "the last call
    /// failed". `errorMessage` collects every failure in the app — a refused
    /// server stop, one flaky poll — and keying off it threw the whole
    /// dashboard back to the setup sheet over things the host was fine for.
    ///
    /// First run is not part of this condition any more: it has its own window
    /// (`WelcomeWindowController`), so an empty dashboard behind the welcome is
    /// the dashboard, not a second copy of onboarding.
    private var needsSetup: Bool {
        !store.hostReachable
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    if needsSetup {
                        SetupView(store: store) {
                            Task { await store.refresh() }
                        }
                    } else {
                        if let skew = store.hostSkew {
                            HostSkewBanner(skew: skew, store: store)
                        }
                        providerSwitcher
                        // Warnings first: failed deploys / Actions / etc. stay
                        // visible without scrolling past quota charts. On
                        // provider tabs, only show the card while something
                        // needs attention.
                        let hasAttentionWarning =
                            store.snapshot.attention?.isWarning == true
                        if isOverview || hasAttentionWarning {
                            AttentionCard(store: store)
                        }
                        if isOverview {
                            QuotaOverviewCard(snapshot: store.snapshot) { providerID in
                                selectedProviderRaw = providerID
                                selectedDashboardRaw = providerID
                            }
                            OverviewBurndownCard(snapshot: store.snapshot)
                            DailyBurnCard(
                                days: store.snapshot.byDay ?? [],
                                providerIDs: visibleProviders.map(\.id),
                                tintFor: store.snapshot.tint(forProviderID:)
                            )
                        } else {
                            let meter = store.snapshot.meter(
                                forProviderID: selectedDashboardRaw)
                            ProviderQuotaCard(
                                meter: meter,
                                tint: store.snapshot.tint(
                                    forProviderID: selectedDashboardRaw)
                            )
                            BurndownCard(
                                providerID: selectedDashboardRaw,
                                rings: store.snapshot.burndownRings(
                                    forProviderID: selectedDashboardRaw),
                                tint: store.snapshot.tint(
                                    forProviderID: selectedDashboardRaw)
                            )
                        }
                        ActivitySection(items: store.snapshot.activity ?? [])
                        SupabaseSection(data: store.snapshot.supabase)
                        PlausibleSection(data: store.snapshot.plausible)
                        ServersSection(store: store, pendingStop: $serverToStop)
                        MachinesSection(machines: store.snapshot.peerMachines)
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
        if store.snapshot.attention?.isWarning == true {
            if store.snapshot.attention?.isCritical == true {
                return HeadroomPalette.red
            }
            return HeadroomPalette.amber
        }
        return HeadroomPalette.green
    }

    /// The popover is a fixed width, so past four or five providers the tab
    /// names have to give way to the marks rather than wrap and spill out of
    /// it. Widest layout that fits wins; the last one always fits.
    private var providerSwitcher: some View {
        ViewThatFits(in: .horizontal) {
            switcherRow(labels: .all)
            switcherRow(labels: .selectedOnly)
            switcherRow(labels: .none)
        }
        .onChange(of: visibleProviders.map(\.id)) { _, ids in
            // Drop onto Overview if the selected provider was disabled.
            if !isOverview, !ids.contains(selectedDashboardRaw) {
                selectedDashboardRaw = DashboardSelection.overview
            }
        }
    }

    private func switcherRow(labels: DashboardTabLabels) -> some View {
        let tabs = DashboardSelection.tabs(for: visibleProviders)
        return HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tabID in
                let isSelected = selectedDashboardRaw == tabID
                DashboardTabButton(
                    tabID: tabID,
                    title: DashboardSelection.title(
                        for: tabID, providers: visibleProviders),
                    isSelected: isSelected,
                    showsTitle: labels.showsTitle(isSelected: isSelected)
                ) {
                    selectedDashboardRaw = tabID
                    if tabID != DashboardSelection.overview {
                        selectedProviderRaw = tabID
                    }
                }
            }
        }
        .padding(3)
        .background(
            Color(nsColor: .separatorColor).opacity(0.35),
            in: Capsule(style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard")
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
            .help(HeadroomCopy.settings)
            .accessibilityLabel(HeadroomCopy.settings)
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
        if store.isRefreshing {
            // Recovering from an outage kicks /sync/refresh; say so instead of
            // leaving "Updated … ago" frozen under the spinner.
            return store.errorMessage == nil && store.lastRefresh != nil
                ? HeadroomCopy.refreshing
                : HeadroomCopy.reconnecting
        }
        if let error = store.errorMessage {
            return error
        }
        if let attention = store.snapshot.attention, attention.isWarning {
            return attention.summary ?? HeadroomCopy.needsAttention
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

/// How much of each tab's name the switcher can afford to draw.
enum DashboardTabLabels {
    case all
    case selectedOnly
    case none

    func showsTitle(isSelected: Bool) -> Bool {
        switch self {
        case .all: true
        case .selectedOnly: isSelected
        case .none: false
        }
    }
}

/// Segment in the overview/provider switcher. Plain buttons on macOS only
/// hit-test their text unless the padded capsule is an explicit content shape.
private struct DashboardTabButton: View {
    let tabID: String
    let title: String
    let isSelected: Bool
    /// False once the row can only fit the marks. The name still reaches
    /// VoiceOver and the tooltip, so a mark-only tab is never unlabelled.
    var showsTitle = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if tabID == DashboardSelection.overview {
                    Image(systemName: "rectangle.grid.2x2")
                        .font(.system(size: 10.5, weight: .medium))
                } else {
                    ProviderMark(providerID: tabID, size: 11)
                }
                if showsTitle {
                    // Fixed, so the row measures at its untruncated width —
                    // that measurement is what ViewThatFits rejects when it
                    // falls through to the next layout.
                    Text(title)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
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
                } else if hovering {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
