import AppKit
import SwiftUI

/// The macOS half of the same split used by iOS: Activity is what happened,
/// while Attention owns failed rows and anything waiting for a person.
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
        if !rows.isEmpty {
            DataSection(title: HeadroomCopy.activity) {
                ForEach(ActivityGrouping.groups(from: rows)) { group in
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Metrics.rowInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(group.rows) { item in
                        MacActivityRow(item: item)
                    }
                }
            }
        }
    }

    private enum Metrics {
        static let rowInset: CGFloat = 7
        static let rowPadding: CGFloat = 4
        static let rowCorner: CGFloat = 7
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
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(attentionTint(reason.level))
                            .frame(width: 7, height: 7)
                            .padding(.top, 4)
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
                Image(systemName: style.symbol)
                    .font(.caption)
                    .foregroundStyle(style.tint)
                    .frame(width: 12)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.subject ?? "Event")
                        .font(.subheadline.weight(
                            style.needsAttention ? .semibold : .regular))
                        .lineLimit(1)
                    Text(caption(style))
                        .font(.caption)
                        .foregroundStyle(style.needsAttention
                                         ? AnyShapeStyle(style.tint)
                                         : AnyShapeStyle(.secondary))
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
                    .foregroundStyle(HeadroomPalette.red)
                    .lineLimit(2)
                    .padding(.leading, 20)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .background(
            style.needsAttention ? HeadroomPalette.red.opacity(0.09) : .clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let url { NSWorkspace.shared.open(url) }
        }
        .help(url != nil ? "Open in browser" : "")
        .accessibilityElement(children: .combine)
    }

    private func caption(_ style: ActivityStatusStyle) -> String {
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

    private func leafName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.split(separator: "/").last.map(String.init)
    }

    private var url: URL? {
        let raw = item.inspectorURL ?? item.url
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }
}
