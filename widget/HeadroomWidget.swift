import SwiftUI
import WidgetKit

struct HeadroomWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: HeadroomWidgetSnapshot
}

struct HeadroomWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> HeadroomWidgetEntry {
        HeadroomWidgetEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (HeadroomWidgetEntry) -> Void
    ) {
        completion(HeadroomWidgetEntry(date: .now, snapshot: load()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<HeadroomWidgetEntry>) -> Void
    ) {
        let entry = HeadroomWidgetEntry(date: .now, snapshot: load())
        completion(Timeline(
            entries: [entry],
            policy: .after(Date(timeIntervalSinceNow: 15 * 60))
        ))
    }

    private func load() -> HeadroomWidgetSnapshot {
        HeadroomWidgetSnapshot.cached() ?? .placeholder
    }
}

/// No product name, no status dot. A widget the user chose to place already
/// says which app it belongs to, and the chart says the rest — both of them
/// were spending the small size's only real currency, which is height.
struct HeadroomWidgetView: View {
    let entry: HeadroomWidgetEntry
    @Environment(\.widgetFamily) private var family

    private var charted: [HeadroomWidgetSnapshot.Provider] {
        entry.snapshot.providers.filter { $0.burndown != nil }
    }

    var body: some View {
        Group {
            if family == .systemSmall {
                small
            } else {
                wide
            }
        }
        .containerBackground(.background, for: .widget)
    }

