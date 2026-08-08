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
        // Invented numbers belong in the complication gallery and nowhere
        // else — on the face they read as this week's quota.
        let snapshot = context.isPreview ? .placeholder : load()
        completion(WatchComplicationEntry(date: .now, snapshot: snapshot))
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
        WatchSnapshotCache.load() ?? .awaitingFirstSync
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
        case _ where entry.snapshot.charted.isEmpty:
            // Nothing to draw. The one case that still gets words, because a
            // blank tile and a flat week look identical.
            Text(emptyLabel)
                .font(.system(size: 12))
                .lineLimit(3)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .leading)
        default:
            // The chart takes the whole tile. What it used to say in a headline
            // is what the inline and corner families say already.
            WatchRundownChart(snapshot: entry.snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A watch that has never heard from the phone is a different problem from
    /// one waiting on its first week of history, and only the first is
    /// something the wearer can act on.
    private var emptyLabel: String {
        guard entry.snapshot.bindingProvider != nil else {
            return entry.snapshot.attentionSummary ?? HeadroomCopy.openOnPhone
        }
        return HeadroomCopy.noHistoryYet
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
