import SwiftUI

/// The burndown: what an even spend would leave you against what you actually
/// have, plus where the current pace lands.
///
/// Read it as a sprint burndown. The straight line is the budget, falling from
/// full at the window's start to zero at its reset. The drawn curve is reality.
/// Below the line means burning faster than the window can afford; the dashed
/// tail is where that pace ends up if nothing changes.

struct BurndownCard: View {
    let provider: UsageProvider
    let rings: [Burndown]
    var tint: Color? = nil

    private var brand: Color { tint ?? provider.tint }

    /// Longest window first here: the weekly shape is the one worth a chart,
    /// while a 5h session is mostly noise at this size.
    private var charted: [Burndown] {
        rings.sorted {
            ($0.windowS ?? 0) > ($1.windowS ?? 0)
        }
    }

    /// Cursor's Total and API share one billing cycle. Overlay them on a single
    /// axis so a drained API pool can't hide behind a healthy Total.
    private var overlayPools: [Burndown]? {
        guard provider == .cursor, charted.count >= 2 else { return nil }
        return charted
    }

    var body: some View {
        if charted.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Burndown")
                    .font(.headline)
                if let overlayPools {
                    MultiBurndownPlot(pools: overlayPools, tint: brand)
                } else {
                    ForEach(charted) { pool in
                        BurndownPlot(pool: pool, tint: brand)
                    }
                }
            }
            .cardStyle()
        }
    }
}

/// All providers on one rolling calendar week.
///
/// Provider windows start and reset at different times, so the overview uses
/// real timestamps rather than pretending their elapsed-window fractions share
/// weekdays. The provider cards retain the full-window budget comparison.
struct OverviewBurndownCard: View {
    let snapshot: UsageSnapshot

    private struct Point {
        let time: Double
        let remaining: Double
    }

    private struct Series: Identifiable {
        let id: String
        let provider: UsageProvider
        let pool: Burndown
        let actual: [Point]
        let projected: [Point]
    }

    /// One pool per provider: longest window for Claude/Codex, Total for Cursor.
    /// Cursor's API pool stays on the Cursor detail chart — four lines here is
    /// more than the overview can usefully carry.
    private var series: [Series] {
        func points(_ pairs: [[Double]]?) -> [Point] {
            (pairs ?? []).compactMap { pair in
                guard pair.count >= 2 else { return nil }
                return Point(
                    time: pair[0],
                    remaining: max(0, min(pair[1], 100))
                )
            }
        }

        return UsageProvider.allCases.compactMap { provider in
            guard snapshot.activeQuotaProviders.contains(provider) else {
                return nil
            }
            let pools = snapshot.burndownRings(for: provider)
            let pool: Burndown?
            if provider == .cursor {
                pool = pools.first(where: { $0.pool == "total" })
                    ?? pools.max(by: {
                        ($0.windowS ?? 0) < ($1.windowS ?? 0)
                    })
            } else {
                pool = pools.max(by: {
                    ($0.windowS ?? 0) < ($1.windowS ?? 0)
                })
            }
            guard let pool else { return nil }
            let actual = points(pool.actual)
            guard !actual.isEmpty else { return nil }
            return Series(
                id: provider.rawValue,
                provider: provider,
                pool: pool,
                actual: actual,
                projected: points(pool.projected)
            )
        }
    }

