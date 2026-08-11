import Foundation

// Burndown chart geometry, shared by macOS, iOS, and the widget extension.
//
// It lives apart from `HeadroomModels.swift` because the widget target draws
// the overview chart without compiling the model layer — the same reason
// `HeadroomPalette` is its own file.

/// Shared overall-burndown domain and polyline clip.
///
/// Three layers, applied in order:
/// 1. **Crop** the forecast at the held reset and at 0% (`cropProjection`).
/// 2. **Domain** is a fixed local calendar week: today−3.5d … today+3.5d. Upcoming
///    resets that fall inside still paint (dotted rule); farther ones stay
///    off-canvas so the axis never stretches and compresses history.
/// 3. **Clip** strokes to that domain with edge interpolation — `chartXScale`
///    alone still paints past the plot into the gutter.
///
/// This is the **clock-anchored** frame, and it is the only one available to
/// the overview: provider windows open and reset at different times, so there
/// is no single window to hang an axis on — which is also why this chart has
/// no budget diagonal. `BurndownChartAxis` is the **reset-anchored** frame for
/// a single pool. Two rules, two answers to two questions; every surface says
/// which one it is drawing (`frameLabel`) so the pair never reads as drift.
enum OverallBurndownChartMath {
    /// Whole calendar days of history in the frame, plus the half-day history
    /// extension below.
    ///
    /// The domain starts three days before today's midnight, reaches back a
    /// further half-day, and covers three and a half days either side — seven days,
    /// symmetric about today. `HeadroomCopy.overallBurndownSubtitle` says that
    /// in words; change one and change the other.
    static let lookbackDays = 3
    static let extraHistorySeconds: TimeInterval = 12 * 60 * 60
    static let spanDays = 7

    struct Domain: Equatable, Sendable {
        var start: Date
        var end: Date
        var now: Date

        var startEpoch: Double { start.timeIntervalSince1970 }
        var endEpoch: Double { end.timeIntervalSince1970 }
        var nowEpoch: Double { now.timeIntervalSince1970 }

        /// What the X-axis covers, for the subtitle beside the chart's title.
        /// Always the same words here — this frame does not vary.
        var frameLabel: String { HeadroomCopy.overallBurndownSubtitle }
    }

    /// Fixed seven-day overview frame, with three and a half days of history
    /// before today's midnight and three and a half days after it.
    static func domain(
        now: Date,
        calendar: Calendar = .current
    ) -> Domain {
        let today = calendar.startOfDay(for: now)
        let dayStart = calendar.date(
            byAdding: .day, value: -lookbackDays, to: today
        ) ?? today
        let start = dayStart.addingTimeInterval(-extraHistorySeconds)
        let end = calendar.date(
            byAdding: .day, value: spanDays, to: start
        ) ?? start.addingTimeInterval(
            TimeInterval(spanDays) * 24 * 60 * 60
        )
        // Degenerate guard: never invert, never zero-width.
        let safeEnd = end > start
            ? end
            : start.addingTimeInterval(24 * 60 * 60)
        return Domain(start: start, end: safeEnd, now: now)
    }

    /// The most recent sample time in a compact `[[t, remaining], …]` series.
    ///
    /// Every surface that anchors a domain to data rather than to the wall
    /// clock asks this. It reads the pairs rather than the last row because a
    /// row is only a sample when it has both numbers: the series arrives from
    /// the host on one path and from a cache another build wrote on the other,
    /// and `rows.last![0]` on a short row is a crash — which in a widget
    /// extension is not a wrong number, it is a blank box with nothing to say
    /// why. A malformed row costs that sample and nothing else.
    static func latestSampleTime(_ pairs: [[Double]]?) -> Double? {
        pairs?.compactMap { $0.count >= 2 ? $0[0] : nil }.max()
    }

    /// Clip [[t, remaining], …] to `[start, end]`, interpolating at the edges.
    static func clipPolyline(
        _ pairs: [[Double]],
        start: Double,
        end: Double
    ) -> [[Double]] {
        guard end > start else { return [] }
        let points: [(t: Double, r: Double)] = pairs.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return (pair[0], min(100, max(0, pair[1])))
        }
        guard points.count >= 2 else {
            return points
                .filter { $0.t >= start && $0.t <= end }
                .map { [$0.t, $0.r] }
        }

        func between(
            _ a: (t: Double, r: Double),
            _ b: (t: Double, r: Double),
            at t: Double
        ) -> (t: Double, r: Double) {
            let span = b.t - a.t
            guard span > 0 else { return (t, b.r) }
            let ratio = (t - a.t) / span
            return (t, min(100, max(0, a.r + ratio * (b.r - a.r))))
        }

