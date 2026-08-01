import AppKit
import SwiftUI

/// The popover shell: header, semantic mode switcher, footer, and the stack of
/// sections. Provider selection stays inside Usage, matching the iPhone's
/// Usage → provider detail relationship.
/// Each section owns its own rendering and preferences — see QuotaSection,
/// ActivitySection, SupabaseSection, ServersSection.
struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @AppStorage("selectedProvider")
    private var selectedProviderRaw = UsageProvider.codex.rawValue
    @AppStorage("selectedDashboard")
    private var selectedDashboardRaw = DashboardSelection.overview
    @AppStorage("selectedDashboardMode")
    private var selectedModeRaw = DashboardMode.overview.rawValue
    @State private var serverToStop: LocalServer?
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var updateInstallMessage: String?

    private var visibleProviders: [QuotaProviderInfo] {
        store.snapshot.visibleQuotaProviders
    }

    private var selectedMode: DashboardMode {
        DashboardMode(rawValue: selectedModeRaw) ?? .overview
    }

    private var isOverview: Bool {
        selectedMode == .overview
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
                        modeSwitcher
                        if selectedMode == .attention {
                            AttentionSection(store: store)
                        } else if selectedMode == .activity {
                            ActivitySection(items: store.snapshot.activity ?? [])
                            SupabaseSection(data: store.snapshot.supabase)
                            PlausibleSection(data: store.snapshot.plausible)
                            PostHogSection(data: store.snapshot.posthog)
                            ServersSection(store: store, pendingStop: $serverToStop)
                            MachinesSection(machines: store.snapshot.peerMachines)
                        } else {
                            providerSwitcher
                            if selectedDashboardRaw == DashboardSelection.overview {
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
                                SpendCard(
                                    history: store.snapshot.history,
                                    today: store.snapshot.today
                                )
                            } else {
                                let providerID = selectedDashboardRaw
                                let meter = store.snapshot.meter(
                                    forProviderID: providerID)
                                ProviderQuotaCard(
                                    meter: meter,
                                    subscriptionPricing: store.snapshot
                                        .visibleQuotaProviders
                                        .first { $0.id == providerID }?
                                        .subscriptionPricing,
                                    tint: store.snapshot.tint(
                                        forProviderID: providerID)
                                )
                                BurndownCard(
                                    providerID: providerID,
                                    rings: store.snapshot.burndownRings(
                                        forProviderID: providerID),
                                    tint: store.snapshot.tint(
                                        forProviderID: providerID),
                                    resetNoteURL: store.snapshot
                                        .visibleQuotaProviders
                                        .first { $0.id == providerID }?
                                        .resetNoteURL
                                        .flatMap(URL.init(string:))
                                )
                            }
                        }
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
        .alert(
            "Couldn’t install update",
            isPresented: Binding(
                get: { updateInstallMessage != nil },
                set: { if !$0 { updateInstallMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { updateInstallMessage = nil }
        } message: {
            Text(updateInstallMessage ?? "Please try again from Settings.")
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(DashboardMode.allCases, id: \.self) { mode in
                Button {
                    selectedModeRaw = mode.rawValue
                    if mode == .overview {
                        selectedDashboardRaw = DashboardSelection.overview
                    }
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .font(.caption.weight(
                            selectedMode == mode ? .semibold : .medium))
                        .foregroundStyle(
                            selectedMode == mode ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 4)
                        .background {
                            if selectedMode == mode {
                                Capsule(style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .help(mode.title)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(
                    selectedMode == mode ? .isSelected : [])
            }
        }
        .padding(3)
        .background(
            Color(nsColor: .separatorColor).opacity(0.35),
            in: Capsule(style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard mode")
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

    /// Always icon + label. Named accounts use the user label beside the
    /// brand mark — "Claude · Work" next to a Claude glyph truncates to the
    /// brand and hides the only word that told the tabs apart. Extra
    /// providers share the fixed popover width and truncate rather than
    /// dropping names (which left friend setups looking like icon-only chrome).
    private var providerSwitcher: some View {
        let tabs = DashboardSelection.tabs(for: visibleProviders)
        return HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tabID in
                let isSelected = selectedDashboardRaw == tabID
                let fullTitle = DashboardSelection.title(
                    for: tabID, providers: visibleProviders)
                DashboardTabButton(
                    tabID: tabID,
                    title: DashboardSelection.markTitle(
                        for: tabID, providers: visibleProviders),
                    accessibilityTitle: fullTitle,
                    isSelected: isSelected
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
        .onChange(of: visibleProviders.map(\.id)) { _, ids in
            // Drop onto Summary if the selected provider was disabled.
            if !isOverview, !ids.contains(selectedDashboardRaw) {
                selectedDashboardRaw = DashboardSelection.overview
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
            if let update = updates.available, UpdateCheck.canSelfUpdate {
                Button {
                    do {
                        try UpdateInstaller.install(update)
                    } catch {
                        updateInstallMessage = error.localizedDescription
                    }
                } label: {
                    Label(
                        HeadroomCopy.newVersionAvailable,
                        systemImage: "arrow.down.circle.fill"
                    )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("Install Headroom \(update.version)")
                .accessibilityLabel(
                    "\(HeadroomCopy.newVersionAvailable): install Headroom \(update.version)"
                )
            }
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

/// Segment in the summary/provider switcher. Plain buttons on macOS only
/// hit-test their text unless the padded capsule is an explicit content shape.
private struct DashboardTabButton: View {
    let tabID: String
    let title: String
    /// Spoken / hover name. Keeps the brand when the visible title is only
    /// the account label next to the mark.
    var accessibilityTitle: String = ""
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    private var spokenTitle: String {
        accessibilityTitle.isEmpty ? title : accessibilityTitle
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if tabID == DashboardSelection.overview {
                    Image(systemName: "rectangle.grid.2x2")
                        .font(.system(size: 10.5, weight: .medium))
                } else {
                    ProviderMark(providerID: tabID, size: 11)
                }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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
        .help(spokenTitle)
        .accessibilityLabel(spokenTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
