import AppKit
import SwiftUI

/// The macOS half of the same split used by iOS: Activity is what happened,
/// while Attention owns failed rows and anything waiting for a person.
///
/// The popover mode is already titled Activity, so groups draw as their own
/// sections (Git commits, Vercel deployments, …) rather than nesting under a
/// second "Activity" header.
struct ActivitySection: View {
    let items: [ActivityItem]
    @AppStorage("activityRowLimit")
    private var activityRowLimit = 8

    var body: some View {
        let rows = Array(
            items
                .filter { !ActivityStatusStyle.resolve($0.status).needsAttention }
                .prefix(max(3, min(activityRowLimit, 14)))
        )
        ForEach(ActivityGrouping.groups(from: rows)) { group in
            DataSection(title: group.title) {
                ForEach(group.rows) { item in
                    MacActivityRow(item: item)
                }
            }
        }
    }
}

/// Attention keeps the concrete failed rows reachable on the Mac, just as it
/// does on iOS. When the host has only a rollup, show its reasons instead.
struct AttentionSection: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let failures = (store.snapshot.activity ?? []).filter {
            ActivityStatusStyle.resolve($0.status).needsAttention
        }
        let reasons = store.snapshot.attention?.reasons ?? []
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

            if failures.isEmpty {
                ForEach(reasons) { reason in
                    let hasBrand = ProviderIcon.sourceID(forKind: reason.kind) != nil
                    HStack(alignment: .top, spacing: 8) {
                        ProviderMark.forKind(
                            reason.kind,
                            size: 12,
                            fallbackSystemImage: "exclamationmark.triangle.fill"
                        )
                        // Services have no brand colour — keep the mark
                        // monochrome; only the fallback triangle takes level tint.
                        .foregroundStyle(
                            hasBrand
                                ? AnyShapeStyle(.primary)
                                : AnyShapeStyle(attentionTint(reason.level))
                        )
                        .frame(width: 12)
                        .padding(.top, 2)
                        Text(reason.summary ?? HeadroomCopy.needsAttention)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, Metrics.rowInset)
                }
            } else {
                ForEach(failures.prefix(8)) { failure in
                    MacActivityRow(item: failure)
                }
            }
        }
    }

    private enum Metrics {
        static let rowInset: CGFloat = 7
    }
}

/// Compact menubar rendering for one activity row. The status vocabulary and
/// caption order match iOS; only the density and browser action are platform
/// specific.
struct MacActivityRow: View {
    let item: ActivityItem

    var body: some View {
        let style = ActivityStatusStyle.resolve(item.status)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 8) {
                let hasBrand = ProviderIcon.sourceID(forKind: item.kind) != nil
                ProviderMark.forKind(
                    item.kind,
                    size: 12,
                    fallbackSystemImage: style.symbol
                )
                .foregroundStyle(
                    hasBrand
                        ? AnyShapeStyle(.primary)
                        : AnyShapeStyle(style.tint)
                )
                .frame(width: 12)
                .padding(.top, 2)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.subject ?? "Event")
                        .font(.subheadline.weight(
                            style.needsAttention ? .semibold : .regular))
                        .lineLimit(1)
                    // Secondary only — status is the word in the caption,
                    // not a tint. Services have no colour to paint with.
                    Text(caption(style))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(item.ago ?? "—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            if style.needsAttention, let error = item.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            if let url { NSWorkspace.shared.open(url) }
        }
        .help(url != nil ? "Open in browser" : "")
        .accessibilityElement(children: .combine)
    }

    private func caption(_ style: ActivityStatusStyle) -> String {
        item.caption(label: style.label)
    }

    private var url: URL? {
        let raw = item.inspectorURL ?? item.url
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }
}
