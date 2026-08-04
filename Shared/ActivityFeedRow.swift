#if os(macOS)
import AppKit
#endif
import SwiftUI

/// Affordance that a menubar / phone Activity row drills into a detail page.
/// Stays tertiary and compact — same vocabulary as a SwiftUI `NavigationLink`
/// disclosure — so it does not compete with the accent-tinted permalink.
struct ServiceDetailChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.body.weight(.semibold))
            .foregroundStyle(.tertiary)
            .imageScale(.small)
            .accessibilityHidden(true)
    }
}

/// One Activity feed row for every Apple surface — menubar Attention /
/// Activity, and the iPhone lists that share them.
///
/// Layout matches the service panels: leading mark, title + caption, trailing
/// age, disclosure chevron on the drill-in target, and a separate permalink
/// control so opening the source never fights the detail push.
struct ActivityFeedRow: View {
    let item: ActivityItem
    /// macOS menubar: set selection. iOS uses `NavigationLink` instead.
    var onSelect: (() -> Void)? = nil

    private var markSize: CGFloat {
        #if os(macOS)
        12
        #else
        16
        #endif
    }

    var body: some View {
        let style = ActivityStatusStyle.resolve(item.status)
        HStack(spacing: 8) {
            #if os(macOS)
            Button {
                onSelect?()
            } label: {
                rowLabel(style: style)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show event detail")
            .disabled(onSelect == nil)
            #else
            NavigationLink {
                ActivityItemDetail(item: item)
            } label: {
                rowLabel(style: style)
                    .padding(.vertical, 4)
            }
            #endif
            PermalinkButton(url: Permalink.activity(item))
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func rowLabel(style: ActivityStatusStyle) -> some View {
        let hasBrand = ProviderIcon.sourceID(forKind: item.kind) != nil
        #if os(macOS)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 8) {
                mark(style: style, hasBrand: hasBrand)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.subject ?? "Event")
                        .font(.subheadline.weight(
                            style.needsAttention ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(item.caption(label: style.label))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Text(item.ago ?? "—")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                ServiceDetailChevron()
            }
            if style.needsAttention, let error = item.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.leading, 20)
            }
        }
        #else
        // System NavigationLink already draws the disclosure chevron.
        HStack(alignment: .top, spacing: 10) {
            mark(style: style, hasBrand: hasBrand)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.subject ?? "Event")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text(item.caption(label: style.label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if style.needsAttention, let error = item.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            Text(item.ago ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        #endif
    }

    private func mark(style: ActivityStatusStyle, hasBrand: Bool) -> some View {
        ProviderMark.forKind(
            item.kind,
            size: markSize,
            fallbackSystemImage: style.symbol
        )
        .foregroundStyle(
            hasBrand
                ? AnyShapeStyle(.primary)
                : AnyShapeStyle(style.tint)
        )
        .frame(width: markSize)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}

/// Rollup reason as the same list chrome when no concrete feed row exists
/// (stale quota, sign-in, and similar). Permalink + chevron only when the
/// host gave something to open; otherwise it stays a plain row.
struct AttentionReasonRow: View {
    let reason: AttentionReason
    var permalink: URL? = nil
    /// macOS: drill-in or open. iOS: `NavigationLink` / openURL when set.
    var onSelect: (() -> Void)? = nil

    private var markSize: CGFloat {
        #if os(macOS)
        12
        #else
        16
        #endif
    }

    private var isTappable: Bool { onSelect != nil || permalink != nil }

    var body: some View {
        let hasBrand = ProviderIcon.sourceID(forKind: reason.kind) != nil
        HStack(spacing: 8) {
            #if os(macOS)
            Button {
                if let onSelect {
                    onSelect()
                } else if let permalink {
                    NSWorkspace.shared.open(permalink)
                }
            } label: {
                reasonLabel(hasBrand: hasBrand)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isTappable)
            .help(isTappable ? HeadroomCopy.openPermalink : "")
            #else
            if let onSelect {
                Button(action: onSelect) {
                    reasonLabel(hasBrand: hasBrand)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            } else if let permalink {
                Link(destination: permalink) {
                    reasonLabel(hasBrand: hasBrand)
                        .padding(.vertical, 4)
                }
            } else {
                reasonLabel(hasBrand: hasBrand)
                    .padding(.vertical, 4)
            }
            #endif
            PermalinkButton(url: permalink)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func reasonLabel(hasBrand: Bool) -> some View {
        HStack(alignment: .top, spacing: markSize == 12 ? 8 : 10) {
            ProviderMark.forKind(
                reason.kind,
                size: markSize,
                fallbackSystemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(
                hasBrand
                    ? AnyShapeStyle(.primary)
                    : AnyShapeStyle(HeadroomPalette.attention(reason.level))
            )
            .frame(width: markSize)
            .padding(.top, 2)
            Text(reason.summary ?? HeadroomCopy.needsAttention)
                #if os(macOS)
                .font(.subheadline)
                .lineLimit(2)
                #else
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                #endif
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isTappable {
                ServiceDetailChevron()
            }
        }
    }
}
