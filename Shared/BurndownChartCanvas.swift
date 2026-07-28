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
func burndownPlotRect(
    in size: CGSize,
    axis: Bool,
    gutter: CGFloat = burndownGutter
) -> CGRect {
    let reserved = burndownEdgeInset * 2 + (axis ? burndownAxisHeight : 0)
    return CGRect(
        x: gutter,
        y: burndownEdgeInset,
        width: max(0, size.width - gutter),
        height: max(0, size.height - reserved)
    )
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
func drawBurndownCalendar(
    _ context: inout GraphicsContext,
    plot: CGRect,
    start: Double,
    end: Double,
    now: Double
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
