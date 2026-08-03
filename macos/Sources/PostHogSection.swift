import AppKit
import SwiftUI

/// PostHog project traffic. Live persons float to the top; row tap opens the
/// shared detail page. The link glyph opens the PostHog dashboard.
/// Which projects appear is chosen under Settings → Integrations.
struct PostHogSection: View {
    let data: PostHogUsage?
    @Binding var selection: ServiceDetailSelection?

    @ViewBuilder
    var body: some View {
        // No token, no card. An empty "Connect PostHog" row is chrome for a
        // feature you haven't opted into — Settings is where you wire it up.
        if data?.configured == true {
            connected
        }
    }

    private var connected: some View {
        let projects = data?.projects ?? []

        return DataSection(title: HeadroomCopy.posthog, iconID: "posthog") {
            if data?.ok != true {
                Text(data?.error ?? HeadroomCopy.serviceStatus(
                    HeadroomCopy.posthog, configured: data?.configured))
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.orange)
            } else {
                Text(summaryLine(projects: projects.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(projects) { project in
                    row(project)
                }
            }
        }
    }

    private func summaryLine(projects: Int) -> String {
        let live = data?.realtime ?? 0
        let events = data?.eventsToday ?? 0
        let label = data?.windowLabel ?? "today"
        var bits = ["\(projects) project" + (projects == 1 ? "" : "s")]
        if live > 0 {
            bits.append("\(live) live")
        }
        bits.append("\(HeadroomFormat.compact(events)) events \(label)")
        return bits.joined(separator: " · ")
    }

    @ViewBuilder
    private func row(_ project: PostHogProject) -> some View {
        HStack(spacing: 8) {
            Button {
                selection = .posthog(project.id)
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill((project.realtime ?? 0) > 0
                              ? HeadroomPalette.green
                              : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(detail(project))
                            .font(.caption)
                            .foregroundStyle(
                                project.error == nil
                                    ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(HeadroomPalette.orange)
                            )
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let live = project.realtime, live > 0 {
                        Text("\(live)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(HeadroomPalette.green)
                            .help("Persons active in the last 5 minutes")
                    }
                    ServiceDetailChevron()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show project detail")
            PermalinkButton(url: Permalink.url(from: project.dashboardURL))
        }
    }

    private func detail(_ project: PostHogProject) -> String {
        if let error = project.error, !error.isEmpty {
            return error
        }
        let events = project.eventsToday
        let users = project.usersToday
        let weekEvents = project.events7d
        let label = project.windowLabel
        var bits: [String] = []
        if let events {
            bits.append("\(HeadroomFormat.compact(events)) events \(label)")
        }
        if let users {
            bits.append("\(HeadroomFormat.compact(users)) users")
        }
        // Avoid repeating the same window when the primary is already 7d.
        if let weekEvents, project.range != "7d" {
            bits.append("\(HeadroomFormat.compact(weekEvents)) / 7d")
        }
        return bits.isEmpty ? "No stats yet" : bits.joined(separator: " · ")
    }
}
