import AppKit
import SwiftUI

/// Card chrome and small shared pieces every dashboard section draws with.
/// Kept in one place so a section file doesn't have to redefine padding,
/// corner radius, or the provider palette.

/// Tab ids: `overview` or a quota provider id from the host registry.
enum DashboardSelection {
    static let overview = "overview"

    /// Full name for accessibility / help — "Claude · Work".
    static func title(for id: String, providers: [QuotaProviderInfo]) -> String {
        if id == overview { return HeadroomCopy.overview }
        if let match = providers.first(where: { $0.id == id }) {
            return match.displayTitle
        }
        return UsageProvider(rawValue: id)?.title ?? id.capitalized
    }

    /// Label drawn next to the brand mark in the switcher — account name when
    /// the row is a named login, otherwise the provider title.
    static func markTitle(for id: String, providers: [QuotaProviderInfo]) -> String {
        if id == overview { return HeadroomCopy.overview }
        if let match = providers.first(where: { $0.id == id }) {
            return match.markTitle
        }
        return title(for: id, providers: providers)
    }

    /// Overview plus whatever quota providers are currently enabled.
    static func tabs(for providers: [QuotaProviderInfo]) -> [String] {
        [overview] + providers.map(\.id)
    }
}

/// AppKit half of the shared palette in `Shared/HeadroomPalette.swift`. The
/// status item draws with `NSColor`, so the same RGB triples get a second
/// spelling here — and only here.
extension HeadroomPalette {
    static let nsGreen = nsRGB(95, 155, 115)
    static let nsAmber = nsRGB(195, 155, 85)
    static let nsRed = nsRGB(175, 105, 100)

    static func nsRGB(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static func nsColor(hex: String?) -> NSColor? {
        guard let parts = components(hex: hex) else { return nil }
        return nsRGB(parts.r, parts.g, parts.b)
    }

    static func nsAttention(_ level: String?) -> NSColor {
        switch level {
        case "critical": nsRed
        case "warn": nsAmber
        default: nsGreen
        }
    }
}

extension UsageProvider {
    /// Fallback when the host omitted `accent` — same RGB as firmware COL_*.
    var tint: Color { HeadroomPalette.providerTint(id: rawValue) }
}

extension UsageSnapshot {
    /// Prefer the host registry accent; fall back to the firmware palette.
    func tint(for provider: UsageProvider) -> Color {
        tint(forProviderID: provider.rawValue)
    }

    func tint(forProviderID providerID: String) -> Color {
        HeadroomPalette.providerTint(
            id: providerID,
            accent: providers?.first(where: { $0.id == providerID })?.accent
        )
    }
}

extension View {
    /// Report this view's laid-out width into `width`, for the few places that
    /// size their own content against it. The popover is a fixed 390 wide and
    /// nothing inside it may exceed that — a child that does overflows both
    /// edges rather than clipping, dragging every other card off-centre.
    ///
    /// Safe to read back into the same subtree only where the width does not
    /// depend on the value: a row of equal, width-filling cells, not
    /// content-sized ones.
    func measuredWidth(_ width: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, measured in
                        if abs(measured - width.wrappedValue) > 0.5 {
                            width.wrappedValue = measured
                        }
                    }
            }
        }
    }

    func cardStyle() -> some View {
        padding(14)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.primary.opacity(0.07))
            }
    }
}

struct DataSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            VStack(spacing: 10) {
                content
            }
        }
        .cardStyle()
    }
}

func attentionTint(_ level: String?) -> Color {
    HeadroomPalette.attention(level)
}
