import SwiftUI

/// Full trailing-window visitor histogram — OpenRouter day-chart shape,
/// visitors instead of dollars. Used on Plausible site detail.
struct PlausibleTrafficChart: View {
    let days: [PlausibleTrafficDay]
    var title: String
    var tint: Color = HeadroomPalette.dim

    var body: some View {
        let peak = max(days.compactMap(\.visitors).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days) { day in
                    let count = day.visitors ?? 0
                    let height = CGFloat(count) / CGFloat(peak)
                    Capsule()
                        .fill(tint.opacity(count > 0 ? 0.9 : 0.12))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, 72 * height))
                        .accessibilityLabel(day.day ?? "bucket")
                        .accessibilityValue(HeadroomFormat.compact(count))
                }
            }
            .frame(height: 72)
            if let first = days.first?.day, let last = days.last?.day {
                HStack {
                    Text(shortLabel(first))
                    Spacer()
                    Text(shortLabel(last))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
        }
    }

    private func shortLabel(_ raw: String) -> String {
        // YYYY-MM-DD → M/D; hourly "YYYY-MM-DD HH" → H:00
        let parts = raw.split(separator: " ")
        if parts.count >= 2, let hour = Int(parts[1].prefix(2)) {
            return "\(hour):00"
        }
        let dayParts = raw.prefix(10).split(separator: "-")
        guard dayParts.count == 3,
              let month = Int(dayParts[1]),
              let day = Int(dayParts[2])
        else { return raw }
        return "\(month)/\(day)"
    }
}

/// Compact sparkline for each Plausible site row in the menubar list.
struct PlausibleTrafficSparkline: View {
    let days: [PlausibleTrafficDay]
    var tint: Color = HeadroomPalette.dim
    var width: CGFloat = 56
    var height: CGFloat = 28

    var body: some View {
        // Hourly windows stay whole; longer day series trim to the recent
        // strip the row can actually resolve (same idea as OpenRouter's 14).
        let recent = days.count > 24 ? Array(days.suffix(14)) : days
        let peak = max(recent.compactMap(\.visitors).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 1) {
            ForEach(recent) { day in
                let count = day.visitors ?? 0
                let barHeight = CGFloat(count) / CGFloat(peak)
                Capsule()
                    .fill(tint.opacity(count > 0 ? 0.9 : 0.15))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, height * barHeight))
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}
