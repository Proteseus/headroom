import SwiftUI

/// The wide rundown, redrawn for a wrist.
///
/// The Mac's `OverviewBurndownCard` and the medium widget draw the same week
/// with a percent gutter, a labelled weekday axis, a legend, and every source
/// in its own brand colour. None of that survives here. A rectangular
/// complication is roughly 160×72 points, and it renders `.accented` — the
/// system flattens the whole view into one tint plus whatever is marked
/// accentable, so colour cannot carry identity at all.
///
/// What that leaves is a deliberate reduction rather than a shrunk copy:
///
///   * **One source is named, in words, above the chart** — whichever runs dry
///     first. That is the question a glance is asking, and text answers it in a
///     way a legend at 8pt cannot.
///   * **Its line is the accented one, and the only thick one.** The rest stay
///     in the base tone as context: the shape of the week, not a legend to
///     decode.
///   * **The axis goes, the rhythm stays.** Day boundaries keep their rules and
///     lose their labels; the scale keeps its three lines and loses "100%".
///
/// Two canvases, not one, because `.widgetAccentable()` groups views — it
/// cannot reach inside a single `Canvas`. Both build their geometry from the
/// same size and domain, so the layers register exactly.
struct WatchRundownChart: View {
    let snapshot: HeadroomWidgetSnapshot

    private var charted: [HeadroomWidgetSnapshot.Provider] { snapshot.charted }
    private var lead: HeadroomWidgetSnapshot.Provider? {
        snapshot.bindingProvider.flatMap { binding in
            charted.first { $0.id == binding.id }
        } ?? charted.first
    }

    var body: some View {
        ZStack {
            Canvas { context, size in
                guard let plot = Self.plot(in: size) else { return }
                Self.drawFurniture(&context, plot: plot)
                for provider in charted where provider.id != lead?.id {
                    Self.draw(
                        provider, in: &context, plot: plot, leading: false
                    )
                }
            }

            Canvas { context, size in
                guard let plot = Self.plot(in: size), let lead else { return }
                Self.draw(lead, in: &context, plot: plot, leading: true)
            }
            .widgetAccentable()
        }
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
        context.stroke(
            plot.rule(at: plot.domain.nowEpoch),
            with: .color(.primary.opacity(0.35)),
            lineWidth: 1
        )
    }

    /// One source's week. `leading` is the named one: thicker, and alone in the
    /// accented layer, so it separates from the context lines under any tint
    /// the face happens to be wearing.
    private static func draw(
        _ provider: HeadroomWidgetSnapshot.Provider,
        in context: inout GraphicsContext,
        plot: BurndownGeometry,
        leading: Bool
    ) {
        guard let series = provider.burndown else { return }
        // The face supplies the colour in `.accented`; opacity is the only part
        // of this that survives, and it is what pushes context lines back.
        let ink = Color.primary.opacity(leading ? 1 : 0.45)

        let actual = OverallBurndownChartMath.preparedActual(
            series.actual, domain: plot.domain
        )
        if let line = plot.line(actual) {
            context.stroke(
                line,
                with: .color(ink),
                style: StrokeStyle(
                    lineWidth: leading ? 2.4 : 1.2, lineJoin: .round
                )
            )
        }
        if leading, let last = actual.last,
           let head = plot.dot(last, diameter: 4.5) {
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
                    lineWidth: leading ? 1.6 : 1,
                    lineJoin: .round,
                    dash: leading ? [4, 2] : [2, 2]
                )
            )
            // Running out inside the week is the one event on this chart that
            // earns a mark of its own at this size.
            if let hit = projected.last, hit.count >= 2, hit[1] <= 0,
               let mark = plot.dot(hit, diameter: leading ? 5.5 : 3.5) {
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
                style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 2.5])
            )
        }
    }
}

// MARK: - Headline

/// The line above the chart: how much is left, on which source, and the date
/// that matters — empty if the forecast runs dry inside the week, otherwise
/// the renewal.
struct WatchRundownHeadline: View {
    let snapshot: HeadroomWidgetSnapshot

    var body: some View {
        if let provider = snapshot.bindingProvider {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int((100 - provider.percent).rounded()))%")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .widgetAccentable()
                Text("left · \(provider.title)")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                if let deadline = WatchRundownDeadline.label(for: provider) {
                    Text(deadline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else {
            Text(snapshot.attentionSummary ?? HeadroomCopy.openOnPhone)
                .font(.system(size: 12))
                .lineLimit(2)
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
