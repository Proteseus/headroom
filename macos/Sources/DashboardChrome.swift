import AppKit
import SwiftUI

/// Card chrome and small shared pieces every dashboard section draws with.
/// Kept in one place so a section file doesn't have to redefine padding,
/// corner radius, or the provider palette.

/// Tab ids: `overview` or a quota provider id from the host registry.
enum DashboardSelection {
    static let overview = "overview"

    static func title(for id: String, providers: [QuotaProviderInfo]) -> String {
        if id == overview { return HeadroomCopy.overview }
        if let match = providers.first(where: { $0.id == id }) {
            return match.displayTitle
        }
        return UsageProvider(rawValue: id)?.title ?? id.capitalized
    }

    /// Overview plus whatever quota providers are currently enabled.
    static func tabs(for providers: [QuotaProviderInfo]) -> [String] {
        [overview] + providers.map(\.id)
    }
}

/// Firmware `COL_*` palette — the only brand/status colors the Mac app paints with.
/// Host `accent` hexes and `UsageProvider.tint` must match these RGB triples.
enum HeadroomPalette {
    static let claude = rgb(217, 119, 87)   // COL_CLAUDE #D97757
    static let openai = rgb(16, 163, 127)   // COL_OPENAI #10A37F
    static let cursor = rgb(120, 155, 200)  // COL_CURSOR #789BC8
    static let vercel = rgb(240, 238, 234)  // COL_VERCEL
    static let git = rgb(155, 85, 200)      // COL_GIT
    static let local = rgb(70, 175, 165)    // COL_LOCAL
    static let dim = rgb(120, 116, 110)     // COL_DIM
    static let green = rgb(95, 155, 115)    // COL_GREEN
    static let amber = rgb(195, 155, 85)    // COL_AMBER
    static let red = rgb(175, 105, 100)     // COL_RED

    static let nsGreen = nsRGB(95, 155, 115)
    static let nsAmber = nsRGB(195, 155, 85)
    static let nsRed = nsRGB(175, 105, 100)

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Color {
        Color(red: r / 255, green: g / 255, blue: b / 255)
    }

    static func nsRGB(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    /// Parse host `#RRGGBB` / `RRGGBB` accents. Nil on garbage.
    static func color(hex: String?) -> Color? {
        guard let ns = nsColor(hex: hex) else { return nil }
        return Color(nsColor: ns)
    }

    static func nsColor(hex: String?) -> NSColor? {
        guard var raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF)
        let g = CGFloat((value >> 8) & 0xFF)
        let b = CGFloat(value & 0xFF)
        return nsRGB(r, g, b)
    }

    static func attention(_ level: String?) -> Color {
        switch level {
        case "critical": red
        case "warn": amber
        default: green
        }
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
    var tint: Color {
        switch self {
        case .claude: HeadroomPalette.claude
        case .codex: HeadroomPalette.openai
        case .cursor: HeadroomPalette.cursor
        }
    }
}

extension UsageSnapshot {
    /// Prefer the host registry accent; fall back to the firmware palette.
    func tint(for provider: UsageProvider) -> Color {
        tint(forProviderID: provider.rawValue)
    }

    func tint(forProviderID providerID: String) -> Color {
        if let hex = providers?.first(where: { $0.id == providerID })?.accent,
           let color = HeadroomPalette.color(hex: hex) {
            return color
        }
        return UsageProvider(rawValue: providerID)?.tint ?? HeadroomPalette.dim
    }
}

extension View {
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
