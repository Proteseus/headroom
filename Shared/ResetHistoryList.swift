import SwiftUI

/// Past grants on one quota pool — when the pool came back — drawn as a
/// binary calendar heatmap so day-of-week clusters read. How much came back
/// (`% back`) lives in the day detail, not in cell shade: a reset either
/// happened that day or it did not.
///
/// Two colours, not one intensity ramp: the provider tint is a *global* grant
/// (announced publicly, optionally matched to what this Mac observed); amber is
/// a banked credit *you* spent. Scheduled weekly rolls stay off the grid —
/// the burndown axis already ends on those, and lighting them every seven days
/// would bury the irregular pattern this view is for.
///
/// Lives in `Shared/` because the Mac popover and the iPhone detail screen draw
/// the same list under the same chart. The widget and watch targets take an
/// explicit file list rather than the whole folder, so neither compiles it.
struct ResetHistoryList: View {
    let resets: [BurndownReset]
    let tint: Color
    /// Where the provider explains its own resets. Nil → plain header, no link.
    var noteURL: URL? = nil

    /// Matches the host grant journal / public Codex feed (~a year). The drawn
    /// window shrinks to the span of resets we actually have so a fresh install
    /// does not pad empty months; it grows toward this cap as history fills.
    private static let maxWindowDays = 400
    /// Floor so a single week of grants still reads as a grid, not one column.
    private static let minWindowDays = 28

    @State private var selectedDay: DayBucket?
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

#if os(iOS)
    @Environment(\.horizontalSizeClass)
    private var horizontalSizeClass
#endif

    private let gap: CGFloat = 2
    private var yoursTint: Color { HeadroomPalette.amber }

    private var maxCell: CGFloat {
#if os(iOS)
        return horizontalSizeClass == .regular ? 14 : 9
#else
        return 9
#endif
    }

    private var ordered: [BurndownReset] {
        resets
            .filter { $0.t != nil }
            .sorted { ($0.t ?? 0) > ($1.t ?? 0) }
    }

    /// Oldest day that has a grant, used to size the grid from real data.
    private var earliestResetDay: Date? {
        guard let oldest = ordered.last?.date else { return nil }
        return Calendar.current.startOfDay(for: oldest)
    }

    private var visibleWindowDays: Int {
        let cal = Calendar.current
        let end = cal.startOfDay(for: Date())
        guard let earliest = earliestResetDay else { return Self.minWindowDays }
        let span = max(1, (cal.dateComponents([.day], from: earliest, to: end).day ?? 0) + 1)
        return min(Self.maxWindowDays, max(Self.minWindowDays, span))
    }

    private var byDay: [String: DayBucket] {
        var buckets: [String: DayBucket] = [:]
        for reset in ordered {
            guard let date = reset.date else { continue }
            let key = Self.iso(date)
            var bucket = buckets[key] ?? DayBucket(iso: key, date: date, resets: [])
            bucket.resets.append(reset)
            buckets[key] = bucket
        }
        return buckets
    }

    var body: some View {
        let buckets = byDay
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(HeadroomCopy.resetHistory)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                // Codex: the public tracker (or the lead's X account). Credit
                // that source beside the grid, not as the section title itself.
                if let noteURL, let label = Self.noteLabel(from: noteURL) {
                    Link(label, destination: noteURL)
                        .font(.caption.weight(.medium))
                }
            }

