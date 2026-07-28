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
        guard let data = UserDefaults(suiteName: "group.com.centaur-labs.headroom")?
                .data(forKey: "widgetSnapshot"),
              let value = try? JSONDecoder().decode(
                HeadroomWidgetSnapshot.self,
                from: data
              )
        else { return .placeholder }
        return value
    }
}

struct HeadroomWidgetView: View {
    let entry: HeadroomWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(HeadroomCopy.product)
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }

            if family == .systemSmall {
                if let provider = entry.snapshot.providers.first {
                    HStack {
                        HeadroomRings(
                            layers: provider.ringLayers,
                            tint: Color(widgetHex: provider.accent) ?? .cyan
                        )
                        .frame(width: 54, height: 54)
                        VStack(alignment: .leading) {
                            Text(provider.title)
                                .font(.caption.weight(.semibold))
                            Text("\(Int(provider.percent.rounded()))%")
                                .font(.title3.monospacedDigit())
                        }
                    }
                } else {
                    Text(entry.snapshot.attentionSummary ?? HeadroomCopy.openHeadroom)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 18) {
                    ForEach(entry.snapshot.providers.prefix(3)) { provider in
                        VStack {
                            HeadroomRings(
                                layers: provider.ringLayers,
                                tint: Color(widgetHex: provider.accent) ?? .cyan
                            )
                            .frame(width: 54, height: 54)
                            Text(provider.title)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
            }

            if entry.snapshot.isStale {
                Text(HeadroomCopy.ago(entry.snapshot.age))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private var statusColor: Color {
        if entry.snapshot.isStale { return .orange }
        switch entry.snapshot.attentionLevel {
        case "critical": return .red
        case "warn": return .orange
        default: return .green
        }
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
}

private extension Color {
    init?(widgetHex: String?) {
        guard var value = widgetHex, !value.isEmpty else { return nil }
        value.removeAll(where: { $0 == "#" })
        guard value.count == 6, let rgb = Int(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }
}

@main
struct HeadroomWidgetBundle: WidgetBundle {
    var body: some Widget {
        HeadroomStatusWidget()
    }
}

struct HeadroomStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "HeadroomWidget",
            provider: HeadroomWidgetProvider()
        ) { entry in
            HeadroomWidgetView(entry: entry)
        }
        .configurationDisplayName(HeadroomCopy.product)
        .description("Coding quota and attention status from your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
