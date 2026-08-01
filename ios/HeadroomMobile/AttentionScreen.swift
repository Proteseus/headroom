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
    @Binding var focusedEventID: String?
    @Binding var showsSettings: Bool
    @State private var showsStartTask = false

    var body: some View {
        // Both halves of the queue are the store's to decide: dismissing a row
        // has to drop it from the tab badge as well as from this list.
        let failures = store.attentionFailures
        let reasons = store.attentionReasons
        let hasNeedsAttention = !reasons.isEmpty || !failures.isEmpty
        // Agent-originated state is attention even when the answer is simply
        // "I saw this". A finished turn is useful context for the person
        // coordinating several sessions, so it stays here until dismissed.
        let events = store.agentAttentionEvents
        let dismissibleEvents = events.filter(\.isDismissOnly)
        ScrollViewReader { proxy in
            List {
                ArchivedDataNotice(store: store)
                if events.isEmpty, !hasNeedsAttention {
                    Label(HeadroomCopy.allClear, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(HeadroomPalette.green)
                }
                if !events.isEmpty {
                    Section {
                        ForEach(events) { event in
                            agentRow(event)
                                .id(event.id)
                                .swipeActions(
                                    edge: .trailing,
                                    allowsFullSwipe: true
                                ) {
                                    if event.isDismissOnly,
                                       store.mobilePermissions.agents,
                                       let dismiss = event.actions.first(
                                           where: { $0.id == "dismiss" }
                                       ) {
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
                    } header: {
                        HStack {
                            Text(HeadroomCopy.codingAgents)
                            Spacer()
                            if !dismissibleEvents.isEmpty,
                               store.mobilePermissions.agents {
                                Button(HeadroomCopy.dismissAll) {
                                    Task {
                                        await store.dismissAllAgentNotices()
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                            }
                        }
                    }
                }
                if hasNeedsAttention {
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
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(HeadroomCopy.dismiss) {
                                    store.dismissAttention(id: reason.id)
                                }
                                .tint(HeadroomPalette.dim)
                            }
                        }
                        ForEach(failures) { failure in
                            ActivityRow(item: failure, showsCaption: false)
                                .swipeActions(
                                    edge: .trailing,
                                    allowsFullSwipe: true
                                ) {
                                    Button(HeadroomCopy.dismiss) {
                                        store.dismissAttention(id: failure.id)
                                    }
                                    .tint(HeadroomPalette.dim)
                                }
                        }
                    } header: {
                        // Plain, like Coding agents above it. The count and the
                        // alarm colour were saying what the rows already say,
                        // and moved with every poll.
                        HStack {
                            Text(HeadroomCopy.needsAttention)
                            Spacer()
                            Button(HeadroomCopy.dismissAll) {
                                Task { await store.dismissAllAttention() }
                            }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                        }
                    }
                }
            }
            .onChange(of: focusedEventID) { _, eventID in
                focus(eventID, using: proxy)
            }
            .onChange(of: store.agentAttentionEvents) { _, _ in
                // The notification route refreshes before assigning focus,
                // but this also handles a slow Mac response safely.
                focus(focusedEventID, using: proxy)
            }
            .task {
                focus(focusedEventID, using: proxy)
            }
        }
        .navigationTitle(HeadroomCopy.attention)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(HeadroomCopy.settings, systemImage: "gearshape") {
                    showsSettings = true
                }
                .labelStyle(.iconOnly)
            }
            if store.mobilePermissions.agents, store.agentTaskSurface != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(HeadroomCopy.startTask, systemImage: "plus") {
                        showsStartTask = true
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .sheet(isPresented: $showsStartTask) {
            NavigationStack {
                Group {
                    if let surface = store.agentTaskSurface {
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
                        .padding()
                    } else {
                        ProgressView()
                    }
                }
                .navigationTitle(HeadroomCopy.startTask)
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
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
        let isQuestion = event.kind == "structured_question"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(event.displayTitle)
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
            if let machineName = event.machineName, !machineName.isEmpty {
                Label(machineName, systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // A question is already represented by its prompt plus option
            // buttons. Showing the provider's raw request underneath repeats
            // the same information and makes the row feel like a debug dump.
            if isQuestion || event.isDismissOnly {
                Text(event.summary)
                    .font(.subheadline)
            }
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
            if !isQuestion {
                AgentRequestView(fields: event.detail.requestFields)
            }
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
        // Keep agent events as ordinary rows in the grouped List. The
        // section supplies the single white rounded container and the system
        // supplies dividers between events, matching the Needs attention rows.
        .listRowBackground(
            focusedEventID == event.id
                ? tint.opacity(0.16)
                : Color(.systemBackground)
        )
        .padding(.vertical, 4)
    }

    private func focus(_ eventID: String?, using proxy: ScrollViewProxy) {
        guard let eventID,
              store.agentAttentionEvents.contains(where: { $0.id == eventID })
        else { return }
        withAnimation {
            proxy.scrollTo(eventID, anchor: .center)
        }
    }
}
