import SwiftUI

/// The queue: everything that is waiting on a person. Coding agents that asked
/// a question, the rollup's own reasons, and the feed rows that failed.
///
/// Anything that merely happened is one tab over on `ActivityScreen`. That
/// split is the whole point of this screen — a build that went green and a
/// permission request that is blocking a session were the same list until now,
/// and the list was sorted by which arrived last.
struct AttentionScreen: View {
    @ObservedObject var store: MobileUsageStore

    var body: some View {
        let failures = AttentionScreen.failures(in: store.snapshot)
        let reasons = store.snapshot.attention?.reasons ?? []
        let events = store.agentAttentionEvents
        List {
            ArchivedDataNotice(store: store)
            if events.isEmpty, reasons.isEmpty, failures.isEmpty {
                Label(HeadroomCopy.allClear, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(HeadroomPalette.green)
            }
            if !events.isEmpty {
                Section(HeadroomCopy.answerCodingAgents) {
                    ForEach(events) { event in
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
            if !reasons.isEmpty {
                Section {
                    ForEach(reasons) { reason in
                        HStack(alignment: .top, spacing: 9) {
                            Circle()
                                .fill(HeadroomPalette.attention(reason.level))
                                .frame(width: 7, height: 7)
                                .padding(.top, 6)
                            Text(reason.summary ?? HeadroomCopy.needsAttention)
                                .font(.subheadline)
                        }
                    }
                } header: {
                    HStack {
                        Text(HeadroomCopy.attention)
                        Spacer()
                        if store.snapshot.attention?.isWarning == true {
                            Button(HeadroomCopy.clearAttention) {
                                Task { await store.acknowledgeAttention() }
                            }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                        }
                    }
                }
            }
            if !failures.isEmpty {
                Section {
                    ForEach(failures) { ActivityRow(item: $0) }
                } header: {
                    Label(
                        HeadroomCopy.needsAttention(count: failures.count),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(HeadroomPalette.red)
                }
            }
            // Giving an agent work is not something waiting on you, so it sits
            // under the queue rather than above it — but it stays on the
            // agents' own screen, where the answer buttons already are.
            if store.mobilePermissions.agents, let surface = store.agentTaskSurface {
                Section(HeadroomCopy.startTask) {
                    StartAgentTaskView(
                        surface: surface,
                        tint: { id in
                            (store.snapshot.providers ?? [])
                                .accentTint(forProvider: id)
                        },
                        start: { provider, cwd, prompt in
                            await store.startTask(
                                provider: provider, cwd: cwd, prompt: prompt)
                        }
                    )
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle(HeadroomCopy.attention)
        .refreshable { await store.refresh(forceServerSync: true) }
        .task { await store.loadTaskSurface() }
    }

    /// The feed rows this screen claims off `ActivityScreen`. One definition,
    /// read by both tabs and by the tab bar's badge, so a row can never be on
    /// both screens or on neither.
    /// `nonisolated` because it is a rule about data, not about a view: the
    /// tab bar's badge and the tests both ask it off the main actor.
    nonisolated static func failures(in snapshot: UsageSnapshot) -> [ActivityItem] {
        (snapshot.activity ?? []).filter {
            ActivityStatusStyle.resolve($0.status).needsAttention
        }
    }

    private func agentRow(_ event: AgentAttentionEvent) -> some View {
        let tint = (store.snapshot.providers ?? [])
            .accentTint(forProvider: event.providerIconID)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(event.title)
                    .font(.headline)
                Spacer(minLength: 6)
                // Same treatment as an activity row's age, so the two halves
                // of one feed read as one feed.
                Text(HeadroomCopy.ago(event.age))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                // The mark rides in the corner rather than in front of the
                // title: which agent asked is a property of the row, not the
                // first thing to read in the sentence.
                ProviderMark(providerID: event.providerIconID, size: 14)
                    .foregroundStyle(tint)
                    .alignmentGuide(.firstTextBaseline) { $0.height - 2 }
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
            if event.detail.answerOnMac == true {
                Label(HeadroomCopy.answerInTheTerminal,
                      systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Wraps: three options no longer run off the edge of the row.
            FlowingActions(
                actions: event.actions,
                tint: tint,
                disabled: !store.mobilePermissions.agents
                    || store.respondingAgentEventID != nil,
                responding: store.respondingAgentEventID == event.id
            ) { action, text in
                Task { await store.answer(event, with: action, text: text) }
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
}
