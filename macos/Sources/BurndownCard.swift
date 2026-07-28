import SwiftUI

/// The burndown: what an even spend would leave you against what you actually
/// have, plus where the current pace lands.
///
/// Read it as a sprint burndown. The straight line is the budget, falling from
/// full at the window's start to zero at its reset. The drawn curve is reality.
/// Below the line means burning faster than the window can afford; the dashed
/// tail is where that pace ends up if nothing changes.

struct BurndownCard: View {
    let providerID: String
    let rings: [Burndown]
    var tint: Color? = nil

    private var brand: Color {
        tint
            ?? UsageProvider(rawValue: providerID)?.tint
            ?? HeadroomPalette.dim
    }

    /// `rings` already arrives in the app-wide pool order, which is the order
    /// the quota card's progress bars use. Keep it: a chart should sit in the
    /// same position as the bar it belongs to.
    private var charted: [Burndown] { rings }

    /// Cursor's Total and API share one billing cycle. Overlay them on a single
    /// axis so a drained API pool can't hide behind a healthy Total.
    private var overlayPools: [Burndown]? {
        guard providerID == UsageProvider.cursor.rawValue,
              charted.count >= 2
        else { return nil }
        return charted
    }

    var body: some View {
        if charted.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text(HeadroomCopy.burndown)
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
        let providerID: String
        let title: String
        let pool: Burndown
        let renewsAt: Double?
    }

    /// One pool per provider: longest window for Claude/Codex, Total for Cursor.
    /// Cursor's API pool stays on the Cursor detail chart — four lines here is
    /// more than the overview can usefully carry.
    private var series: [Series] {
        snapshot.visibleQuotaProviders.compactMap { provider in
            let pools = snapshot.burndownRings(forProviderID: provider.id)
            let pool: Burndown?
            if provider.id == UsageProvider.cursor.rawValue {
                pool = pools.first(where: { $0.pool == "total" })
                    ?? pools.max(by: {
                        ($0.windowS ?? 0) < ($1.windowS ?? 0)
                    })
            } else {
                pool = pools.max(by: {
                    ($0.windowS ?? 0) < ($1.windowS ?? 0)
                })
            }
            guard let pool, !(pool.actual ?? []).isEmpty else { return nil }
            return Series(
                id: provider.id,
                providerID: provider.id,
                title: provider.displayTitle,
                pool: pool,
                renewsAt: pool.windowEnd
            )
        }
    }

