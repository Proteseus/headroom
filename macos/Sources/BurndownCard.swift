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

    /// Longest window first here: the weekly shape is the one worth a chart,
    /// while a 5h session is mostly noise at this size.
    private var charted: [Burndown] {
        rings.sorted {
            ($0.windowS ?? 0) > ($1.windowS ?? 0)
        }
    }

    var body: some View {
        if charted.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Burndown")
                    .font(.headline)
                ForEach(charted) { pool in
                    BurndownPlot(pool: pool, tint: provider.tint)
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

    /// One pool per provider: the longest window, matching what the board
    /// charts. A 5h session is too short to say anything at this size.
    private var series: [Series] {
        UsageProvider.allCases.compactMap { provider in
            let pools = snapshot.burndownRings(for: provider)
            guard let pool = pools.max(by: {
                ($0.windowS ?? 0) < ($1.windowS ?? 0)
            })
            else { return nil }

            func points(_ pairs: [[Double]]?) -> [Point] {
                (pairs ?? []).compactMap { pair in
                    guard pair.count >= 2 else { return nil }
                    return Point(
                        time: pair[0],
                        remaining: max(0, min(pair[1], 100))
                    )
                }
            }
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
                    let span = range.end - range.start
                    func x(_ time: Double) -> CGFloat {
                        CGFloat((time - range.start) / span) * size.width
                    }
                    func y(_ remaining: Double) -> CGFloat {
                        size.height
                            - CGFloat(remaining / 100) * size.height
                    }

                    var nowMarker = Path()
                    nowMarker.move(to: CGPoint(x: x(range.now), y: 0))
                    nowMarker.addLine(to: CGPoint(
                        x: x(range.now), y: size.height))
                    context.stroke(
                        nowMarker,
                        with: .color(.secondary.opacity(0.18)),
                        lineWidth: 1
                    )

                    for entry in all {
                        let tint = entry.pool.kind == .exhausted
                            ? entry.provider.tint.drained()
                            : entry.provider.tint
                        let actual = entry.actual
                            .filter {
                                $0.time >= range.start && $0.time <= range.end
                            }
                            .map {
                                CGPoint(
                                    x: x($0.time),
                                    y: y($0.remaining)
                                )
                            }
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

                        let projected = entry.projected
                            .filter {
                                $0.time >= range.start && $0.time <= range.end
                            }
                            .map {
                                CGPoint(
                                    x: x($0.time),
                                    y: y($0.remaining)
                                )
                            }
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
                .frame(height: 92)

                SharedBurndownWeekdayRow(
                    start: range.start,
                    end: range.end,
                    now: range.now
                )
                .frame(height: 12)

                HStack(alignment: .top, spacing: 8) {
                    ForEach(all) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(entry.pool.kind == .exhausted
                                          ? entry.provider.tint.drained()
                                          : entry.provider.tint)
                                    .frame(width: 7, height: 7)
                                Text(entry.provider.title)
                                    .font(.caption2.weight(.medium))
                            }
                            if let delta = entry.pool.deltaPct {
                                Text(paceLabel(delta))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(
                                        delta < 0 ? Color.orange : .secondary)
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

private struct SharedBurndownWeekdayRow: View {
    let start: Double
    let end: Double
    let now: Double

    var body: some View {
        GeometryReader { geometry in
            let span = end - start
            ForEach(burndownWeekdayTicks(start: start, end: end)) { tick in
                Text(tick.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(
                        Color.secondary.opacity(tick.time <= now ? 1 : 0.55)
                    )
                    .position(
                        x: CGFloat((tick.time - start) / span)
                            * geometry.size.width,
                        y: geometry.size.height / 2
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

struct BurndownPlot: View {
    let pool: Burndown
    let tint: Color

    private var statusTint: Color {
        switch pool.kind {
        case .exhausted: tint.drained()
        case .ahead: .orange
        case .ok, .critical: tint
        }
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
                .frame(height: 84)

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
        Canvas { context, size in
            guard let start = pool.windowStart,
                  let end = pool.windowEnd,
                  end > start
            else { return }

            let span = end - start
            let dayTicks = burndownWeekdayTicks(start: start, end: end)
            let axisHeight: CGFloat = dayTicks.isEmpty ? 0 : 16
            let plotSize = CGSize(
                width: size.width,
                height: max(0, size.height - axisHeight)
            )
            func x(_ t: Double) -> CGFloat {
                CGFloat((t - start) / span) * plotSize.width
            }
            // Remaining percent, so 100 is the top and exhaustion is the floor.
            func y(_ pct: Double) -> CGFloat {
                plotSize.height
                    - CGFloat(max(0, min(pct, 100)) / 100) * plotSize.height
            }

            let actual = (pool.actual ?? []).compactMap { pair -> CGPoint? in
                guard pair.count >= 2 else { return nil }
                return CGPoint(x: x(pair[0]), y: y(pair[1]))
            }

            // --- budget line: full at the window's start, zero at its reset
            var ideal = Path()
            ideal.move(to: CGPoint(x: x(start), y: y(100)))
            ideal.addLine(to: CGPoint(x: x(end), y: y(0)))
            context.stroke(
                ideal,
                with: .color(.secondary.opacity(0.45)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )

            // --- drift: the gap between the budget and reality
            if actual.count >= 2, let first = actual.first, let last = actual.last {
                var drift = Path()
                drift.move(to: first)
                for point in actual.dropFirst() { drift.addLine(to: point) }
                drift.addLine(to: CGPoint(
                    x: last.x, y: y(idealAt(last.x, size: plotSize))))
                drift.addLine(to: CGPoint(
                    x: first.x, y: y(idealAt(first.x, size: plotSize))))
                drift.closeSubpath()
                context.fill(drift, with: .color(tint.opacity(0.16)))
            }

            // --- what actually happened
            if actual.count >= 2 {
                var line = Path()
                line.move(to: actual[0])
                for point in actual.dropFirst() { line.addLine(to: point) }
                context.stroke(
                    line,
                    with: .color(tint),
                    style: StrokeStyle(lineWidth: 2, lineJoin: .round)
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
                // Long dash / short gap keeps the projection readable as
                // provisional without the old sparse look. Estimates stay a
                // touch finer so certainty is still visible.
                context.stroke(
                    forecast,
                    with: .color(tint),
                    style: StrokeStyle(
                        lineWidth: pool.isEstimated ? 1 : 1.5,
                        dash: pool.isEstimated ? [3, 2] : [6, 2]
                    )
                )
                // Mark the wall if the pace hits it before the reset.
                if pool.exhaustsBeforeReset == true, let hit = projected.last {
                    let dot = Path(ellipseIn: CGRect(
                        x: hit.x - 3, y: hit.y - 3, width: 6, height: 6))
                    context.fill(dot, with: .color(tint))
                }
            }

            // --- now
            if let last = actual.last {
                var marker = Path()
                marker.move(to: CGPoint(x: last.x, y: 0))
                marker.addLine(to: CGPoint(x: last.x, y: plotSize.height))
                context.stroke(
                    marker,
                    with: .color(.secondary.opacity(0.25)),
                    lineWidth: 1
                )
                let dot = Path(ellipseIn: CGRect(
                    x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5))
                context.fill(dot, with: .color(tint))
            }

            // Weekdays run across both the measured curve and its forecast.
            // Future labels are quieter so "history" and "preview" remain
            // distinguishable without needing a second legend.
            if !dayTicks.isEmpty {
                let latestSample = (pool.actual ?? [])
                    .compactMap { $0.first }
                    .max() ?? start
                for tick in dayTicks {
                    let labelColor = tick.time <= latestSample
                        ? Color.secondary
                        : Color.secondary.opacity(0.55)
                    context.draw(
                        Text(tick.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(labelColor),
                        at: CGPoint(
                            x: x(tick.time),
                            y: plotSize.height + axisHeight / 2
                        ),
                        anchor: .center
                    )
                }
            }
        }
        .accessibilityLabel(pool.headline ?? "Burndown")
    }

    /// Budget line height at a given x, in remaining percent.
    private func idealAt(_ px: CGFloat, size: CGSize) -> Double {
        guard size.width > 0 else { return 100 }
        return 100 * (1 - Double(px / size.width))
    }
}

private struct BurndownWeekdayTick: Identifiable {
    let time: Double
    let label: String

    var id: Double { time }
}

/// Up to seven labels, centered in equal slices of the quota window. Weekly
/// pools therefore get one label per day; short sessions omit the axis, while
/// monthly billing windows stay legible.
private func burndownWeekdayTicks(
    start: Double,
    end: Double
) -> [BurndownWeekdayTick] {
    let secondsPerDay = 24.0 * 60 * 60
    let span = end - start
    guard span >= 2 * secondsPerDay else { return [] }

    let count = min(7, max(2, Int(ceil(span / secondsPerDay))))
    let slice = span / Double(count)
    return (0..<count).map { index in
        let time = start + (Double(index) + 0.5) * slice
        let label = Date(timeIntervalSince1970: time).formatted(
            .dateTime.weekday(.abbreviated)
        )
        return BurndownWeekdayTick(time: time, label: label)
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
