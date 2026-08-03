import SwiftUI

/// What the Mac has been doing: one chronological mixed feed (commits,
/// Actions, deploys, resets) plus service panels and local servers/builds
/// in Integrations catalog order. Failed rows live on Attention — this
/// screen takes the complement.
struct ActivityScreen: View {
    @ObservedObject var store: MobileUsageStore
    @State private var serverToStop: LocalServer?
    @State private var controlError: String?

    var body: some View {
        List {
            ArchivedDataNotice(store: store)
            ServiceSections(store: store) { serverToStop = $0 }
            if !hasAnyActivityBlock {
                PageEmptyState(
                    systemImage: "list.bullet.rectangle.fill",
                    title: HeadroomCopy.noActivityYet
                )
                .frame(minHeight: 220)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(HeadroomCopy.activity)
        .refreshable { await store.refresh(forceServerSync: true) }
        .confirmationDialog(
            "Stop \(serverToStop?.name ?? "server")?",
            isPresented: Binding(
                get: { serverToStop != nil },
                set: { if !$0 { serverToStop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop server", role: .destructive) {
                guard let server = serverToStop else { return }
                serverToStop = nil
                Task { await authenticateAndStop(server) }
            }
            Button("Cancel", role: .cancel) { serverToStop = nil }
        } message: {
            Text("Stops the process on your Mac.")
        }
        .alert(
            "Couldn’t complete action",
            isPresented: Binding(
                get: { controlError != nil },
                set: { if !$0 { controlError = nil } }
            )
        ) {
            Button("OK") { controlError = nil }
        } message: {
            Text(controlError ?? "")
        }
    }

    /// True when any catalog block would paint something — used only for the
    /// empty state when every section is quiet.
    private var hasAnyActivityBlock: Bool {
        let snap = store.snapshot
        let feed = (snap.activity ?? []).filter {
            !ActivityStatusStyle.resolve($0.status).needsAttention
        }
        if !feed.isEmpty { return true }
        for watch in IntegrationWatch.activityBlocks(
            from: snap.integrationsOrder ?? snap.servicesOrder
        ) {
            switch watch {
            case .git, .github, .vercel, .sentry, .datadog, .axiom:
                continue
            case .supabase:
                if snap.supabase?.configured == true { return true }
            case .plausible:
                if snap.plausible?.configured == true { return true }
            case .posthog:
                if snap.posthog?.configured == true { return true }
            case .servers:
                return true
            case .builds:
                if !(snap.local?.builds ?? []).isEmpty { return true }
            case .openrouter, .aiGateway:
                continue
            }
        }
        return false
    }

    @MainActor
    private func authenticateAndStop(_ server: LocalServer) async {
        do {
            try await MobileControlAuthorizer.authorize(
                reason: "Stop \(server.name ?? "this server") on your Mac"
            )
            await store.stopServer(server)
        } catch {
            controlError = error.localizedDescription
        }
    }
}

/// One feed row, drawn the same on Activity and Attention. Status vocabulary
/// comes from `Shared/ActivityStatus.swift` so the phone and the Mac card
/// can't drift into different ideas of green.
struct ActivityRow: View {
    let item: ActivityItem

    var body: some View {
        let style = ActivityStatusStyle.resolve(item.status)
        HStack(spacing: 8) {
            NavigationLink {
                ActivityItemDetail(item: item)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    // Brand marks stay monochrome — only AI providers own a
                    // colour. Status tint paints the fallback glyph alone.
                    let hasBrand = ProviderIcon.sourceID(forKind: item.kind) != nil
                    ProviderMark.forKind(
                        item.kind,
                        size: 16,
                        fallbackSystemImage: style.symbol
                    )
                    .foregroundStyle(
                        hasBrand
                            ? AnyShapeStyle(.primary)
                            : AnyShapeStyle(style.tint)
                    )
                    .frame(width: 16)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.subject ?? "Event")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        // Caption stays secondary — the word ("Failed", "Review")
                        // carries the state. Tinting it painted service rows in
                        // status colour, and services don't own a colour.
                        Text(item.caption(label: style.label))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if style.needsAttention, let error = item.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(item.ago ?? "")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
            PermalinkButton(url: Permalink.activity(item))
        }
    }
}