    private func points(_ pairs: [[Double]]) -> [Point] {
        pairs.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return Point(
                time: pair[0],
                remaining: max(0, min(pair[1], 100))
            )
        }
    }

    var body: some View {
        let all = series
        if all.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(HeadroomCopy.overallBurndown)
                    .font(.headline)
                Text(HeadroomCopy.noHistoryYet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 14)
            }
            .cardStyle()
        } else {
            let now = all.compactMap { $0.pool.actual?.last?[0] }.max()
                ?? Date().timeIntervalSince1970
            let domain = OverallBurndownChartMath.domain(
                now: Date(timeIntervalSince1970: now)
            )
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(HeadroomCopy.overallBurndown)
                        .font(.headline)
                    Spacer()
                    Text(HeadroomCopy.overallBurndownSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Canvas { context, size in
                    let plot = burndownPlotRect(in: size, axis: true)
                    let span = domain.endEpoch - domain.startEpoch
                    guard span > 0 else { return }
                    func x(_ time: Double) -> CGFloat {
                        plot.minX
                            + CGFloat((time - domain.startEpoch) / span)
                            * plot.width
                    }
                    func y(_ remaining: Double) -> CGFloat {
                        plot.maxY
                            - CGFloat(remaining / 100) * plot.height
                    }

                    drawBurndownScale(&context, plot: plot)
                    drawBurndownCalendar(
                        &context, plot: plot,
                        start: domain.startEpoch,
                        end: domain.endEpoch,
                        now: domain.nowEpoch)

                    var nowMarker = Path()
                    nowMarker.move(to: CGPoint(
                        x: x(domain.nowEpoch), y: plot.minY))
                    nowMarker.addLine(to: CGPoint(
                        x: x(domain.nowEpoch), y: plot.maxY))
                    context.stroke(
                        nowMarker,
                        with: .color(.secondary.opacity(0.4)),
                        lineWidth: 1
                    )

                    for entry in all {
                        let tint = entry.pool.kind == .exhausted
                            ? snapshot.tint(forProviderID: entry.providerID)
                                .drained()
                            : snapshot.tint(forProviderID: entry.providerID)

                        let actual = points(
                            OverallBurndownChartMath.preparedActual(
                                entry.pool.actual, domain: domain
                            )
                        ).map {
                            CGPoint(x: x($0.time), y: y($0.remaining))
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

                        let projectedPairs =
                            OverallBurndownChartMath.preparedProjection(
                                entry.pool.projected,
                                windowEnd: entry.pool.windowEnd,
                                domain: domain
                            )
                        let projected = points(projectedPairs).map {
                            CGPoint(x: x($0.time), y: y($0.remaining))
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
                            if let hit = projected.last {
                                let exhausted =
                                    (projectedPairs.last?[1] ?? 1) <= 0
                                let size: CGFloat = exhausted ? 6 : 4
                                let dot = Path(ellipseIn: CGRect(
                                    x: hit.x - size / 2,
                                    y: hit.y - size / 2,
                                    width: size, height: size))
                                context.fill(
                                    dot, with: .color(tint.opacity(0.85)))
                            }
                        }

                        // Accent dotted reset on top of the strokes.
                        if let renew = entry.renewsAt,
                           renew > domain.nowEpoch,
                           renew >= domain.startEpoch,
                           renew <= domain.endEpoch {
                            var renewMarker = Path()
                            renewMarker.move(to: CGPoint(
                                x: x(renew), y: plot.minY))
                            renewMarker.addLine(to: CGPoint(
                                x: x(renew), y: plot.maxY))
                            context.stroke(
                                renewMarker,
                                with: .color(tint),
                                style: StrokeStyle(
                                    lineWidth: 1.5, dash: [1.5, 2.5])
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
                                          ? snapshot.tint(
                                              forProviderID: entry.providerID
                                          ).drained()
                                          : snapshot.tint(
                                              forProviderID: entry.providerID
                                          ))
                                    .frame(width: 7, height: 7)
                                Text(entry.title)
                                    .font(.caption2.weight(.medium))
                            }
                            if let resets = entry.pool.resetsIn {
                                Text(HeadroomCopy.resets(resets))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.pool.verdict
                                  ?? HeadroomCopy.collectingHistory)
                                .font(.caption2)
                                .monospacedDigit()
                                .lineLimit(2)
                                .foregroundStyle(
                                    entry.pool.kind == .critical
                                        ? AnyShapeStyle(Color.red)
                                        : AnyShapeStyle(.secondary))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .cardStyle()
        }
    }

}

/// The card's answer line: do I make it to the reset, and if not, when.
///
/// It carries no numbers. The stat row underneath already shows what is left
/// and how fast it is going, and a verdict that repeated them is how this card
/// grew into a paragraph with the actionable half buried at the end.
struct BurndownVerdict: View {
    let pool: Burndown
    let tint: Color

    /// Colour only where colour is information. Running out and being spent
    /// change the tint; burning ahead of budget does not, because the gap
    /// between the curve and the budget line already shows it.
    private var textTint: Color {
        switch pool.kind {
        case .critical: .red
        case .exhausted: .secondary
        default: pool.hasForecast ? .primary : .secondary
        }
    }

    private var dotTint: Color {
        switch pool.kind {
        case .critical: .red
        case .exhausted: .secondary
        default: pool.hasForecast ? tint : .secondary
        }
    }

    var body: some View {
        if let verdict = pool.verdict {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotTint)
                    .frame(width: 6, height: 6)
                Text(verdict)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(textTint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }
}

/// Left / Burning / Budget, as three labelled cells.
///
/// The whole question this card answers is whether burning exceeds budget.
/// Side by side in the same unit that is one glance; split across a sentence
/// and a footnote, as it used to be, it is two readings and a subtraction.
struct BurndownStats: View {
    let pool: Burndown

    private var unit: String { pool.rateUnit ?? "day" }

    private func rate(_ value: Double?) -> String? {
        value.map { "\($0.rateLabel)%/\(unit)" }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            cell("Left", pool.remainingPct.map {
                "\(Int($0.rounded()))%"
            }, dimmed: pool.kind == .exhausted)
            // An estimate off token history is worth marking; a measured rate
            // should not be hedged.
            cell(pool.isEstimated ? "Burning · est" : "Burning",
                 rate(pool.burnRatePct),
                 hot: pool.kind == .critical)
            cell("Budget", rate(pool.allowancePct),
                 dimmed: pool.kind == .exhausted)
        }
        .padding(.top, 7)
        .overlay(alignment: .top) {
            Divider().opacity(0.5)
        }
    }

    @ViewBuilder
    private func cell(_ label: String, _ value: String?,
                      hot: Bool = false, dimmed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.tertiary)
            // An absent number reads as "not yet", never as zero.
            Text(value ?? "—")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(value == nil || dimmed ? AnyShapeStyle(.secondary)
                                 : hot ? AnyShapeStyle(Color.red)
                                 : AnyShapeStyle(.primary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Two (or more) pools on one axis — Cursor Total + API share a billing cycle.
struct MultiBurndownPlot: View {
    let pools: [Burndown]
    let tint: Color

    /// The pool the shared axis belongs to. Cursor's pools are one billing
    /// cycle, but each holds its own reset, so spanning min-start to max-end
    /// would draw the budget diagonal across a window none of them has and
    /// leave the caption describing a different one.
    private var anchor: Burndown? {
        pools.first(where: { $0.pool == "total" }) ?? pools.first
    }

    private var window: (start: Double, end: Double, reset: String?)? {
        guard let anchor,
              let start = anchor.windowStart,
              let end = anchor.windowEnd,
              end > start
        else { return nil }
        return (start, end, anchor.resetsIn)
    }

    private var headline: String? { anchor?.headline }

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

            if let anchor {
                BurndownVerdict(pool: anchor, tint: tint)
                BurndownStats(pool: anchor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline ?? HeadroomCopy.burndown)
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

    /// Sample count is a confidence signal, not a user fact, so it lives in
    /// the tooltip rather than taking a line under the chart.
    private var help: String {
        guard let samples = pool.samples else { return pool.headline ?? "" }
        let counted = "\(samples) sample\(samples == 1 ? "" : "s") this window"
        return pool.isEstimated
            ? "\(counted). Rate estimated from recent token usage."
            : counted
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

            BurndownVerdict(pool: pool, tint: statusTint)
            BurndownStats(pool: pool)
        }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pool.headline ?? HeadroomCopy.burndown)
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
        .accessibilityLabel(pool.headline ?? HeadroomCopy.burndown)
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
                let projected = (pool.croppedProjected).compactMap { pair -> CGPoint? in
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
                            lineWidth: 1.5,
                            dash: [6, 2]
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
