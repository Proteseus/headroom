import SwiftUI

/// The phone's copy of the merged feed. Same reading order as the Mac card:
/// what is broken, under a count, above everything that merely happened —
/// with the status vocabulary coming from `Shared/ActivityStatus.swift` so the
/// two surfaces can't drift into different ideas of green.
struct ActivityScreen: View {
    @ObservedObject var store: MobileUsageStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        let rows = store.snapshot.activity ?? []
        let attention = rows.filter {
            ActivityStatusStyle.resolve($0.status).needsAttention
        }
        let routine = rows.filter {
            !ActivityStatusStyle.resolve($0.status).needsAttention
        }
        List {
            ArchivedDataNotice(store: store)
            if !store.agentAttentionEvents.isEmpty {
                Section(HeadroomCopy.answerCodingAgents) {
                    ForEach(store.agentAttentionEvents) { event in
                        agentRow(event)
                            // Only rows whose sole answer is "dismiss" can be
                            // swiped. A swipe that denied a permission would
                            // send Claude a real answer by accident.
                            .swipeActions(edge: .trailing) {
                                if event.isDismissOnly,
                                   let dismiss = event.actions.first {
                                    Button(dismiss.label) {
                                        Task {
                                            await store.answer(
                                                event, with: dismiss)
                                        }
                                    }
                                    .tint(HeadroomPalette.dim)
                                }
                            }
                    }
                }
            }
            // One list, failures first, uniform rows — same reading order as
            // the Mac card. Splitting it into sections put a gap in the middle
            // of what is really one timeline.
            if !rows.isEmpty {
                Section {
                    ForEach(attention + routine) { row($0) }
                } header: {
                    if attention.isEmpty {
                        Label(HeadroomCopy.allClear, systemImage: "checkmark.circle")
                            .foregroundStyle(HeadroomPalette.green)
                    } else {
                        Label(
                            HeadroomCopy.needsAttention(count: attention.count),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(HeadroomPalette.red)
                    }
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView(
                    HeadroomCopy.noActivityYet,
                    systemImage: "bolt.horizontal.circle"
                )
            }
        }
        .navigationTitle(HeadroomCopy.activity)
        .refreshable { await store.refresh(forceServerSync: true) }
    }

    private func agentRow(_ event: AgentAttentionEvent) -> some View {
        let tint = (store.snapshot.providers ?? [])
            .accentTint(forProvider: event.providerIconID)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // The mark says which agent is asking before the words do.
                // A generic speech bubble made a Claude row and a Codex row
                // look like the same thing.
                ProviderMark(providerID: event.providerIconID, size: 15)
                    .foregroundStyle(tint)
                Text(event.title)
                    .font(.headline)
                Spacer(minLength: 6)
                // Same treatment as an activity row's age, so the two halves
                // of one feed read as one feed.
                Text(HeadroomCopy.ago(event.age))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(event.summary)
                .font(.subheadline)
            if let reasons = event.detail.reasons, !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(HeadroomCopy.agentWhyAsking)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(reasons, id: \.self) { reason in
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(HeadroomPalette.amber)
                    }
                }
            }
            AgentRequestView(fields: event.detail.requestFields)
            // Wraps: three options no longer run off the edge of the row.
            FlowingActions(
                actions: event.actions,
                tint: tint,
                disabled: !store.mobilePermissions.agents
                    || store.respondingAgentEventID != nil,
                responding: store.respondingAgentEventID == event.id
            ) { action in
                Task { await store.answer(event, with: action) }
            }
            if event.actions.contains(where: { $0.id == "approve_always" }),
               let rule = event.detail.permissionRule {
                VStack(alignment: .leading, spacing: 1) {
                    Text(HeadroomCopy.agentWouldSaveRule)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(rule)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func row(_ item: ActivityItem) -> some View {
        let style = ActivityStatusStyle.resolve(item.status)
        Button {
            open(item)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.symbol)
                    .font(.footnote)
                    .foregroundStyle(style.tint)
                    .frame(width: 16)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.subject ?? "Event")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(caption(item, style))
                        .font(.caption)
                        .foregroundStyle(style.needsAttention
                                         ? AnyShapeStyle(style.tint)
                                         : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                    if style.needsAttention, let error = item.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(HeadroomPalette.red)
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
        .buttonStyle(.plain)
        .disabled(url(item) == nil)
    }

    /// "Failed · headroom · Release · main · 1901f54" — state first, then the
    /// coordinates. Matches the Mac card word for word.
    private func caption(_ item: ActivityItem, _ style: ActivityStatusStyle) -> String {
        var parts = [style.label]
        let repo = leafName(item.repo)
        if let repo { parts.append(repo) }
        if let project = item.project, project != repo { parts.append(project) }
        if let branch = item.branch { parts.append(branch) }
        if let sha = item.shortSHA { parts.append(sha) }
        if item.status == "ready" {
            parts.append(item.target == "production" ? "prod" : "preview")
        }
        return parts.joined(separator: " · ")
    }

    /// `owner/name` → `name`. The owner is the same on every row here.
    private func leafName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.split(separator: "/").last.map(String.init)
    }

    private func url(_ item: ActivityItem) -> URL? {
        guard let raw = item.inspectorURL ?? item.url, !raw.isEmpty else { return nil }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }

    private func open(_ item: ActivityItem) {
        if let target = url(item) {
            openURL(target)
        }
    }
}
