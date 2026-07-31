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
/// 2. **Domain** is a fixed local calendar week: today−3 … today+4. Upcoming
///    resets that fall inside still paint (dotted rule); farther ones stay
///    off-canvas so the axis never stretches and compresses history.
/// 3. **Clip** strokes to that domain with edge interpolation — `chartXScale`
///    alone still paints past the plot into the gutter.
enum OverallBurndownChartMath {
    static let lookbackDays = 3
    static let spanDays = 7

    struct Domain: Equatable, Sendable {
        var start: Date
        var end: Date
        var now: Date

        var startEpoch: Double { start.timeIntervalSince1970 }
        var endEpoch: Double { end.timeIntervalSince1970 }
        var nowEpoch: Double { now.timeIntervalSince1970 }
    }

    /// Fixed calendar week for the overview chart (today−3 … today+4).
    static func domain(
        now: Date,
        calendar: Calendar = .current
    ) -> Domain {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(
            byAdding: .day, value: -lookbackDays, to: today
        ) ?? today
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
            for edge in [from, to] where out.last?.t != edge {
                out.append(between(a, b, at: edge))
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

    /// Split a cross-window series into runs that never span a reset.
    ///
    /// `history` climbs at every boundary — a reset is a vertical jump *upward*
    /// in remaining percent. Stroked as one polyline, that jump draws a
    /// diagonal joining two budgets which never coexisted, and a burndown that
    /// rises reads as a bug. Cutting at the reset instants leaves one falling
    /// run per window, which is what actually happened.
    ///
    /// Runs shorter than two points are dropped: a single sample has no line to
    /// draw, and keeping it would put a lone dot where a window used to be.
    static func historySegments(
        _ pairs: [[Double]]?,
        splitAt resets: [Double]
    ) -> [[[Double]]] {
        let points = (pairs ?? [])
            .filter { $0.count >= 2 }
            .sorted { $0[0] < $1[0] }
        guard !points.isEmpty else { return [] }

        let cuts = resets.sorted()
        var segments: [[[Double]]] = []
        var current: [[Double]] = []
        var cutIndex = 0
        for point in points {
            while cutIndex < cuts.count && cuts[cutIndex] <= point[0] {
                if current.count >= 2 { segments.append(current) }
                current = []
                cutIndex += 1
            }
            current.append(point)
        }
        if current.count >= 2 { segments.append(current) }
        return segments
    }

    /// `historySegments` clipped to a chart domain, ready to stroke.
    static func preparedHistory(
        _ pairs: [[Double]]?,
        splitAt resets: [Double],
        domain: Domain
    ) -> [[[Double]]] {
        historySegments(pairs, splitAt: resets)
            .map {
                clipPolyline(
                    $0, start: domain.startEpoch, end: domain.endEpoch
                )
            }
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
        var lo = now - TimeInterval(OverallBurndownChartMath.lookbackDays)
            * daySeconds
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
