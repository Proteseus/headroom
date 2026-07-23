import AppKit
import SwiftUI

struct DailyBurnCard: View {
    let days: [DailyBurnDay]

    private var visibleDays: [DailyBurnDay] {
        Array(days.suffix(7))
    }

    private var maxTotal: Double {
        max(visibleDays.map { $0.total ?? 0 }.max() ?? 0, 1)
    }

    private var todayTotal: Double {
        visibleDays.last?.total ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily burn")
                    .font(.headline)
                Spacer()
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if visibleDays.isEmpty {
                Text("Burn history starts after the next quota refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(visibleDays) { day in
                        DailyBurnBar(day: day, maxTotal: maxTotal)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 108)

                HStack(spacing: 12) {
                    ForEach(UsageProvider.allCases, id: \.rawValue) { provider in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(providerColor(provider))
                                .frame(width: 8, height: 8)
                            Text(provider.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.primary.opacity(0.07))
        }
    }

    private var subtitle: String {
        if todayTotal > 0 {
            let rounded = (todayTotal * 10).rounded() / 10
            if rounded == rounded.rounded() {
                return "Today \(Int(rounded))%"
            }
            return "Today \(rounded)%"
        }
        return "Quota points / day"
    }
}

private struct DailyBurnBar: View {
    let day: DailyBurnDay
    let maxTotal: Double

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let height = geo.size.height
                let scale = maxTotal > 0 ? height / maxTotal : 0
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ForEach(UsageProvider.allCases.reversed(), id: \.rawValue) { provider in
                        let value = day.burn(for: provider)
                        if value > 0 {
                            Rectangle()
                                .fill(providerColor(provider))
                                .frame(height: max(1, value * scale))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .background(
                    Color(nsColor: .tertiaryLabelColor).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 3)
                )
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(dayLabel(day.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func dayLabel(_ isoDate: String) -> String {
        let parts = isoDate.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = Calendar.current.date(
                from: DateComponents(year: year, month: month, day: day)
              )
        else {
            return String(isoDate.suffix(5))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }
}

private func providerColor(_ provider: UsageProvider) -> Color {
    switch provider {
    case .claude: Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
    case .codex: Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
    case .cursor: Color(red: 0 / 255, green: 191 / 255, blue: 165 / 255)
    }
}