    /// A polyline cut to the charted range, interpolated where it crosses an
    /// edge.
    ///
    /// Dropping the out-of-range points instead loses whole lines rather than
    /// their tails: a weekly pool that resets after the chart's right edge has
    /// its projection reduced to the single point at "now", which is not two
    /// points, so nothing is drawn at all. The line running off the edge is
    /// precisely the one worth seeing.
    private func clipped(
        _ points: [Point], from start: Double, to end: Double
    ) -> [Point] {
        guard points.count >= 2 else {
            return points.filter { $0.time >= start && $0.time <= end }
        }

        func between(_ a: Point, _ b: Point, at time: Double) -> Point {
            let span = b.time - a.time
            guard span > 0 else { return Point(time: time, remaining: b.remaining) }
            let ratio = (time - a.time) / span
            return Point(
                time: time,
                remaining: a.remaining + ratio * (b.remaining - a.remaining)
            )
        }

        var out: [Point] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let from = max(a.time, start)
            let to = min(b.time, end)
            guard from <= to else { continue }
            for edge in [from, to] where out.last?.time != edge {
                out.append(between(a, b, at: edge))
            }
        }
        return out
    }

    private func calendarRange(for series: [Series]) -> (
        start: Double,
        end: Double,
        now: Double
    ) {
        let now = series.flatMap(\.actual).map(\.time).max()
            ?? Date().timeIntervalSince1970
        let calendar = Calendar.current
        let today = calendar.startOfDay(
            for: Date(timeIntervalSince1970: now))
        let start = calendar.date(
            byAdding: .day, value: -3, to: today) ?? today
        let end = calendar.date(
            byAdding: .day, value: 7, to: start)
            ?? start.addingTimeInterval(7 * 24 * 60 * 60)
        return (
            start.timeIntervalSince1970,
            end.timeIntervalSince1970,
            now
        )
    }

    var body: some View {
        let all = series
        if all.isEmpty {
            EmptyView()
        } else {
            let range = calendarRange(for: all)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Burndown")
                        .font(.headline)
                    Spacer()
                    Text("7-day calendar")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Canvas { context, size in
                    let plot = burndownPlotRect(in: size, axis: true)
                    let span = range.end - range.start
                    func x(_ time: Double) -> CGFloat {
                        plot.minX
                            + CGFloat((time - range.start) / span) * plot.width
                    }
                    func y(_ remaining: Double) -> CGFloat {
                        plot.maxY
                            - CGFloat(remaining / 100) * plot.height
                    }

                    drawBurndownScale(&context, plot: plot)
                    drawBurndownCalendar(
                        &context, plot: plot,
                        start: range.start, end: range.end, now: range.now)

                    // Darker than the day rules, which it would otherwise be
                    // mistaken for.
                    var nowMarker = Path()
                    nowMarker.move(to: CGPoint(x: x(range.now), y: plot.minY))
                    nowMarker.addLine(to: CGPoint(
                        x: x(range.now), y: plot.maxY))
                    context.stroke(
                        nowMarker,
                        with: .color(.secondary.opacity(0.4)),
                        lineWidth: 1
                    )

                    for entry in all {
                        let tint = entry.pool.kind == .exhausted
                            ? snapshot.tint(for: entry.provider).drained()
                            : snapshot.tint(for: entry.provider)
                        let actual = clipped(
                            entry.actual, from: range.start, to: range.end
                        ).map { CGPoint(x: x($0.time), y: y($0.remaining)) }
                        if actual.count >= 2 {
                            var line = Path()
                            line.move(to: actual[0])
                            for point in actual.dropFirst() {
                                line.addLine(to: point)
                            }
                            context.stroke(
                                line,
                                with: .color(tint),
                                style: StrokeStyle(
                                    lineWidth: 2, lineJoin: .round)
                            )
                        }
                        if let last = actual.last {
                            let dot = Path(ellipseIn: CGRect(
                                x: last.x - 3, y: last.y - 3,
                                width: 6, height: 6))
                            context.fill(dot, with: .color(tint))
                        }

                        let projected = clipped(
                            entry.projected, from: range.start, to: range.end
                        ).map { CGPoint(x: x($0.time), y: y($0.remaining)) }
                        if projected.count >= 2 {
                            var forecast = Path()
                            forecast.move(to: projected[0])
                            for point in projected.dropFirst() {
                                forecast.addLine(to: point)
                            }
                            context.stroke(
                                forecast,
                                with: .color(tint),
                                style: StrokeStyle(
                                    lineWidth: 1.5,
                                    lineJoin: .round,
                                    dash: [6, 2]
                                )
                            )
                        }
                    }
                }
                .frame(height: 118)

                HStack(alignment: .top, spacing: 8) {
                    ForEach(all) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(entry.pool.kind == .exhausted
                                          ? snapshot.tint(for: entry.provider).drained()
                                          : snapshot.tint(for: entry.provider))
                                    .frame(width: 7, height: 7)
                                Text(entry.provider.title)
                                    .font(.caption2.weight(.medium))
                            }
                            if let delta = entry.pool.deltaPct {
                                // Ahead and behind are both just readings, so
                                // neither gets a colour that argues about it.
                                Text(paceLabel(delta))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("pace pending")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .cardStyle()
        }
    }

    private func paceLabel(_ delta: Double) -> String {
        let points = abs(Int(delta.rounded()))
        if points == 0 { return "on budget" }
        return "\(points)% \(delta > 0 ? "ahead" : "behind")"
    }
}

/// Two (or more) pools on one axis — Cursor Total + API share a billing cycle.
struct MultiBurndownPlot: View {
    let pools: [Burndown]
    let tint: Color