        var out: [(t: Double, r: Double)] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let from = max(a.t, start)
            let to = min(b.t, end)
            guard from <= to else { continue }
            for edge in [from, to] {
                let candidate = between(a, b, at: edge)
                // Deduped on the whole point, not on time alone. A reset riser
                // is two samples sharing one instant, and dropping either
                // because "we already have that x" flattens the climb the
                // chart exists to show.
                if let last = out.last,
                   last.t == candidate.t, last.r == candidate.r {
                    continue
                }
                out.append(candidate)
            }
        }
        return out.map { [$0.t, $0.r] }
    }

    /// Crop at reset/empty, then clip to the chart domain — the full pipeline
    /// for an overview forecast stroke.
    static func preparedProjection(
        _ pairs: [[Double]]?,
        windowEnd: Double?,
        domain: Domain
    ) -> [[Double]] {
        clipPolyline(
            cropProjection(pairs, windowEnd: windowEnd),
            start: domain.startEpoch,
            end: domain.endEpoch
        )
    }

    /// Granted-reset marks inside the domain, oldest first.
    ///
    /// Takes bare epochs rather than the model type so this file stays free of
    /// the model layer, which is what lets the widget target draw the same
    /// chart. Callers pass `pool.resets?.compactMap(\.t)`.
    static func preparedResets(
        _ times: [Double]?,
        domain: Domain
    ) -> [Double] {
        (times ?? [])
            .filter { $0 >= domain.startEpoch && $0 <= domain.endEpoch }
            .sorted()
    }

    /// Known future events that have entered the overview's visible week.
    ///
    /// Kept separate from `preparedResets`: granted resets are history and may
    /// sit left of now, while deadlines such as banked-credit expiries should
    /// disappear as soon as they pass.
    static func preparedUpcomingEvents(
        _ times: [Double]?,
        domain: Domain
    ) -> [Double] {
        Set(times ?? [])
            .filter { $0 > domain.nowEpoch && $0 <= domain.endEpoch }
            .sorted()
    }

    /// Clip actual samples to the chart domain.
    static func preparedActual(
        _ pairs: [[Double]]?,
        domain: Domain
    ) -> [[Double]] {
        clipPolyline(
            pairs ?? [],
            start: domain.startEpoch,
            end: domain.endEpoch
        )
    }

    /// A cross-window series as one polyline, with the recharge drawn.
    ///
    /// `history` climbs at every boundary, because a reset *is* a jump upward in
    /// remaining percent. That climb is the point: the moment the pool came back
    /// is the most legible thing on the chart, and hiding it leaves a curve that
    /// ends at nothing and restarts at full with no visible cause.
    ///
    /// The samples either side of a boundary are a bucket apart, so joining them
    /// raw draws a steep diagonal that reads as an implausibly fast refill. This
    /// squares it off instead: at each known reset the line runs level to the
    /// reset instant, rises vertically there, and carries on. The rise lands on
    /// the same x as the rule the chart already draws, so the two agree.
    ///
    /// Boundaries the host did not flag as grants still show their climb — the
    /// diagonal is simply not squared off, which is the honest rendering when
    /// nothing pinned the instant.
    static func historyPolyline(
        _ pairs: [[Double]]?,
        risersAt resets: [Double]
    ) -> [[Double]] {
        let points = (pairs ?? [])
            .filter { $0.count >= 2 }
            .sorted { $0[0] < $1[0] }
        guard points.count >= 2 else { return points }

        let cuts = resets.sorted()
        var out: [[Double]] = [points[0]]
        for (previous, point) in zip(points, points.dropFirst()) {
            // At most one reset can sit between two adjacent samples; if the
            // host reported several, the last one is the boundary that stuck.
            if let cut = cuts.last(where: { $0 > previous[0] && $0 <= point[0] }) {
                out.append([cut, previous[1]])
                out.append([cut, point[1]])
            }
            out.append(point)
        }
        return out
    }

    /// `historyPolyline` clipped to a chart domain, ready to stroke.
    ///
    /// Returned as an array of runs because clipping can only ever produce one —
    /// the shape callers already draw, kept so a future domain that drops a gap
    /// in the middle does not change every call site.
    static func preparedHistory(
        _ pairs: [[Double]]?,
        splitAt resets: [Double],
        domain: Domain
    ) -> [[[Double]]] {
        [
            clipPolyline(
                historyPolyline(pairs, risersAt: resets),
                start: domain.startEpoch,
                end: domain.endEpoch
            )
        ]
        .filter { $0.count >= 2 }
    }

    static func cropProjection(
        _ pairs: [[Double]]?,
        windowEnd: Double?
    ) -> [[Double]] {
        var points: [(t: Double, r: Double)] = (pairs ?? []).compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return (pair[0], min(100, max(0, pair[1])))
        }
        guard !points.isEmpty else { return [] }

        if let end = windowEnd {
            var cropped: [(t: Double, r: Double)] = []
            for point in points {
                if point.t <= end {
                    cropped.append(point)
                    continue
                }
                if let prev = cropped.last, prev.t < end {
                    let span = point.t - prev.t
                    if span > 0 {
                        let ratio = (end - prev.t) / span
                        let remaining = prev.r + ratio * (point.r - prev.r)
                        cropped.append((end, min(100, max(0, remaining))))
                    }
                }
                break
            }
            points = cropped
        }

        var out: [(t: Double, r: Double)] = []
        for point in points {
            if let prev = out.last, prev.r > 0, point.r <= 0 {
                let span = point.t - prev.t
                let drop = prev.r - point.r
                if span > 0, drop > 0 {
                    out.append((prev.t + span * (prev.r / drop), 0))
                } else {
                    out.append((point.t, 0))
                }
                break
            }
            out.append(point)
            if point.r <= 0 { break }
        }
        return out.map { [$0.t, $0.r] }
    }
}

