import SwiftUI

/// Card chrome and small shared pieces every dashboard section draws with.
/// Kept in one place so a section file doesn't have to redefine padding,
/// corner radius, or the provider palette.

enum DashboardSelection: String, CaseIterable {
    case overview
    case claude
    case codex
    case cursor

    var title: String {
        switch self {
        case .overview: "Overview"
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }

    var provider: UsageProvider? {
        UsageProvider(rawValue: rawValue)
    }
}

extension UsageProvider {
    var tint: Color {
        switch self {
        case .claude: Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
        case .codex: Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
        case .cursor: Color(red: 0 / 255, green: 191 / 255, blue: 165 / 255)
        }
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

struct GlanceStat: View {
    let value: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }
}

func attentionTint(_ level: String?) -> Color {
    switch level {
    case "critical": .red
    case "warn": .orange
    default: .green
    }
}