    private var window: (start: Double, end: Double, reset: String?)? {
        guard let start = pools.compactMap(\.windowStart).min(),
              let end = pools.compactMap(\.windowEnd).max(),
              end > start
        else { return nil }
        let reset = pools.first(where: { $0.pool == "total" })?.resetsIn
            ?? pools.first?.resetsIn
        return (start, end, reset)
    }

    private var headline: String? {
        pools.first(where: { $0.pool == "total" })?.headline
            ?? pools.first?.headline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                HStack(spacing: 10) {
                    ForEach(pools) { pool in
                        HStack(spacing: 5) {
                            Capsule()
                                .fill(seriesTint(pool))
                                .frame(width: pool.pool == "api" ? 10 : 12,
                                       height: pool.pool == "api" ? 2 : 3)
                            Text(pool.poolTitle)
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }
                Spacer()
                if let reset = window?.reset {
                    Text(reset)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if let window {
                MultiBurndownCanvas(pools: pools, tint: tint,
                                    start: window.start, end: window.end)
                    .frame(height: 100)
            }

            if let headline {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func seriesTint(_ pool: Burndown) -> Color {
        let base = pool.kind == .exhausted ? tint.drained() : tint
        return pool.pool == "api" ? base.opacity(0.75) : base
    }
}

struct BurndownPlot: View {
    let pool: Burndown
    let tint: Color

    /// Only exhaustion changes the colour, and it desaturates rather than
    /// warns. Burning ahead of budget is a reading, not a verdict: the gap
    /// between the curve and the budget line already shows it, and the
    /// headline already says it.
    private var statusTint: Color {
        pool.kind == .exhausted ? tint.drained() : tint
    }

    private var footnote: String {
        var parts: [String] = []
        if let rate = pool.burnRatePct, let unit = pool.rateUnit {
            parts.append("burning \(rate.rateLabel)%/\(unit)")
        }
        if let allowance = pool.allowancePct, let unit = pool.rateUnit {
            parts.append("budget \(allowance.rateLabel)%/\(unit)")
        }
        if let samples = pool.samples, parts.isEmpty {
            parts.append("\(samples) sample\(samples == 1 ? "" : "s") so far")
        }
        if pool.isEstimated {
            parts.append("estimated from recent usage")
        } else if let samples = pool.samples, !parts.isEmpty {
            parts.append("\(samples) samples")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(pool.poolTitle)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let reset = pool.resetsIn {
                    Text(reset)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            BurndownCanvas(pool: pool, tint: statusTint)
                .frame(height: 100)

            if let headline = pool.headline {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !footnote.isEmpty {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }
}

struct BurndownCanvas: View {
    let pool: Burndown
    let tint: Color

    var body: some View {
        MultiBurndownCanvas(
            pools: [pool],
            tint: tint,
            start: pool.windowStart ?? 0,
            end: pool.windowEnd ?? 0
        )
        .accessibilityLabel(pool.headline ?? "Burndown")
    }
}

struct MultiBurndownCanvas: View {
    let pools: [Burndown]
    let tint: Color
    let start: Double
    let end: Double

    var body: some View {
        Canvas { context, size in
            guard end > start else { return }

            let span = end - start
            let days = burndownDays(start: start, end: end)
            let plot = burndownPlotRect(in: size, axis: !days.isEmpty)
            func x(_ t: Double) -> CGFloat {
                plot.minX + CGFloat((t - start) / span) * plot.width
            }
            // Remaining percent, so 100 is the top and exhaustion is the floor.
            func y(_ pct: Double) -> CGFloat {
                plot.maxY
                    - CGFloat(max(0, min(pct, 100)) / 100) * plot.height
            }
            /// The budget line's height at a given instant.
            func budget(_ t: Double) -> Double {
                100 * (1 - (t - start) / span)
            }

            // --- the grid the curve is read against
            drawBurndownScale(&context, plot: plot)
            let sampleTimes = pools.flatMap { pool in
                (pool.actual ?? []).compactMap { pair -> Double? in
                    pair.count >= 2 ? pair[0] : nil
                }
            }
            drawBurndownCalendar(
                &context, plot: plot, start: start, end: end,
                now: sampleTimes.max() ?? start)

            // --- budget line: full at the window's start, zero at its reset
            var ideal = Path()
            ideal.move(to: CGPoint(x: x(start), y: y(100)))
            ideal.addLine(to: CGPoint(x: x(end), y: y(0)))
            context.stroke(
                ideal,
                with: .color(.secondary.opacity(0.45)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )

            // API under Total when both share this canvas.
            let ordered = pools.sorted {
                ($0.pool == "api" ? 0 : 1) < ($1.pool == "api" ? 0 : 1)
            }

            var nowX: CGFloat?
            for pool in ordered {
                let base = pool.kind == .exhausted ? tint.drained() : tint
                let isApi = pool.pool == "api"
                let seriesTint = isApi ? base.opacity(0.75) : base

                let samples = (pool.actual ?? []).compactMap { pair -> Double? in
                    pair.count >= 2 ? pair[0] : nil
                }
                let actual = (pool.actual ?? []).compactMap { pair -> CGPoint? in
                    guard pair.count >= 2 else { return nil }
                    return CGPoint(x: x(pair[0]), y: y(pair[1]))
                }

                // --- drift: the gap between the budget and reality (primary only)
                if !isApi,
                   actual.count >= 2,
                   let firstSample = samples.first,
                   let lastSample = samples.last {
                    var drift = Path()
                    drift.move(to: actual[0])
                    for point in actual.dropFirst() { drift.addLine(to: point) }
                    drift.addLine(to: CGPoint(
                        x: x(lastSample), y: y(budget(lastSample))))
                    drift.addLine(to: CGPoint(
                        x: x(firstSample), y: y(budget(firstSample))))
                    drift.closeSubpath()
                    context.fill(drift, with: .color(seriesTint.opacity(0.16)))
                }

                // --- what actually happened
                if actual.count >= 2 {
                    var line = Path()
                    line.move(to: actual[0])
                    for point in actual.dropFirst() { line.addLine(to: point) }
                    context.stroke(
                        line,
                        with: .color(seriesTint),
                        style: StrokeStyle(
                            lineWidth: isApi ? 1.5 : 2, lineJoin: .round)
                    )
                }

                // --- where this pace lands
                let projected = (pool.projected ?? []).compactMap { pair -> CGPoint? in
                    guard pair.count >= 2 else { return nil }
                    return CGPoint(x: x(pair[0]), y: y(pair[1]))
                }
                if projected.count >= 2 {
                    var forecast = Path()
                    forecast.move(to: projected[0])
                    for point in projected.dropFirst() { forecast.addLine(to: point) }
                    context.stroke(
                        forecast,
                        with: .color(seriesTint),
                        style: StrokeStyle(
                            lineWidth: pool.isEstimated ? 1 : 1.5,
                            dash: pool.isEstimated ? [3, 2] : [6, 2]
                        )
                    )
                    if pool.exhaustsBeforeReset == true, let hit = projected.last {
                        let dot = Path(ellipseIn: CGRect(
                            x: hit.x - 3, y: hit.y - 3, width: 6, height: 6))
                        context.fill(dot, with: .color(seriesTint))
                    }
                }

                if let last = actual.last {
                    nowX = last.x
                    let dot = Path(ellipseIn: CGRect(
                        x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5))
                    context.fill(dot, with: .color(seriesTint))
                }
            }

            // --- now marker (once, shared)
            if let nx = nowX {
                var marker = Path()
                marker.move(to: CGPoint(x: nx, y: plot.minY))
                marker.addLine(to: CGPoint(x: nx, y: plot.maxY))
                context.stroke(
                    marker,
                    with: .color(.secondary.opacity(0.4)),
                    lineWidth: 1
                )
            }
        }
    }
}

// MARK: - Shared chart furniture
//
// Both burndowns draw the same grid, so the geometry lives here rather than
// twice. Percent scale down the left, day boundaries as vertical rules, and
// weekday labels along the bottom.

/// Room for the "100%" scale labels.
private let burndownGutter: CGFloat = 30
/// Band under the plot holding the weekday labels.
private let burndownAxisHeight: CGFloat = 16
/// Slack above and below the plot so the 100% and 0% labels, which sit centred
/// on the outermost grid lines, are not clipped by the canvas edge.
private let burndownEdgeInset: CGFloat = 7

private struct BurndownDay {
    /// Local midnight opening this day. Earlier than the charted range for the
    /// first day when the range starts mid-day.
    let date: Date

    var midnight: Double { date.timeIntervalSince1970 }
}

/// The local days a charted range covers. Empty below two days: one label is
/// not an axis, and a 5h session window is the common case there.
///
/// Walked with `Calendar` rather than by adding 86400, so the rules stay on
/// real midnights across a DST change.
private func burndownDays(start: Double, end: Double) -> [BurndownDay] {
    let secondsPerDay = 24.0 * 60 * 60
    guard end - start >= 2 * secondsPerDay else { return [] }

    let calendar = Calendar.current
    var days: [BurndownDay] = []
    var midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: start))
    while midnight.timeIntervalSince1970 < end {
        days.append(BurndownDay(date: midnight))
        guard let next = calendar.date(byAdding: .day, value: 1, to: midnight)
        else { break }
        midnight = next
    }
    return days
}

/// Where the series actually gets drawn inside a canvas of `size`.
private func burndownPlotRect(in size: CGSize, axis: Bool) -> CGRect {
    let reserved = burndownEdgeInset * 2 + (axis ? burndownAxisHeight : 0)
    return CGRect(
        x: burndownGutter,
        y: burndownEdgeInset,
        width: max(0, size.width - burndownGutter),
        height: max(0, size.height - reserved)
    )
}

/// Reference lines at empty, half and full, labelled in the gutter. Three is
/// as many as a chart this short carries before the grid starts competing with
/// the data it is there to measure.
private func drawBurndownScale(_ context: inout GraphicsContext, plot: CGRect) {
    for percent in [100.0, 50.0, 0.0] {
        let lineY = plot.maxY - CGFloat(percent / 100) * plot.height
        let isHalf = percent == 50
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: lineY))
        line.addLine(to: CGPoint(x: plot.maxX, y: lineY))
        context.stroke(
            line,
            with: .color(.secondary.opacity(isHalf ? 0.12 : 0.22)),
            style: StrokeStyle(lineWidth: 1, dash: isHalf ? [2, 3] : [])
        )
        context.draw(
            Text("\(Int(percent))%")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.7)),
            at: CGPoint(x: plot.minX - 5, y: lineY),
            anchor: .trailing
        )
    }
}

/// Day boundaries as vertical rules, labelled along the bottom.
///
/// A month of daily rules is a moiré pattern rather than a grid, so once the
/// days are too narrow to label the chart falls back to one rule a week —
/// which is the unit anyone reading a monthly billing cycle counts in anyway.
/// The label follows suit: a weekday names a day, but seven of them in a row
/// all reading "Tue" names nothing, so weekly rules carry a date instead.
private func drawBurndownCalendar(
    _ context: inout GraphicsContext,
    plot: CGRect,
    start: Double,
    end: Double,
    now: Double
) {
    let days = burndownDays(start: start, end: end)
    guard !days.isEmpty, plot.width > 0, end > start else { return }

    func x(_ time: Double) -> CGFloat {
        plot.minX + CGFloat((time - start) / (end - start)) * plot.width
    }

    let daily = plot.width / CGFloat(days.count) >= 22
    let marks = days.enumerated()
        .filter { $0.offset % (daily ? 1 : 7) == 0 }
        .map(\.element)
    let labelY = plot.maxY + burndownEdgeInset + burndownAxisHeight / 2

    for (index, day) in marks.enumerated() {
        if day.midnight > start {
            var rule = Path()
            rule.move(to: CGPoint(x: x(day.midnight), y: plot.minY))
            rule.addLine(to: CGPoint(x: x(day.midnight), y: plot.maxY))
            context.stroke(
                rule, with: .color(.secondary.opacity(0.14)), lineWidth: 1)
        }

        let from = x(max(start, day.midnight))
        let to = x(index + 1 < marks.count ? marks[index + 1].midnight : end)
        guard to - from >= (daily ? 22 : 42) else { continue }
        // Spans still to come are quieter, so history and forecast stay
        // distinguishable without needing a second legend.
        let label = Text(
            daily
                ? day.date.formatted(.dateTime.weekday(.abbreviated))
                : day.date.formatted(.dateTime.month(.abbreviated).day())
        )
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(Color.secondary.opacity(day.midnight <= now ? 1 : 0.55))

        // A weekday names the span it sits in, so it is centred; a date names
        // the instant the rule marks, so it sits against it.
        context.draw(
            label,
            at: CGPoint(x: daily ? (from + to) / 2 : from + 3, y: labelY),
            anchor: daily ? .center : .leading
        )
    }
}

extension Double {
    /// Rates span three orders of magnitude across pools; mirror of
    /// burndown._fmt_rate so both surfaces round the same way.
    var rateLabel: String {
        if self >= 10 { return String(format: "%.0f", self) }
        if self >= 1 { return String(format: "%.1f", self) }
        let raw = String(format: "%.2f", self)
        return raw.hasSuffix("0") ? String(raw.dropLast()) : raw
    }
}