/// Shared X-axis furniture for per-provider burndown charts (Mac / iOS / ESP32).
///
/// Multi-day windows get at most seven weekday-named columns — never
/// day-of-month numbers, never an eighth clipped midnight. Windows longer
/// than a week are clipped to seven days covering `now` inside the pool.
/// Sub-day sessions keep their own window and get hour marks instead of a
/// blank axis.
enum BurndownChartAxis {
    static let maxDays = 7
    static let daySeconds: TimeInterval = 24 * 60 * 60
    /// Where the moving slice starts inside a window too long to draw whole.
    ///
    /// Its own number, not `OverallBurndownChartMath.lookbackDays`, though the
    /// two currently agree. One centres a fixed week on today; this one places
    /// a seven-day slice inside a month and is then clamped by the window's
    /// edges, so it is not symmetric about today and the copy must not claim
    /// it is. Sharing the constant meant a change to the overview silently
    /// moved every monthly chart.
    static let sliceLookbackDays = 3
    /// Below this, weekday columns don't apply (session windows).
    static let dayAxisMinSpan: TimeInterval = 2 * daySeconds
    /// How far a plot may reach back past its own window to show the burn a
    /// grant wiped out, as a fraction of the window.
    ///
    /// A stub, deliberately. The window is what this chart is about — it is
    /// where the budget line lives and where the reset sits — so history gets
    /// only enough room to show the drop that preceded the grant. Scaling by
    /// the window keeps that true at both ends of the range: about a day
    /// before a weekly reset, about forty minutes before a session one.
    /// Wide enough to read, narrow enough that `dayColumns` still settles on
    /// seven weekday names.
    static let historyFraction = 0.15

    struct Domain: Equatable, Sendable {
        var start: Date
        var end: Date
        /// Full pool window — budget diagonal is relative to this, not the plot.
        var windowStart: Date
        var windowEnd: Date

        var startEpoch: Double { start.timeIntervalSince1970 }
        var endEpoch: Double { end.timeIntervalSince1970 }
        var windowStartEpoch: Double { windowStart.timeIntervalSince1970 }
        var windowEndEpoch: Double { windowEnd.timeIntervalSince1970 }
        var showsDayAxis: Bool {
            endEpoch - startEpoch >= dayAxisMinSpan
        }

        /// Whether the plot spans the pool's whole window.
        ///
        /// True for session, daily and weekly pools; false for a monthly one,
        /// where the plot is a seven-day slice inside the window and the
        /// budget diagonal runs off both edges. Derived rather than stored so
        /// it cannot disagree with the domain `domain(…)` actually returned.
        var showsWholeWindow: Bool {
            startEpoch <= windowStartEpoch && endEpoch >= windowEndEpoch
        }

        /// What the X-axis covers, for the subtitle beside the chart's title.
        /// The counterpart to `OverallBurndownChartMath.Domain.frameLabel`:
        /// the two rules are told apart here, in words, exactly once.
        var frameLabel: String {
            showsWholeWindow
                ? HeadroomCopy.windowFrame
                : HeadroomCopy.windowSliceFrame
        }
    }

