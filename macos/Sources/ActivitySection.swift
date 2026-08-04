import SwiftUI

/// The macOS half of the same split used by iOS: Activity is what happened,
/// while Attention owns failed rows and anything waiting for a person.
///
/// One chronological mixed feed — host order, provider marks on each row.
/// The popover mode is already titled Activity, so the section header is
/// "Recent" rather than repeating the mode name. Row tap drills into the
/// shared detail page (Open / Inspector live there).
struct ActivitySection: View {
    let items: [ActivityItem]
    @Binding var selection: ServiceDetailSelection?
    @AppStorage("activityRowLimit")
    private var activityRowLimit = 8

    var body: some View {
        let rows = Array(
            items
                .filter { !ActivityStatusStyle.resolve($0.status).needsAttention }
                .prefix(max(3, min(activityRowLimit, 24)))
        )
        if !rows.isEmpty {
            DataSection(title: HeadroomCopy.recentActivity) {
                ForEach(rows) { item in
                    ActivityFeedRow(item: item) {
                        selection = .activity(item.id)
                    }
                }
            }
        }
    }
}

/// Attention keeps the concrete failed rows reachable on the Mac, just as it
/// does on iOS. Rollup summaries expand into feed / source rows with the same
/// permalink + chevron chrome; leftover reasons (stale, sign-in) use the
/// shared reason row when there is still something to open.
struct AttentionSection: View {
    @ObservedObject var store: UsageStore
    @Binding var selection: ServiceDetailSelection?

    var body: some View {
        let failures = AttentionList.failures(in: store.snapshot)
        let reasons = AttentionList.leftoverReasons(in: store.snapshot)
        let warning = store.snapshot.attention?.isWarning == true
        let hasAttention = !failures.isEmpty || !reasons.isEmpty || warning
        let summary: String = {
            if !failures.isEmpty {
                return HeadroomCopy.needsAttention(count: failures.count)
            }
            if !reasons.isEmpty {
                return HeadroomCopy.needsAttention(count: reasons.count)
            }
            return store.snapshot.attention?.summary ?? HeadroomCopy.allClear
        }()

        DataSection(title: HeadroomCopy.attention) {
            HStack(spacing: 5) {
                Image(systemName: hasAttention
                      ? "exclamationmark.triangle.fill"
                      : "checkmark.circle")
                Text(summary)
                Spacer()
                if warning {
                    Button {
                        Task { await store.acknowledgeAttention() }
                    } label: {
                        Label(HeadroomCopy.clearAttention,
                              systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Clear this warning on every Headroom surface")
                    .accessibilityLabel(HeadroomCopy.clearAttention)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(
                hasAttention
                    ? AnyShapeStyle(attentionTint(store.snapshot.attention?.level))
                    : AnyShapeStyle(HeadroomPalette.green)
            )
            .padding(.horizontal, Metrics.rowInset)
            .accessibilityElement(children: .combine)

            ForEach(failures.prefix(8)) { failure in
                ActivityFeedRow(item: failure) {
                    selection = .activity(failure.id)
                }
            }
            ForEach(reasons) { reason in
                AttentionReasonRow(
                    reason: reason,
                    permalink: AttentionList.permalink(
                        for: reason, in: store.snapshot)
                )
            }
        }
    }

    private enum Metrics {
        static let rowInset: CGFloat = 7
    }
}
