import SwiftUI

/// The wide rundown, redrawn for a wrist.
///
/// The Mac's `OverviewBurndownCard` and the medium widget draw the same week
/// with a percent gutter, a labelled weekday axis, a legend, and every source
/// in its own brand colour. Most of that does not survive at roughly 160×72
/// points, but the colour does: `.widgetAccentable(false)` opts the chart out
/// of the face's tint, so each source keeps the hue it wears everywhere else.
///
/// What that leaves is a deliberate reduction rather than a shrunk copy:
///
///   * **No text at all.** The chart takes the whole tile. The percent and the
///     deadline it used to carry are the same sentence the inline and corner
///     families already say, and repeating them cost a fifth of the height
///     that makes the line readable.
///   * **The binding source's line is the only thick one.** The rest keep full
///     colour as context — same as the board — and separate by weight, not by
///     fading out.
///   * **The axis goes, the rhythm stays.** Day boundaries keep their rules and
///     lose their labels; the scale keeps its three lines and loses "100%".
///
/// One canvas, because colour separates the sources and there is no tint group
/// to keep the lead line out of.
struct WatchRundownChart: View {
    let snapshot: HeadroomWidgetSnapshot

    private var charted: [HeadroomWidgetSnapshot.Provider] { snapshot.charted }
    private var lead: HeadroomWidgetSnapshot.Provider? {
        snapshot.bindingProvider.flatMap { binding in
            charted.first { $0.id == binding.id }
        } ?? charted.first
    }

    var body: some View {
        Canvas { context, size in
            guard let plot = Self.plot(in: size) else { return }
            Self.drawFurniture(&context, plot: plot)
            // Context lines first so the named source draws over them.
            for provider in charted where provider.id != lead?.id {
                Self.draw(provider, in: &context, plot: plot, leading: false)
            }
            if let lead {
                Self.draw(lead, in: &context, plot: plot, leading: true)
            }
        }
        .widgetAccentable(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let sources = charted
            .map { "\($0.title) \(HeadroomCopy.percentLeft(100 - $0.percent))" }
            .joined(separator: ", ")
        return "\(HeadroomCopy.overallBurndown), \(HeadroomCopy.overallBurndownSubtitle). \(sources)"
    }

    // MARK: Drawing

    /// A tight inset — the slack that keeps scale labels off the canvas edge is
    /// most of the plot at this height, and there are no labels to protect.
    private static func plot(in size: CGSize) -> BurndownGeometry? {
        let plot = BurndownGeometry(
            rect: burndownPlotRect(in: size, axis: false, gutter: 0, inset: 2),
            domain: OverallBurndownChartMath.domain(now: .now)
        )
        return plot.isDrawable ? plot : nil
    }

    private static func drawFurniture(
        _ context: inout GraphicsContext,
        plot: BurndownGeometry
    ) {
        drawBurndownScale(&context, plot: plot.rect, labels: false)
        drawBurndownCalendar(
            &context, plot: plot.rect,
            start: plot.domain.startEpoch,
            end: plot.domain.endEpoch,
            now: plot.domain.nowEpoch,
            labels: false
        )
        // Where "now" falls is what makes the forecast half legible as a
        // forecast, so it carries a little more than the day rules around it —
        // but stays under the data lines it sits behind.
        context.stroke(
            plot.rule(at: plot.domain.nowEpoch),
            with: .color(.primary.opacity(0.45)),
            lineWidth: 1.4
        )
    }

    /// Stroke weights for the wrist.
    ///
    /// Heavier than the medium widget's, which draws the same week at 2pt over
    /// roughly twice the width. A hairline survives being looked at on a desk;
    /// it does not survive a wrist at arm's length, in sunlight, for the second
    /// a glance lasts. Nothing here goes below 1.5.
    private enum Ink {
        static let actualLead: CGFloat = 3.2
        static let actualContext: CGFloat = 2.0
        static let projectedLead: CGFloat = 2.2
        static let projectedContext: CGFloat = 1.5
        static let renewalRule: CGFloat = 1.6
        static let headDot: CGFloat = 6
        static let emptyLead: CGFloat = 6.5
        static let emptyContext: CGFloat = 4.5
    }

    /// One source's week, in that source's colour. Every line is opaque — same
    /// as the board — and `leading` is only thicker, so it separates from the
    /// context lines without needing the legend there is no room for.
    private static func draw(
        _ provider: HeadroomWidgetSnapshot.Provider,
        in context: inout GraphicsContext,
        plot: BurndownGeometry,
        leading: Bool
    ) {
        guard let series = provider.burndown else { return }
        let ink = provider.watchTint

        let actual = OverallBurndownChartMath.preparedActual(
            series.actual, domain: plot.domain
        )
        if let line = plot.line(actual) {
            context.stroke(
                line,
                with: .color(ink),
                style: StrokeStyle(
                    lineWidth: leading ? Ink.actualLead : Ink.actualContext,
                    lineJoin: .round
                )
            )
        }
        if leading, let last = actual.last,
           let head = plot.dot(last, diameter: Ink.headDot) {
            context.fill(head, with: .color(ink))
        }

        let projected = OverallBurndownChartMath.preparedProjection(
            series.projected, windowEnd: series.windowEnd, domain: plot.domain
        )
        if let forecast = plot.line(projected) {
            context.stroke(
                forecast,
                with: .color(ink),
                style: StrokeStyle(
                    lineWidth: leading
                        ? Ink.projectedLead : Ink.projectedContext,
                    lineJoin: .round,
                    // Longer dashes than the widget's. On a heavier stroke a
                    // tight pattern closes up and the forecast stops reading
                    // as a forecast.
                    dash: leading ? [5, 2.5] : [3, 2.5]
                )
            )
            // Running out inside the week is the one event on this chart that
            // earns a mark of its own at this size.
            if let hit = projected.last, hit.count >= 2, hit[1] <= 0,
               let mark = plot.dot(
                   hit, diameter: leading ? Ink.emptyLead : Ink.emptyContext
               ) {
                context.fill(mark, with: .color(ink))
            }
        }

        // Only the named source's renewal gets a rule. Three dotted verticals
        // on a 40pt chart read as noise, not as three resets.
        if leading, let renew = series.windowEnd,
           renew > plot.domain.nowEpoch, renew <= plot.domain.endEpoch {
            context.stroke(
                plot.rule(at: renew),
                with: .color(ink.opacity(0.7)),
                style: StrokeStyle(lineWidth: Ink.renewalRule, dash: [2, 2.5])
            )
        }
    }
}

/// "Empty Thu" or "Resets Thu" for one source.
enum WatchRundownDeadline {
    static func label(for provider: HeadroomWidgetSnapshot.Provider) -> String? {
        if let empty = provider.emptiesAt {
            return HeadroomCopy.empty(weekday(empty))
        }
        guard let renew = provider.burndown?.windowEnd,
              renew > Date().timeIntervalSince1970
        else { return nil }
        return HeadroomCopy.resets(weekday(renew))
    }

    /// Weekday names, never day-of-month — the same axis rule every Headroom
    /// chart follows (`docs/glossary.md`).
    private static func weekday(_ epoch: Double) -> String {
        Date(timeIntervalSince1970: epoch)
            .formatted(.dateTime.weekday(.abbreviated))
    }
}
