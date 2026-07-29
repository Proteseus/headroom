import AppKit
import SwiftUI

/// Merged deploy / commit / Actions timeline. Pure function of the snapshot —
/// no state of its own.
///
/// Two questions, in that order: is anything broken, and what happened. The
/// count answers the first above the rows; failures then sort to the top and
/// carry their own tint. Every row is the same unit — same insets, same
/// rhythm, text on one left edge — so the feed reads as a list rather than a
/// box of urgent things stacked on a list. Status is carried by glyph, word,
/// and colour together (`Shared/ActivityStatus.swift`) rather than by a
/// coloured dot alone, which used to be the only difference between a failed
/// release and a push.
struct ActivitySection: View {
    let items: [ActivityItem]
    @AppStorage("activityRowLimit")
    private var activityRowLimit = 8

    var body: some View {
        let rows = Array(items.prefix(max(3, min(activityRowLimit, 14))))
        if !rows.isEmpty {
            let attention = rows.filter {
                ActivityStatusStyle.resolve($0.status).needsAttention
            }
            let routine = rows.filter {
                !ActivityStatusStyle.resolve($0.status).needsAttention
            }
            DataSection(title: HeadroomCopy.activity) {
                summary(failing: attention.count)
                ForEach(attention + routine) { row($0) }
            }
        }
    }

    /// The card's headline reading: red count, or the green word for none.
    /// Without it "nothing is wrong" is only ever implied by the absence of a
    /// colour, which is not a thing you can see at a glance.
    private func summary(failing: Int) -> some View {
        let clear = failing == 0
        return HStack(spacing: 5) {
            Image(systemName: clear
                  ? "checkmark.circle"
                  : "exclamationmark.triangle.fill")
            Text(clear
                 ? HeadroomCopy.allClear
                 : HeadroomCopy.needsAttention(count: failing))
            Spacer()
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(clear ? HeadroomPalette.green : HeadroomPalette.red)
        // Same inset as the rows, so the card has one left edge under its title.
        .padding(.horizontal, Metrics.rowInset)
        .accessibilityElement(children: .combine)
    }

    private enum Metrics {
        static let rowInset: CGFloat = 7
        static let rowPadding: CGFloat = 4
        static let rowCorner: CGFloat = 7
    }

    @ViewBuilder
    private func row(_ item: ActivityItem) -> some View {
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
                    Text(caption(item, style))
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
                if url(item) != nil {
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            // Only a real build error earns a second line; the host stopped
            // repeating repo and status here now that the caption carries both.
            if style.needsAttention, let error = item.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.red)
                    .lineLimit(2)
                    .padding(.leading, 20)
            }
        }
        // Identical insets on every row, failing or not — the tint is the only
        // thing that changes, so nothing shifts sideways between them.
        .padding(.vertical, Metrics.rowPadding)
        .padding(.horizontal, Metrics.rowInset)
        .background(
            style.needsAttention ? HeadroomPalette.red.opacity(0.09) : .clear,
            in: RoundedRectangle(cornerRadius: Metrics.rowCorner)
        )
        .contentShape(Rectangle())
        .onTapGesture { open(item) }
        .help(url(item) != nil ? "Open in browser" : "")
        .accessibilityElement(children: .combine)
    }

    /// "Failed · headroom · Release · main · 1901f54" — the state first,
    /// because that is the word being scanned for, then enough coordinates to
    /// know where to look. Actions rows used to omit the repo entirely, which
    /// left four red workflows indistinguishable from each other.
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
        let raw = item.inspectorURL ?? item.url
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw.contains("://") ? raw : "https://\(raw)")
    }

    private func open(_ item: ActivityItem) {
        guard let target = url(item) else { return }
        NSWorkspace.shared.open(target)
    }
}
