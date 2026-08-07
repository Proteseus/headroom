import AppKit
import SwiftUI

/// Plausible site traffic. Live visitors float to the top; row tap opens the
/// shared detail page. The link glyph opens the Plausible dashboard.
/// Which sites appear is chosen under Settings → Integrations.
struct PlausibleSection: View {
    let data: PlausibleUsage?
    @Binding var selection: ServiceDetailSelection?

    @ViewBuilder
    var body: some View {
        // No token, no card. An empty "Connect Plausible" row is chrome for a
        // feature you haven't opted into — Settings is where you wire it up.
        if data?.configured == true {
            connected
        }
    }

    private var connected: some View {
        // Settings picks which sites the host returns; draw all of them.
        let sites = data?.sites ?? []

        return DataSection(title: "Plausible", iconID: "plausible") {
            if data?.ok != true {
                Text(data?.error ?? HeadroomCopy.serviceStatus("Plausible", configured: data?.configured))
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.orange)
            } else {
                Text(summaryLine(sites: sites.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(sites) { site in
                    row(site)
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
        let series = site.byDay ?? []
        HStack(spacing: 8) {
            Button {
                selection = .plausible(site.domain)
            } label: {
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
                                    : AnyShapeStyle(HeadroomPalette.orange)
                            )
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if series.contains(where: { ($0.visitors ?? 0) > 0 }) {
                        PlausibleTrafficSparkline(
                            days: series,
                            tint: HeadroomPalette.providerTint(id: "plausible")
                        )
                    }
                    if let live = site.realtime, live > 0 {
                        Text("\(live)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(HeadroomPalette.green)
                            .help("Current visitors")
                    }
                    ServiceDetailChevron()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show site detail")
            PermalinkButton(url: Permalink.url(from: site.dashboardURL))
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
}