    /// Plot domain for a provider burndown: the pool window, capped at 7 days.
    ///
    /// `historyStart` is the oldest pre-window sample worth drawing — the
    /// first point of `forgiven`. The plot reaches back toward it by at most
    /// `historyFraction` of the window, so a granted reset shows what it wiped
    /// out without the new window losing its reset off the right edge. The
    /// budget diagonal is unaffected: `windowStart` / `windowEnd` still
    /// describe the window, which is why the two are separate fields.
    static func domain(
        windowStart: Double,
        windowEnd: Double,
        now: Double = Date().timeIntervalSince1970,
        historyStart: Double? = nil
    ) -> Domain? {
        guard windowEnd > windowStart else { return nil }
        let winStart = Date(timeIntervalSince1970: windowStart)
        let winEnd = Date(timeIntervalSince1970: windowEnd)
        let span = windowEnd - windowStart
        let week = TimeInterval(maxDays) * daySeconds
        if span <= week + 3600 {
            let floor = windowStart - span * historyFraction
            let reach = historyStart.map { max($0, floor) } ?? windowStart
            return Domain(
                start: Date(timeIntervalSince1970: min(reach, windowStart)),
                end: winEnd,
                windowStart: winStart, windowEnd: winEnd
            )
        }
        // Monthly+: seven days covering now, clamped inside the window.
        var lo = now - TimeInterval(sliceLookbackDays) * daySeconds
        var hi = lo + week
        if lo < windowStart {
            lo = windowStart
            hi = lo + week
        }
        if hi > windowEnd {
            hi = windowEnd
            lo = max(windowStart, hi - week)
        }
        return Domain(
            start: Date(timeIntervalSince1970: lo),
            end: Date(timeIntervalSince1970: hi),
            windowStart: winStart,
            windowEnd: winEnd
        )
    }

    /// One labelled band per weekday, clamped to the plot domain.
    ///
    /// A pool that resets mid-day covers eight calendar days in seven days of
    /// wall clock, so the two edge bands are part-days. Both get dropped down
    /// to seven by discarding the narrower edge and letting its sliver fall
    /// into the neighbouring band — that is what keeps the axis at exactly
    /// seven names instead of an eighth clipped label.
    struct DayColumn: Equatable, Sendable, Identifiable {
        /// Clamped band edges, inside the plot domain.
        var start: Date
        var end: Date

        var id: Double { start.timeIntervalSince1970 }
        /// Where the weekday name is centred. Always inside the band, so
        /// formatting it as a weekday names the right day.
        var mid: Date {
            Date(
                timeIntervalSince1970:
                    (start.timeIntervalSince1970 + end.timeIntervalSince1970) / 2
            )
        }
    }

    /// At most seven weekday bands — never day-of-month numbers.
    static func dayColumns(
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> [DayColumn] {
        guard end.timeIntervalSince(start) >= dayAxisMinSpan else { return [] }
        var edges: [Date] = []
        var day = calendar.startOfDay(for: start)
        // Guard against a runaway calendar; a clipped domain is ≤ 7 days.
        while day < end && edges.count <= maxDays + 2 {
            edges.append(max(day, start))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { break }
            day = next
        }
        guard !edges.isEmpty else { return [] }

        var columns: [DayColumn] = edges.indices.map { index in
            DayColumn(
                start: edges[index],
                end: index + 1 < edges.count ? edges[index + 1] : end
            )
        }
        // Trim to seven from whichever end holds the thinner part-day.
        while columns.count > maxDays {
            let firstSpan = columns[0].end.timeIntervalSince(columns[0].start)
            let last = columns[columns.count - 1]
            let lastSpan = last.end.timeIntervalSince(last.start)
            if firstSpan < lastSpan {
                let dropped = columns.removeFirst()
                columns[0].start = dropped.start
            } else {
                let dropped = columns.removeLast()
                columns[columns.count - 1].end = dropped.end
            }
        }
        return columns
    }

    /// Midnight rules for the day bands, skipping the domain's leading edge
    /// (which the plot frame already draws).
    static func dayGridLines(
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        dayColumns(start: start, end: end, calendar: calendar)
            .map(\.start)
            .filter { $0 > start }
    }


    /// Hour ticks for session-scale windows so the axis is never blank.
    static func hourMarks(
        start: Date,
        end: Date,
        calendar: Calendar = .current
    ) -> [Date] {
        guard end > start else { return [] }
        var hour = calendar.date(
            from: calendar.dateComponents(
                [.year, .month, .day, .hour], from: start
            )
        ) ?? start
        if hour < start {
            hour = calendar.date(byAdding: .hour, value: 1, to: hour) ?? hour
        }
        var marks: [Date] = []
        while hour < end && marks.count < 12 {
            marks.append(hour)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour)
            else { break }
            hour = next
        }
        return marks
    }
}
