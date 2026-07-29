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
        let resetCreditExpiries: [Double]
        /// Where this provider explains its grants, when it explains them
        /// anywhere. Opened on click; never fetched.
        let resetNoteURL: URL?

        /// Newest grant the chart is actually showing, for the caption that
        /// names the rule.
        func latestReset(
            in domain: OverallBurndownChartMath.Domain
        ) -> BurndownReset? {
            let visible = Set(OverallBurndownChartMath.preparedResets(
                pool.resets?.compactMap(\.t), domain: domain))
            return (pool.resets ?? [])
                .filter { $0.t.map(visible.contains) ?? false }
                .max { ($0.t ?? 0) < ($1.t ?? 0) }
        }

        func nextResetCreditExpiry(
            in domain: OverallBurndownChartMath.Domain
        ) -> Double? {
            OverallBurndownChartMath.preparedUpcomingEvents(
                resetCreditExpiries, domain: domain
            ).first
        }
    }

    /// One pool per provider — `UsageSnapshot.overviewBurndown` makes that
    /// pick, so the phone and the widget draw the same line.
    private var series: [Series] {
        snapshot.visibleQuotaProviders.compactMap { provider in
            let pool = snapshot.overviewBurndown(forProviderID: provider.id)
            guard let pool, !(pool.actual ?? []).isEmpty else { return nil }
            return Series(
                id: provider.id,
                providerID: provider.id,
                title: provider.displayTitle,
                pool: pool,
                renewsAt: pool.windowEnd,
                resetCreditExpiries: provider.id == UsageProvider.codex.rawValue
                    ? snapshot.codex?.resetCreditsExpireAt ?? []
                    : [],
                resetNoteURL: provider.resetNoteURL.flatMap(URL.init(string:))
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

                        // The run a grant wiped out, behind everything else.
                        // Faint and thin: it is history that stopped counting,
                        // and it must never be mistaken for the live curve.
                        let forgiven = points(
                            OverallBurndownChartMath.preparedActual(
                                entry.pool.forgiven, domain: domain
                            )
                        ).map {
                            CGPoint(x: x($0.time), y: y($0.remaining))
                        }
                        if forgiven.count >= 2 {
                            var ghost = Path()
                            ghost.move(to: forgiven[0])
                            for point in forgiven.dropFirst() {
                                ghost.addLine(to: point)
                            }
                            context.stroke(
                                ghost,
                                with: .color(tint.opacity(0.3)),
                                style: StrokeStyle(
                                    lineWidth: 1.5, lineJoin: .round)
                            )
                        }

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

                        // Resets already granted, drawn under the upcoming
                        // one: solid rather than dotted, because this one
                        // happened. Without it the curve just restarts and
                        // the week that was forgiven reads as missing data.
                        for granted in OverallBurndownChartMath.preparedResets(
                            entry.pool.resets?.compactMap(\.t), domain: domain
                        ) {
                            var mark = Path()
                            mark.move(to: CGPoint(x: x(granted), y: plot.minY))
                            mark.addLine(to: CGPoint(
                                x: x(granted), y: plot.maxY))
                            context.stroke(
                                mark,
                                with: .color(tint.opacity(0.55)),
                                lineWidth: 1
                            )
                            let cap = Path(ellipseIn: CGRect(
                                x: x(granted) - 2.5, y: plot.minY - 2.5,
                                width: 5, height: 5))
                            context.fill(cap, with: .color(tint))
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

                        // A banked reset credit does not refill the pool by
                        // itself. Its expiry is a deadline, so use a longer
                        // dash and a pointed cap rather than a reset dot.
                        for expiry in
                            OverallBurndownChartMath.preparedUpcomingEvents(
                                entry.resetCreditExpiries, domain: domain
                            ) {
                            var expiryMarker = Path()
                            expiryMarker.move(to: CGPoint(
                                x: x(expiry), y: plot.minY))
                            expiryMarker.addLine(to: CGPoint(
                                x: x(expiry), y: plot.maxY))
                            context.stroke(
                                expiryMarker,
                                with: .color(tint.opacity(0.7)),
                                style: StrokeStyle(
                                    lineWidth: 1.25, dash: [5, 3])
                            )
                            var cap = Path()
                            cap.move(to: CGPoint(
                                x: x(expiry) - 3, y: plot.minY - 3))
                            cap.addLine(to: CGPoint(
                                x: x(expiry) + 3, y: plot.minY - 3))
                            cap.addLine(to: CGPoint(
                                x: x(expiry), y: plot.minY + 2))
                            cap.closeSubpath()
                            context.fill(cap, with: .color(tint))
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
                            // Legend verdicts stay secondary whatever they
                            // say — see BurndownVerdict.textTint.
                            Text(entry.pool.verdict
                                  ?? HeadroomCopy.collectingHistory)
                                .font(.caption2)
                                .monospacedDigit()
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                            // Names the solid rule on the chart. Only the
                            // newest grant: two lines of history would push
                            // the verdict, which is the actionable one, off
                            // the bottom of the legend.
                            if let granted = entry.latestReset(in: domain) {
                                let caption = HeadroomCopy.resetGranted(
                                    forgivenPct: granted.forgivenPct)
                                // A link only where the provider actually
                                // announces its grants somewhere. Opening it
                                // is the whole integration — Headroom never
                                // reads that page, so nothing here can break
                                // when it changes.
                                if let note = entry.resetNoteURL {
                                    Link(caption, destination: note)
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                } else {
                                    Text(caption)
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            if let expiry = entry.nextResetCreditExpiry(
                                in: domain
                            ) {
                                Text(HeadroomCopy.resetCreditExpires(
                                    Date(timeIntervalSince1970: expiry)
                                        .formatted(
                                            .dateTime
                                                .weekday(.abbreviated)
                                                .hour()
                                                .minute()
                                        )
                                ))
                                .font(.caption2)
                                .monospacedDigit()
                                .lineLimit(1)
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
    /// No alarm colour here. See `BurndownPlot.statusTint` — running out is a
    /// reading the words already deliver ("Runs out tomorrow 04:18"); painting
    /// it red says it a second time, louder. Only exhaustion shifts the
    /// colour, and it recedes rather than warns.
    private var textTint: Color {
        switch pool.kind {
        case .exhausted: .secondary
        default: pool.hasForecast ? .primary : .secondary
        }
    }

    private var dotTint: Color {
        switch pool.kind {
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
            // Burning is a measurement, not an alarm. Whether it exceeds
            // Budget is visible in the cell beside it — colouring it red
            // editorialises a number the user can compare themselves.
            cell(pool.isEstimated ? "Burning · est" : "Burning",
                 rate(pool.burnRatePct))
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
                      dimmed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.tertiary)
            // An absent number reads as "not yet", never as zero.
            Text(value ?? "—")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(value == nil || dimmed
                                 ? AnyShapeStyle(.secondary)
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
            let sampleTimes = pools.flatMap { pool in
                (pool.actual ?? []).compactMap { pair -> Double? in
                    pair.count >= 2 ? pair[0] : nil
                }
            }
            let now = sampleTimes.max() ?? Date().timeIntervalSince1970
            // Oldest forgiven sample across the overlaid pools. The domain
            // only reaches back toward it — see `historyFraction`.
            let historyStart = pools
                .compactMap { $0.forgiven?.first?.first }
                .min()
            guard let domain = BurndownChartAxis.domain(
                windowStart: start, windowEnd: end, now: now,
                historyStart: historyStart
            ) else { return }

            let plotStart = domain.startEpoch
            let plotEnd = domain.endEpoch
            let winStart = domain.windowStartEpoch
            let winEnd = domain.windowEndEpoch
            let plotSpan = plotEnd - plotStart
            let winSpan = winEnd - winStart
            guard plotSpan > 0, winSpan > 0 else { return }

            let showAxis = true  // days or hours — never a blank band
            let plot = burndownPlotRect(in: size, axis: showAxis)
            func x(_ t: Double) -> CGFloat {
                plot.minX + CGFloat((t - plotStart) / plotSpan) * plot.width
            }
            func y(_ pct: Double) -> CGFloat {
                plot.maxY
                    - CGFloat(max(0, min(pct, 100)) / 100) * plot.height
            }
            /// Budget height from the *full* pool window, not the clipped plot.
            func budget(_ t: Double) -> Double {
                100 * (1 - (t - winStart) / winSpan)
            }

            drawBurndownScale(&context, plot: plot)
            if domain.showsDayAxis {
                drawBurndownCalendar(
                    &context, plot: plot, start: plotStart, end: plotEnd,
                    now: now)
            } else {
                drawBurndownHours(
                    &context, plot: plot, start: plotStart, end: plotEnd)
            }

            // Budget diagonal clipped to the plot — uses full-window %.
            let b0 = max(plotStart, winStart)
            let b1 = min(plotEnd, winEnd)
            if b1 > b0 {
                var ideal = Path()
                ideal.move(to: CGPoint(x: x(b0), y: y(budget(b0))))
                ideal.addLine(to: CGPoint(x: x(b1), y: y(budget(b1))))
                context.stroke(
                    ideal,
                    with: .color(.secondary.opacity(0.45)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )
            }

            let ordered = pools.sorted {
                ($0.pool == "api" ? 0 : 1) < ($1.pool == "api" ? 0 : 1)
            }

            var nowX: CGFloat?
            for pool in ordered {
                let base = pool.kind == .exhausted ? tint.drained() : tint
                let isApi = pool.pool == "api"
                let seriesTint = isApi ? base.opacity(0.75) : base

                // The burn a grant wiped out, in the stub of plot that sits
                // before the window. Faint, and never fitted or measured
                // against the budget line — that budget no longer exists.
                let ghost = OverallBurndownChartMath.clipPolyline(
                    pool.forgiven ?? [], start: plotStart, end: plotEnd
                ).map { CGPoint(x: x($0[0]), y: y($0[1])) }
                if ghost.count >= 2 {
                    var path = Path()
                    path.move(to: ghost[0])
                    for point in ghost.dropFirst() { path.addLine(to: point) }
                    context.stroke(
                        path,
                        with: .color(seriesTint.opacity(0.3)),
                        style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
                    )
                }
                for granted in OverallBurndownChartMath.preparedResets(
                    pool.resets?.compactMap(\.t),
                    domain: OverallBurndownChartMath.Domain(
                        start: Date(timeIntervalSince1970: plotStart),
                        end: Date(timeIntervalSince1970: plotEnd),
                        now: Date(timeIntervalSince1970: now)
                    )
                ) {
                    var mark = Path()
                    mark.move(to: CGPoint(x: x(granted), y: plot.minY))
                    mark.addLine(to: CGPoint(x: x(granted), y: plot.maxY))
                    context.stroke(
                        mark,
                        with: .color(seriesTint.opacity(0.55)),
                        lineWidth: 1
                    )
                }

                let clippedActual = OverallBurndownChartMath.clipPolyline(
                    pool.actual ?? [], start: plotStart, end: plotEnd
                )
                let samples = clippedActual.map { $0[0] }
                let actual = clippedActual.map {
                    CGPoint(x: x($0[0]), y: y($0[1]))
                }

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

                let projected = OverallBurndownChartMath.clipPolyline(
                    pool.croppedProjected, start: plotStart, end: plotEnd
                ).map { CGPoint(x: x($0[0]), y: y($0[1])) }
                if projected.count >= 2 {
                    var forecast = Path()
                    forecast.move(to: projected[0])
                    for point in projected.dropFirst() { forecast.addLine(to: point) }
                    context.stroke(
                        forecast,
                        with: .color(seriesTint),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 2])
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
