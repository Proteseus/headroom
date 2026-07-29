import SwiftUI
import WidgetKit

/// Both faces read the app group the watch app fills from the phone. Neither
/// fetches: the extension has no route to the Mac and no business waking the
/// phone.
struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let snapshot: HeadroomWidgetSnapshot
}

struct WatchComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (WatchComplicationEntry) -> Void
    ) {
        completion(WatchComplicationEntry(date: .now, snapshot: load()))
    }

    /// A short run of entries rather than one.
    ///
    /// Nothing in the payload changes between phone pushes, but two things
    /// drawn from `Date()` do: the now rule's position, and how old the
    /// snapshot is. Stepping through them locally keeps the face honest for
    /// four hours on a single reload — asking for one every fifteen minutes,
    /// the way the home-screen widget does, would spend the day's complication
    /// budget before lunch.
    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<WatchComplicationEntry>) -> Void
    ) {
        let snapshot = load()
        let step: TimeInterval = 20 * 60
        let entries = (0..<12).map { index in
            WatchComplicationEntry(
                date: Date(timeIntervalSinceNow: Double(index) * step),
                snapshot: snapshot
            )
        }
        completion(Timeline(
            entries: entries,
            policy: .after(Date(timeIntervalSinceNow: 12 * step))
        ))
    }

    private func load() -> HeadroomWidgetSnapshot {
        WatchSnapshotCache.load() ?? .placeholder
    }
}

// MARK: - Rings

struct HeadroomRingsComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "HeadroomWatchRings",
            provider: WatchComplicationProvider()
        ) { entry in
            HeadroomRingsComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName(HeadroomCopy.codingQuotas)
        .description(HeadroomCopy.onePerProvider)
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

struct HeadroomRingsComplicationView: View {
    let entry: WatchComplicationEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCorner:
            // The corner draws the glyph and hands the reading to the curved
            // label, which is the only text a corner gets and is rendered
            // outside the dial rather than inside it.
            WatchRingsGlyph(providers: entry.snapshot.providers)
                .widgetLabel {
                    Text(cornerLabel)
                }
        default:
            WatchRingsGlyph(providers: entry.snapshot.providers)
        }
    }

    private var cornerLabel: String {
        guard let provider = entry.snapshot.bindingProvider else {
            return HeadroomCopy.openOnPhone
        }
        return "\(provider.title) \(HeadroomCopy.percentUsed(provider.percent))"
    }
}

// MARK: - Rundown

struct HeadroomRundownComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "HeadroomWatchRundown",
            provider: WatchComplicationProvider()
        ) { entry in
            HeadroomRundownComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName(HeadroomCopy.overallBurndown)
        .description(HeadroomCopy.overallBurndownSubtitle)
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

struct HeadroomRundownComplicationView: View {
    let entry: WatchComplicationEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(inlineLabel)
        default:
            VStack(alignment: .leading, spacing: 1) {
                WatchRundownHeadline(snapshot: entry.snapshot)
                if entry.snapshot.charted.isEmpty {
                    // No week to draw yet. Say so once, quietly, rather than
                    // leaving a third of the complication blank.
                    Text(HeadroomCopy.noHistoryYet)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .leading)
                } else {
                    WatchRundownChart(snapshot: entry.snapshot)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// One line, no glyph — inline is a single run of system-styled text.
    private var inlineLabel: String {
        guard let provider = entry.snapshot.bindingProvider else {
            return HeadroomCopy.openOnPhone
        }
        let left = HeadroomCopy.percentLeft(100 - provider.percent)
        guard let deadline = WatchRundownDeadline.label(for: provider) else {
            return "\(provider.title) \(left)"
        }
        return "\(provider.title) \(left) · \(deadline)"
    }
}

@main
struct HeadroomWatchComplicationBundle: WidgetBundle {
    var body: some Widget {
        HeadroomRingsComplication()
        HeadroomRundownComplication()
    }
}
