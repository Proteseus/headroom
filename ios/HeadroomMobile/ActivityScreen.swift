import SwiftUI

/// What the Mac has been doing, and what it is running: the merged deploy /
/// commit / Actions feed above the service panels that used to be a tab of
/// their own.
///
/// Nothing on this screen is waiting for an answer. Rows that failed live on
/// `AttentionScreen`, which is also the one place that decides which those are
/// — this screen takes the complement, so the two can't disagree.
struct ActivityScreen: View {
    @ObservedObject var store: MobileUsageStore
    @State private var serverToStop: LocalServer?
    @State private var controlError: String?

    var body: some View {
        let rows = (store.snapshot.activity ?? []).filter {
            !ActivityStatusStyle.resolve($0.status).needsAttention
        }
        List {
            ArchivedDataNotice(store: store)
            if rows.isEmpty {
                PageEmptyState(
                    systemImage: "list.bullet.rectangle.fill",
                    title: HeadroomCopy.noActivityYet
                )
                .frame(minHeight: 220)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
            } else {
                ForEach(ActivityGrouping.groups(from: rows)) { group in
                    Section(group.title) {
                        ForEach(group.rows) { ActivityRow(item: $0) }
                    }
                }
            }
            ServiceSections(store: store) { serverToStop = $0 }
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

/// One feed row, drawn the same on both tabs. Status vocabulary comes from
/// `Shared/ActivityStatus.swift` so the phone and the Mac card can't drift
/// into different ideas of green.
struct ActivityRow: View {
    let item: ActivityItem

    var body: some View {
        let style = ActivityStatusStyle.resolve(item.status)
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
    }
}
