import AppKit
import SwiftUI

/// Supabase project health and security advisors. Unhealthy and unsafe
/// projects float to the top so a long portfolio still shows the ones that
/// matter. Row tap opens the shared detail page; the link glyph opens the
/// dashboard.
struct SupabaseSection: View {
    let data: SupabaseUsage?
    @Binding var selection: ServiceDetailSelection?

    @State private var showAll = false

    @ViewBuilder
    var body: some View {
        // No token, no card. An empty "Connect Supabase" row is chrome for a
        // feature you haven't opted into — Settings is where you wire it up.
        if data?.configured == true {
            connected
        }
    }

    private var connected: some View {
        let allProjects = data?.projects ?? []
        let attention = allProjects.filter {
            $0.healthy == false || ($0.lintErrorCount ?? 0) > 0
        }
        // Settings picks which projects the host returns; draw all of them.
        // Attention-first when something is wrong, with Show all to expand.
        let rows = showAll || attention.isEmpty ? allProjects : attention

        return DataSection(title: "Supabase", iconID: "supabase") {
            if data?.ok != true {
                Text(data?.error ?? HeadroomCopy.serviceStatus("Supabase", configured: data?.configured))
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.orange)
            } else {
                HStack(spacing: 6) {
                    Text("\(data?.projectCount ?? allProjects.count) projects")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let summary = securitySummary {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(
                                (data?.lintErrorCount ?? 0) > 0
                                    ? HeadroomPalette.red
                                    : HeadroomPalette.orange
                            )
                    }
                }

                ForEach(rows, id: \.ref) { project in
                    row(project)
                }

                if !attention.isEmpty, attention.count < allProjects.count {
                    Button {
                        showAll.toggle()
                    } label: {
                        Label(
                            showAll ? "Show attention only" : "Show all",
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

    @ViewBuilder
    private func row(_ project: SupabaseProject) -> some View {
        HStack(spacing: 8) {
            Button {
                selection = .supabase(project.ref)
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(project.healthy == true
                              ? HeadroomPalette.green
                              : HeadroomPalette.red)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name ?? project.ref)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        let context = context(project)
                        if !context.isEmpty {
                            Text(context)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if let badge = lintBadge(project) {
                        HStack(spacing: 3) {
                            Text("\(badge.count)")
                            Image(systemName: "shield.lefthalf.filled")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(badge.tint)
                        .help(badge.help)
                    }
                    ServiceDetailChevron()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show project detail")
            PermalinkButton(url: Permalink.url(from: project.dashboardURL))
        }
    }

    /// Portfolio headline: errors if there are any, otherwise the warn count.
    private var securitySummary: String? {
        let errors = data?.lintErrorCount ?? 0
        let warns = data?.lintWarnCount ?? 0
        if errors > 0 {
            return "· \(errors) security issue" + (errors == 1 ? "" : "s")
        }
        if warns > 0 {
            return "· \(warns) advisory" + (warns == 1 ? "" : " items")
        }
        return nil
    }

    private func lintBadge(
        _ project: SupabaseProject
    ) -> (count: Int, tint: Color, help: String)? {
        let errors = project.lintErrorCount ?? 0
        let warns = project.lintWarnCount ?? 0
        if errors > 0 {
            return (errors, HeadroomPalette.red,
                    "\(errors) security error" + (errors == 1 ? "" : "s"))
        }
        if warns > 0 {
            return (warns, HeadroomPalette.orange,
                    "\(warns) advisor warning" + (warns == 1 ? "" : "s"))
        }
        return nil
    }

    private func context(_ project: SupabaseProject) -> String {
        // Green/red dot already signals health — only add detail when unhealthy.
        let detail: String? = project.healthy == true
            ? nil
            : ((project.unhealthyServices ?? []).isEmpty
               ? project.status
               : (project.unhealthyServices ?? []).joined(separator: ", "))
        return [detail, project.region].compactMap { $0 }.joined(separator: " · ")
    }
}