            if ordered.isEmpty {
                Text(HeadroomCopy.noResetsYet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    let weeks = weekColumns
                    let columnCount = max(1, weeks.count)
                    let cell = max(
                        3,
                        min(maxCell, (geo.size.width - gap * CGFloat(columnCount - 1))
                            / CGFloat(columnCount))
                    )
                    HStack(alignment: .top, spacing: gap) {
                        ForEach(weeks.indices, id: \.self) { index in
                            VStack(spacing: gap) {
                                ForEach(0..<7, id: \.self) { row in
                                    cellView(
                                        date: weeks[index][row],
                                        bucket: weeks[index][row].flatMap {
                                            buckets[Self.iso($0)]
                                        },
                                        size: cell
                                    )
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(height: maxCell * 7 + gap * 6)

                HStack(spacing: 6) {
                    legendSwatch(tint, HeadroomCopy.resetHistoryGlobal)
                    legendSwatch(yoursTint, HeadroomCopy.resetHistoryYours)
                    Spacer(minLength: 8)
                    if let earliest = earliestResetDay {
                        Text(HeadroomCopy.resetHistorySince(earliest))
                    }
                    Text(HeadroomCopy.resetHistoryCount(ordered.count))
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Text(HeadroomCopy.resetHistoryFootnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let selectedDay {
                    dayDetail(selectedDay)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(HeadroomCopy.resetHistory)
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
        }
    }

    @ViewBuilder
    private func cellView(
        date: Date?,
        bucket: DayBucket?,
        size: CGFloat
    ) -> some View {
        if let date {
            let kind = bucket?.kind ?? .empty
            let cellBody = RoundedRectangle(cornerRadius: max(1, size * 0.22),
                                            style: .continuous)
                .fill(color(for: kind))
                .overlay {
                    if differentiateWithoutColor, kind != .empty {
                        // One mark = global, two = a credit you spent — shade
                        // alone is not enough when colour is off.
                        Text(kind == .yours ? "••" : "•")
                            .font(.system(size: max(2, size * 0.35)))
                            .foregroundStyle(.white.opacity(0.85))
                            .minimumScaleFactor(0.5)
                    }
                }
                .frame(width: size, height: size)

            if let bucket, !bucket.resets.isEmpty {
                Button {
                    selectedDay = selectedDay?.iso == bucket.iso ? nil : bucket
                } label: {
                    cellBody
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.accessibilityLabel(for: bucket))
                .accessibilityAddTraits(.isButton)
            } else {
                cellBody
                    .accessibilityLabel("\(Self.iso(date)): no resets")
            }
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    private func dayDetail(_ day: DayBucket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.date, format: .dateTime.weekday(.wide).month().day())
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Button {
                    selectedDay = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close reset details")
            }
            ForEach(day.resets) { reset in
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(for: DayKind(source: reset.source)))
                        .frame(width: 6, height: 6)
                    if let url = reset.announcementURL {
                        Link(destination: url) {
                            Text(
                                reset.date.map(HeadroomFormat.eventMoment)
                                    ?? HeadroomCopy.resetGranted
                            )
                        }
                        .foregroundStyle(tint)
                    } else {
                        Text(
                            reset.date.map(HeadroomFormat.eventMoment)
                                ?? HeadroomCopy.resetGranted
                        )
                        .foregroundStyle(.secondary)
                    }
                    Text(HeadroomCopy.resetHistoryKind(reset.source))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 8)
                    Text(HeadroomCopy.resetPointsBack(reset.forgivenPct))
                }
                .font(.caption)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }
        }
        .padding(8)
        .background(
            color(for: day.kind).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func color(for kind: DayKind) -> Color {
        switch kind {
        case .empty: return Color.secondary.opacity(0.14)
        case .global: return tint
        case .yours: return yoursTint
        }
    }

    private var weekColumns: [[Date?]] {
        let cal = Calendar.current
        let end = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -(visibleWindowDays - 1),
                             to: end) ?? end
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

    /// Label for the header link: `@handle` from an X profile, otherwise the
    /// bare host (codex-resets.com). Anything we cannot name stays hidden.
    private static func noteLabel(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host == "x.com" || host == "twitter.com" || host == "www.x.com"
            || host == "www.twitter.com"
        {
            let parts = url.path.split(separator: "/").map(String.init)
            guard let name = parts.first, !name.isEmpty else { return nil }
            return "@\(name)"
        }
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host.isEmpty ? nil : host
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

    private static func accessibilityLabel(for day: DayBucket) -> String {
        let n = day.resets.count
        let resetWord = n == 1 ? "reset" : "resets"
        let kind = HeadroomCopy.resetHistoryKind(
            day.kind == .yours ? "observed" : "announced")
        let points = HeadroomCopy.resetPointsBack(day.forgivenPts)
        return "\(day.iso): \(n) \(resetWord), \(kind), \(points)"
    }

    /// How a day paints. Global wins when both kinds land the same day — the
    /// public grant is the pattern signal; the credit spend still shows in
    /// the day detail.
    enum DayKind: Equatable {
        case empty, global, yours

        init(source: String?) {
            switch source {
            case "observed": self = .yours
            case "announced", "both": self = .global
            default: self = .empty
            }
        }
    }

    struct DayBucket: Identifiable, Equatable {
        var iso: String
        var date: Date
        var resets: [BurndownReset]
        var id: String { iso }
        var forgivenPts: Double {
            resets.reduce(0) { $0 + ($1.forgivenPct ?? 0) }
        }
        var kind: DayKind {
            if resets.contains(where: {
                $0.source == "announced" || $0.source == "both"
            }) {
                return .global
            }
            if resets.contains(where: { $0.source == "observed" }) {
                return .yours
            }
            // Host older than `source` — treat as global so the cell still
            // lights in the provider tint rather than vanishing.
            return resets.isEmpty ? .empty : .global
        }
    }
}
