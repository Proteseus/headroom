import SwiftUI

/// A compact GitHub-style grid for the mixed activity contract.
///
/// The host owns the meaning of each 0…4 level. This view only lays out dates,
/// paints the shared ramp, and exposes the sparse day detail when a cell is
/// tapped. It is intentionally usable on both Mac and iPhone.
struct ActivityHistoryHeatmap: View {
    let history: ActivityHistory?
    let accent: Color
    var onTap: ((ActivityHistoryDay) -> Void)? = nil

    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

#if os(iOS)
    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass
#endif

    private let gap: CGFloat = 2
    private let visibleWindowDays = 182

    private var maxCell: CGFloat {
#if os(iOS)
        // The wide phone layout has room for a six-month grid with genuinely
        // readable cells. Narrow phones keep the same window but use the
        // smaller cap so the card does not become a horizontal scroller.
        return horizontalSizeClass == .regular ? 22 : 12
#else
        return 12
#endif
    }

    var body: some View {
        GeometryReader { geo in
            let weeks = weekColumns
            let columnCount = max(1, weeks.count)
            let cell = max(
                3,
                min(maxCell, (geo.size.width - gap * CGFloat(columnCount - 1))
                    / CGFloat(columnCount))
            )
            let byDate = history?.dayByDate ?? [:]

            HStack(alignment: .top, spacing: gap) {
                ForEach(weeks.indices, id: \.self) { index in
                    VStack(spacing: gap) {
                        ForEach(0..<7, id: \.self) { row in
                            cellView(
                                date: weeks[index][row],
                                day: weeks[index][row].flatMap {
                                    byDate[Self.iso($0)]
                                },
                                size: cell
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: maxCell * 7 + gap * 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mixed coding activity history")
    }

    @ViewBuilder
    private func cellView(
        date: Date?,
        day: ActivityHistoryDay?,
        size: CGFloat
    ) -> some View {
        if let date {
            let iso = Self.iso(date)
            let level = day?.level ?? 0
            let cellBody = RoundedRectangle(cornerRadius: max(1, size * 0.22),
                                            style: .continuous)
                .fill(color(for: level))
                .overlay {
                    if differentiateWithoutColor && level > 0 {
                        Text(String(repeating: "•", count: min(level, 4)))
                            .font(.system(size: max(2, size * 0.35)))
                            .foregroundStyle(.white.opacity(0.85))
                            .minimumScaleFactor(0.5)
                    }
                }
                .frame(width: size, height: size)

            if let day, let onTap {
                Button { onTap(day) } label: { cellBody }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.accessibilityLabel(for: day))
                    .accessibilityAddTraits(.isButton)
            } else {
                cellBody
                    .accessibilityLabel(
                        day.map(Self.accessibilityLabel(for:))
                            ?? "\(iso): no recorded activity"
                    )
            }
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    private func color(for level: Int) -> Color {
        switch max(0, min(level, 4)) {
        case 0: return Color.secondary.opacity(0.14)
        case 1: return accent.opacity(0.25)
        case 2: return accent.opacity(0.45)
        case 3: return accent.opacity(0.70)
        default: return accent
        }
    }

    private var weekColumns: [[Date?]] {
        let cal = Calendar.current
        let end = Self.date(fromISO: history?.end) ?? cal.startOfDay(for: Date())
        let fullDayCount = max(1, history?.windowDays ?? history?.levels?.count ?? 365)
        let fullStart = Self.date(fromISO: history?.start)
            ?? cal.date(byAdding: .day, value: -(fullDayCount - 1), to: end)
            ?? end
        let dayCount = min(visibleWindowDays, fullDayCount)
        let start = max(
            fullStart,
            cal.date(byAdding: .day, value: -(dayCount - 1), to: end) ?? fullStart
        )
        let first = cal.dateInterval(of: .weekOfYear, for: start)?.start ?? start
        let last = cal.dateInterval(of: .weekOfYear, for: end)?.start ?? end
        var result: [[Date?]] = []
        var cursor = first
        while cursor <= last {
            result.append((0..<7).map { offset in
                guard let date = cal.date(byAdding: .day, value: offset, to: cursor),
                      date >= start, date <= end else { return nil }
                return date
            })
            guard let next = cal.date(byAdding: .weekOfYear, value: 1, to: cursor)
            else { break }
            cursor = next
        }
        return result.isEmpty ? [Array(repeating: nil, count: 7)] : result
    }

    private static func date(fromISO value: String?) -> Date? {
        guard let value else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return Calendar.current.date(from: components)
    }

    private static func iso(_ date: Date) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func accessibilityLabel(for day: ActivityHistoryDay) -> String {
        let sources = (day.sources ?? []).joined(separator: ", ")
        let evidence = day.activeMinutes.map { "\($0) active minutes" }
            ?? (day.burns.map { "\($0.count) quota sources burned" }
                ?? "recorded activity")
        return "\(day.date): \(evidence)\(sources.isEmpty ? "" : " from \(sources)")"
    }
}

/// The card wrapper is shared so the Mac and phone make the same claim about
/// what the grid means and how mixed-source days are explained.
struct ActivityHistoryCard: View {
    let history: ActivityHistory?
    var accent: Color = HeadroomPalette.green
    var onDayTap: ((ActivityHistoryDay) -> Void)? = nil
    @State private var selectedDay: ActivityHistoryDay?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity history")
                    .font(.headline)
                Spacer()
                Text("Mixed sources")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let history, !(history.levels ?? []).isEmpty {
                HStack(spacing: 18) {
                    stat("\(history.activeDays ?? history.days?.count ?? 0)", "active days")
                    stat("\(history.currentStreak ?? 0)", "day streak")
                    if let bestDay = history.bestDay {
                        stat(HeadroomFormat.shortWeekday(isoDate: bestDay), "busiest day")
                    }
                    Spacer(minLength: 0)
                }

                ActivityHistoryHeatmap(
                    history: history,
                    accent: accent,
                    onTap: { day in
                        selectedDay = day
                        onDayTap?(day)
                    }
                )

                HStack(spacing: 4) {
                    Text("Less")
                    ForEach(0..<5, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(heatmapColor(level))
                            .frame(width: 8, height: 8)
                    }
                    Text("More")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if let selectedDay {
                    ActivityHistoryDayDetail(day: selectedDay, accent: accent) {
                        self.selectedDay = nil
                    }
                }

            } else {
                Text("No recorded activity yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 18)
            }
        }
        .padding(14)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(accent)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func heatmapColor(_ level: Int) -> Color {
        switch level {
        case 0: return Color.secondary.opacity(0.14)
        case 1: return accent.opacity(0.25)
        case 2: return accent.opacity(0.45)
        case 3: return accent.opacity(0.70)
        default: return accent
        }
    }
}

private struct ActivityHistoryDayDetail: View {
    let day: ActivityHistoryDay
    let accent: Color
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(day.date)
                    .font(.caption.weight(.semibold))
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let sources = day.sources, !sources.isEmpty {
                    Text(sources.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(accent)
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close activity details")
        }
        .padding(9)
        .background(
            accent.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var summary: String {
        var values: [String] = []
        if let minutes = day.activeMinutes { values.append("\(minutes)m active") }
        if let sessions = day.sessions { values.append("\(sessions) sessions") }
        if let burns = day.burns, !burns.isEmpty {
            values.append("\(burns.count) quota sources")
        }
        return values.isEmpty
            ? "Recorded activity · level \(day.level)"
            : values.joined(separator: " · ")
    }
}
