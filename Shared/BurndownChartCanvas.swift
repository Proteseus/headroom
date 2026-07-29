import SwiftUI

// Burndown chart furniture — the scale, the weekday bands, the hour ticks.
//
// Day/hour marks come from BurndownChartAxis so Mac, iOS and ESP32 agree:
// ≤7 weekday-named columns, never day-of-month numbers, hours for sessions.
// Shared rather than private to the Mac card because the widget draws the
// same overview chart in a Canvas of its own.

/// Room for the "100%" scale labels. Surfaces too narrow to spend it — the
/// widget — pass `gutter: 0` and drop the labels with it.
let burndownGutter: CGFloat = 30
/// Band under the plot holding the weekday / hour labels.
let burndownAxisHeight: CGFloat = 16
/// Slack above and below the plot so the 100% and 0% labels, which sit centred
/// on the outermost grid lines, are not clipped by the canvas edge.
let burndownEdgeInset: CGFloat = 7

/// Where the series actually gets drawn inside a canvas of `size`.
///
/// `inset` exists for the watch, whose rectangular complication is barely 40pt
/// of chart: the slack that keeps a "100%" label off the canvas edge is most of
/// the plot there, and it has no labels to protect.
func burndownPlotRect(
    in size: CGSize,
    axis: Bool,
    gutter: CGFloat = burndownGutter,
    inset: CGFloat = burndownEdgeInset
) -> CGRect {
    let reserved = inset * 2 + (axis ? burndownAxisHeight : 0)
    return CGRect(
        x: gutter,
        y: inset,
        width: max(0, size.width - gutter),
        height: max(0, size.height - reserved)
    )
}

/// A burndown's plot rect together with the domain it maps, plus the handful of
/// conversions every surface that draws one otherwise rewrites inline.
///
/// Series arrive as compact `[[epoch, remainingPct], …]` pairs; everything here
/// turns those into canvas geometry. Two canvases built from the same size and
/// domain produce the same numbers, which is what lets the watch stack a
/// tinted layer over an untinted one and have the lines register.
struct BurndownGeometry {
    let rect: CGRect
    let domain: OverallBurndownChartMath.Domain

    var isDrawable: Bool {
        rect.width > 0 && rect.height > 0 && domain.endEpoch > domain.startEpoch
    }

    func x(_ time: Double) -> CGFloat {
        let span = domain.endEpoch - domain.startEpoch
        guard span > 0 else { return rect.minX }
        return rect.minX + CGFloat((time - domain.startEpoch) / span) * rect.width
    }

    func y(_ remaining: Double) -> CGFloat {
        rect.maxY - CGFloat(max(0, min(remaining, 100)) / 100) * rect.height
    }

    func point(_ pair: [Double]) -> CGPoint? {
        guard pair.count >= 2 else { return nil }
        return CGPoint(x: x(pair[0]), y: y(pair[1]))
    }

    /// A polyline through the pairs, or nil when fewer than two survive — one
    /// sample is a dot, not a line.
    func line(_ pairs: [[Double]]) -> Path? {
        let points = pairs.compactMap(point)
        guard points.count >= 2 else { return nil }
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    /// A vertical rule across the full plot height — now, and each reset.
    func rule(at time: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x(time), y: rect.minY))
        path.addLine(to: CGPoint(x: x(time), y: rect.maxY))
        return path
    }

    /// A dot centred on a series point: the head of a measured line, or where a
    /// forecast reaches empty.
    func dot(_ pair: [Double], diameter: CGFloat) -> Path? {
        guard let center = point(pair) else { return nil }
        return Path(ellipseIn: CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        ))
    }
}

/// Reference lines at empty, half and full, labelled in the gutter. Three is
/// as many as a chart this short carries before the grid starts competing with
/// the data it is there to measure.
func drawBurndownScale(
    _ context: inout GraphicsContext,
    plot: CGRect,
    labels: Bool = true
) {
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
        guard labels else { continue }
        context.draw(
            Text("\(Int(percent))%")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.7)),
            at: CGPoint(x: plot.minX - 5, y: lineY),
            anchor: .trailing
        )
    }
}

/// Day boundaries as vertical rules, labelled with weekday names (≤7).
///
/// Surfaces with no room for an axis band — the watch's rectangular
/// complication — pass `labels: false` and keep the rules alone, which is
/// enough to read the week's rhythm off a line that is 40pt tall.
func drawBurndownCalendar(
    _ context: inout GraphicsContext,
    plot: CGRect,
    start: Double,
    end: Double,
    now: Double,
    labels: Bool = true
) {
    let columns = BurndownChartAxis.dayColumns(
        start: Date(timeIntervalSince1970: start),
        end: Date(timeIntervalSince1970: end)
    )
    guard !columns.isEmpty, plot.width > 0, end > start else { return }

    func x(_ time: Double) -> CGFloat {
        plot.minX + CGFloat((time - start) / (end - start)) * plot.width
    }

    let labelY = plot.maxY + burndownEdgeInset + burndownAxisHeight / 2

    for column in columns {
        let from = column.start.timeIntervalSince1970
        if from > start {
            var rule = Path()
            rule.move(to: CGPoint(x: x(from), y: plot.minY))
            rule.addLine(to: CGPoint(x: x(from), y: plot.maxY))
            context.stroke(
                rule, with: .color(.secondary.opacity(0.14)), lineWidth: 1)
        }

        guard labels else { continue }
        // Centred in the band, so a part-day column keeps its name.
        context.draw(
            Text(column.mid.formatted(.dateTime.weekday(.abbreviated)))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(
                    Color.secondary.opacity(from <= now ? 1 : 0.55)
                ),
            at: CGPoint(x: x(column.mid.timeIntervalSince1970), y: labelY),
            anchor: .center
        )
    }
}

/// Hour ticks for session-scale windows so the axis is never blank.
func drawBurndownHours(
    _ context: inout GraphicsContext,
    plot: CGRect,
    start: Double,
    end: Double
) {
    let hours = BurndownChartAxis.hourMarks(
        start: Date(timeIntervalSince1970: start),
        end: Date(timeIntervalSince1970: end)
    )
    guard !hours.isEmpty, plot.width > 0, end > start else { return }

    func x(_ time: Double) -> CGFloat {
        plot.minX + CGFloat((time - start) / (end - start)) * plot.width
    }

    let labelY = plot.maxY + burndownEdgeInset + burndownAxisHeight / 2
    for hour in hours {
        let t = hour.timeIntervalSince1970
        if t > start {
            var rule = Path()
            rule.move(to: CGPoint(x: x(t), y: plot.minY))
            rule.addLine(to: CGPoint(x: x(t), y: plot.maxY))
            context.stroke(
                rule, with: .color(.secondary.opacity(0.14)), lineWidth: 1)
        }
        context.draw(
            Text(hour.formatted(.dateTime.hour().minute()))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.secondary),
            at: CGPoint(x: x(t) + 3, y: labelY),
            anchor: .leading
        )
    }
}
