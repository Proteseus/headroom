import AppKit
import SwiftUI

struct DailyBurnCard: View {
    let days: [DailyBurnDay]
    var providerIDs: [String] = []
    var tintFor: (String) -> Color = { _ in HeadroomPalette.dim }

    private var visibleDays: [DailyBurnDay] {
        Array(days.suffix(7))
    }

    private var maxTotal: Double {
        max(visibleDays.map { $0.total(forProviderIDs: providerIDs) }.max() ?? 0, 1)
    }

    private var todayTotal: Double {
        visibleDays.last.map { $0.total(forProviderIDs: providerIDs) } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(HeadroomCopy.dailyBurn)
                    .font(.headline)
                Spacer()
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if visibleDays.isEmpty || providerIDs.isEmpty {
                Text(providerIDs.isEmpty
                       ? HeadroomCopy.noCodingSources
                       : HeadroomCopy.noBurnHistoryYet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
            } else {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(visibleDays) { day in
                        DailyBurnBar(
                            day: day,
                            maxTotal: maxTotal,
                            providerIDs: providerIDs,
                            tintFor: tintFor
                        )
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 108)
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
        return HeadroomCopy.dailyBurnUnit
    }
}

private struct DailyBurnBar: View {
    let day: DailyBurnDay
    let maxTotal: Double
    let providerIDs: [String]
    let tintFor: (String) -> Color

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let height = geo.size.height
                let scale = maxTotal > 0 ? height / maxTotal : 0
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ForEach(providerIDs.reversed(), id: \.self) { providerID in
                        let value = day.burn(forProviderID: providerID)
                        if value > 0 {
                            Rectangle()
                                .fill(tintFor(providerID))
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
            Text(HeadroomFormat.shortWeekday(isoDate: day.date))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
