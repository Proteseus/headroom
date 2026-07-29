import AppKit
import SwiftUI

/// Plausible site traffic. Live visitors float to the top; each row opens the
/// site dashboard. Sites and host come from ~/.headroom/config.json.
struct PlausibleSection: View {
    let data: PlausibleUsage?

    @AppStorage("plausibleRowLimit")
    private var plausibleRowLimit = 6
    @State private var showAll = false

    @ViewBuilder
    var body: some View {
        // No token, no card. An empty "Connect Plausible" row is chrome for a
        // feature you haven't opted into — Settings is where you wire it up.
        if data?.configured == true {
            connected
        }
    }

    private var connected: some View {
        let allSites = data?.sites ?? []
        let limit = max(1, min(plausibleRowLimit, 20))
        let rows = showAll ? allSites : Array(allSites.prefix(limit))

        return DataSection(title: "Plausible") {
            if data?.ok != true {
                Text(data?.error ?? "Plausible unavailable")
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.amber)
            } else {
                Text(summaryLine(sites: allSites.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(rows) { site in
                    row(site)
                }

                if allSites.count > limit {
                    Button {
                        showAll.toggle()
                    } label: {
                        Label(
                            showAll ? "Show fewer" : "Show all",
                            systemImage: showAll
                                ? "line.3.horizontal.decrease"
                                : "ellipsis.circle"
                        )
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func summaryLine(sites: Int) -> String {
        let live = data?.realtime ?? 0
        let visitors = data?.visitorsToday ?? 0
        let label = data?.windowLabel ?? "today"
        var bits = ["\(sites) site" + (sites == 1 ? "" : "s")]
        if live > 0 {
            bits.append("\(live) live")
        }
        bits.append("\(HeadroomFormat.compact(visitors)) \(label)")
        return bits.joined(separator: " · ")
    }

    @ViewBuilder
    private func row(_ site: PlausibleSite) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill((site.realtime ?? 0) > 0
                      ? HeadroomPalette.green
                      : Color.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.domain)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(detail(site))
                    .font(.caption)
                    .foregroundStyle(
                        site.error == nil
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(HeadroomPalette.amber)
                    )
                    .lineLimit(1)
            }
            Spacer()
            if let live = site.realtime, live > 0 {
                Text("\(live)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(HeadroomPalette.green)
                    .help("Current visitors")
            }
            Button {
                open(site)
            } label: {
                Image(systemName: "arrow.up.right")
            }
            .buttonStyle(.borderless)
            .help("Open in Plausible")
            .accessibilityLabel("Open")
        }
    }

    private func detail(_ site: PlausibleSite) -> String {
        if let error = site.error, !error.isEmpty {
            return error
        }
        let visitors = site.visitorsToday
        let week = site.visitors7d
        let label = site.windowLabel
        var bits: [String] = []
        if let visitors {
            bits.append("\(HeadroomFormat.compact(visitors)) \(label)")
        }
        // Avoid "1.2k 7d · 1.2k / 7d" when the primary window is already 7d.
        if let week, site.range != "7d" {
            bits.append("\(HeadroomFormat.compact(week)) / 7d")
        }
        if let bounce = site.bounceRate7d {
            bits.append(String(format: "%.0f%% bounce", bounce))
        }
        return bits.isEmpty ? "No stats yet" : bits.joined(separator: " · ")
    }

    private func open(_ site: PlausibleSite) {
        guard let raw = site.dashboardURL,
              let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
}