    /// One provider's rings — the small size has no room for a week of chart.
    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let provider = entry.snapshot.providers.first {
                HeadroomRings(
                    layers: provider.ringLayers,
                    tint: HeadroomPalette.providerTint(
                        id: provider.id,
                        accent: provider.accent
                    )
                )
                .frame(width: 62, height: 62)
                Spacer(minLength: 8)
                Text(provider.title)
                    .font(.caption.weight(.semibold))
                Text("\(Int(provider.percent.rounded()))% used")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(entry.snapshot.attentionSummary ?? HeadroomCopy.openHeadroom)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            staleNote
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The combined burndown, every provider on one axis — the same chart the
    /// Mac's Overview leads with. Rings stand in until there is history.
    @ViewBuilder
    private var wide: some View {
        if charted.isEmpty {
            ringRow
        } else {
            VStack(alignment: .leading, spacing: 6) {
                CombinedBurndownChart(providers: charted)
                legend
            }
        }
    }

    private var ringRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                ForEach(entry.snapshot.providers.prefix(3)) { provider in
                    VStack(spacing: 5) {
                        HeadroomRings(
                            layers: provider.ringLayers,
                            tint: HeadroomPalette.providerTint(
                                id: provider.id,
                                accent: provider.accent
                            )
                        )
                        .frame(width: 54, height: 54)
                        Text(provider.title)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if entry.snapshot.providers.isEmpty {
                Text(entry.snapshot.attentionSummary ?? HeadroomCopy.openHeadroom)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(HeadroomCopy.noHistoryYet)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            staleNote
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(charted) { provider in
                HStack(spacing: 4) {
                    Capsule()
                        .fill(provider.burndownTint)
                        .frame(width: 10, height: 2.5)
                    Text(provider.title)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if entry.snapshot.isStale {
                Text(HeadroomCopy.ago(entry.snapshot.age))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var staleNote: some View {
        if entry.snapshot.isStale {
            Text(HeadroomCopy.ago(entry.snapshot.age))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
}

/// Every provider's remaining quota on one week-wide axis.
///
/// The Mac's `OverviewBurndownCard` in a widget's worth of space: same domain,
/// same weekday bands, same solid-then-dashed reading of measured against
/// forecast. What it drops is what needs a caption to be worth the pixels —
/// the percent gutter, the per-provider reset countdowns, the verdicts.
private struct CombinedBurndownChart: View {
    let providers: [HeadroomWidgetSnapshot.Provider]

    var body: some View {
        Canvas { context, size in
            let domain = OverallBurndownChartMath.domain(now: .now)
            let plot = burndownPlotRect(in: size, axis: true, gutter: 0)
            let span = domain.endEpoch - domain.startEpoch
            guard span > 0, plot.width > 0, plot.height > 0 else { return }

            func x(_ time: Double) -> CGFloat {
                plot.minX + CGFloat((time - domain.startEpoch) / span) * plot.width
            }
            func y(_ remaining: Double) -> CGFloat {
                plot.maxY
                    - CGFloat(max(0, min(remaining, 100)) / 100) * plot.height
            }
            func path(_ pairs: [[Double]]) -> Path? {
                let points = pairs.compactMap { pair -> CGPoint? in
                    guard pair.count >= 2 else { return nil }
                    return CGPoint(x: x(pair[0]), y: y(pair[1]))
                }
                guard points.count >= 2 else { return nil }
                var line = Path()
                line.move(to: points[0])
                for point in points.dropFirst() { line.addLine(to: point) }
                return line
            }

            drawBurndownScale(&context, plot: plot, labels: false)
            drawBurndownCalendar(
                &context, plot: plot,
                start: domain.startEpoch,
                end: domain.endEpoch,
                now: domain.nowEpoch
            )

            var nowMarker = Path()
            nowMarker.move(to: CGPoint(x: x(domain.nowEpoch), y: plot.minY))
            nowMarker.addLine(to: CGPoint(x: x(domain.nowEpoch), y: plot.maxY))
            context.stroke(
                nowMarker,
                with: .color(.secondary.opacity(0.4)),
                lineWidth: 1
            )

            for provider in providers {
                guard let series = provider.burndown else { continue }
                let tint = provider.burndownTint

                let actual = OverallBurndownChartMath.preparedActual(
                    series.actual, domain: domain
                )
                if let line = path(actual) {
                    context.stroke(
                        line,
                        with: .color(tint),
                        style: StrokeStyle(lineWidth: 2, lineJoin: .round)
                    )
                }
                if let last = actual.last, last.count >= 2 {
                    let head = CGPoint(x: x(last[0]), y: y(last[1]))
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: head.x - 2.5, y: head.y - 2.5,
                            width: 5, height: 5
                        )),
                        with: .color(tint)
                    )
                }

                let projected = OverallBurndownChartMath.preparedProjection(
                    series.projected,
                    windowEnd: series.windowEnd,
                    domain: domain
                )
                if let forecast = path(projected) {
                    context.stroke(
                        forecast,
                        with: .color(tint),
                        style: StrokeStyle(
                            lineWidth: 1.5, lineJoin: .round, dash: [5, 2]
                        )
                    )
                    // A forecast that reaches empty inside the week is the one
                    // thing on this chart worth a mark of its own.
                    if let hit = projected.last, hit.count >= 2, hit[1] <= 0 {
                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: x(hit[0]) - 3, y: y(hit[1]) - 3,
                                width: 6, height: 6
                            )),
                            with: .color(tint.opacity(0.85))
                        )
                    }
                }

                if let renew = series.windowEnd,
                   renew > domain.nowEpoch,
                   renew <= domain.endEpoch {
                    var renewMarker = Path()
                    renewMarker.move(to: CGPoint(x: x(renew), y: plot.minY))
                    renewMarker.addLine(to: CGPoint(x: x(renew), y: plot.maxY))
                    context.stroke(
                        renewMarker,
                        with: .color(tint),
                        style: StrokeStyle(lineWidth: 1.5, dash: [1.5, 2.5])
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(HeadroomCopy.overallBurndown), \(HeadroomCopy.overallBurndownSubtitle). "
                + providers.map { provider in
                    "\(provider.title) \(Int(provider.percent.rounded())) percent used"
                }.joined(separator: ", ")
        )
    }
}

private extension HeadroomWidgetSnapshot.Provider {
    var ringLayers: [HeadroomRingLayer] {
        if let layers, !layers.isEmpty {
            return layers.map {
                HeadroomRingLayer(
                    id: $0.id,
                    percent: $0.percent,
                    pacePercent: $0.pacePercent
                )
            }
        }
        return [
            HeadroomRingLayer(
                id: title,
                percent: percent,
                pacePercent: nil
            ),
        ]
    }

    /// A spent pool recedes rather than warns — the same reading the Mac gives
    /// it, minus the AppKit colour surgery `Color.drained()` needs.
    var burndownTint: Color {
        let base = HeadroomPalette.providerTint(id: id, accent: accent)
        return burndown?.exhausted == true ? base.opacity(0.45) : base
    }
}

@main
struct HeadroomWidgetBundle: WidgetBundle {
    var body: some Widget {
        HeadroomStatusWidget()
    }
}

struct HeadroomStatusWidget: Widget {
    /// Same extension, two homes. On the Mac the numbers never left the machine
    /// the widget is sitting on, so "from your Mac" would read strangely there.
    private static var gallerySubtitle: String {
        #if os(macOS)
        return "Coding quota and attention status at a glance."
        #else
        return "Coding quota and attention status from your Mac."
        #endif
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "HeadroomWidget",
            provider: HeadroomWidgetProvider()
        ) { entry in
            HeadroomWidgetView(entry: entry)
        }
        .configurationDisplayName(HeadroomCopy.product)
        .description(Self.gallerySubtitle)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
