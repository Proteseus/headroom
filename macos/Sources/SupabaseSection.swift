import AppKit
import SwiftUI

/// Supabase project health and security advisors. Unhealthy, unsafe, and
/// pinned projects float to the top so a long portfolio still shows the ones
/// that matter without expanding.
struct SupabaseSection: View {
    let data: SupabaseUsage?

    @AppStorage("supabaseFavoriteRefs")
    private var favoriteRefsRaw = ""
    @AppStorage("supabaseRowLimit")
    private var supabaseRowLimit = 6
    @State private var expandedRef: String?
    @State private var showAll = false

    private var favorites: Set<String> {
        Set(favoriteRefsRaw.split(separator: ",").map(String.init))
    }

    var body: some View {
        let allProjects = data?.projects ?? []
        let attention = allProjects.filter {
            $0.healthy == false
                || ($0.lintErrorCount ?? 0) > 0
                || favorites.contains($0.ref)
        }
        let preferred = attention.isEmpty ? allProjects : attention
        let limit = max(1, min(supabaseRowLimit, 20))
        let rows = showAll ? allProjects : Array(preferred.prefix(limit))

        DataSection(title: "Supabase") {
            if data?.configured != true {
                notConnected
            } else if data?.ok != true {
                Text(data?.error ?? "Supabase unavailable")
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.amber)
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
                                    : HeadroomPalette.amber
                            )
                    }
                }

                ForEach(rows, id: \.ref) { project in
                    row(project)
                }

                if allProjects.count > limit {
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

    private var notConnected: some View {
        HStack {
            Text(data?.error ?? "Connect Supabase")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            SettingsLink {
                Image(systemName: "link")
            }
            .buttonStyle(.borderless)
            .help("Open Settings to connect")
            .accessibilityLabel("Connect Supabase")
        }
    }

    @ViewBuilder
    private func row(_ project: SupabaseProject) -> some View {
        let pinned = favorites.contains(project.ref)
        VStack(alignment: .leading, spacing: 5) {
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
                Spacer()
                if let badge = lintBadge(project) {
                    Label("\(badge.count)", systemImage: "shield.lefthalf.filled")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(badge.tint)
                        .labelStyle(.titleAndIcon)
                        .help(badge.help)
                }
                Button {
                    toggleFavorite(project.ref)
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(pinned ? "Unpin project" : "Pin project")
                .accessibilityLabel(pinned ? "Unpin" : "Pin")
                Button {
                    open(project)
                } label: {
                    Image(systemName: "arrow.up.right")
                }
                .buttonStyle(.borderless)
                .help("Open in Supabase")
                .accessibilityLabel("Open")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                expandedRef = expandedRef == project.ref ? nil : project.ref
            }
            if expandedRef == project.ref {
                VStack(alignment: .leading, spacing: 6) {
                    Text(serviceSummary(project))
                        .font(.caption)
                        .foregroundStyle(
                            project.healthy == true
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(HeadroomPalette.red)
                        )
                    lintList(project)
                }
                .padding(.leading, 15)
            }
        }
    }

    /// Every advisor finding on the project, worst first — the point is to fix
    /// them, so each row carries the entity and links to the remediation doc.
    @ViewBuilder
    private func lintList(_ project: SupabaseProject) -> some View {
        let lints = project.lints ?? []
        if let failure = project.advisorError {
            Label("Advisors unavailable · \(failure)", systemImage: "shield.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if lints.isEmpty {
            if project.advisorError == nil {
                Label("No advisor findings", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(lints) { lint in
                Button {
                    openLint(lint, project: project)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(levelTag(lint))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(levelTint(lint))
                            .frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lint.title ?? lint.name)
                                .font(.caption)
                                .lineLimit(1)
                            if let entity = lint.entity {
                                Text(entity)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(lintHelp(lint))
            }
            if project.lintTruncated == true {
                Text("+ \((project.lintTotal ?? 0) - lints.count) more in the dashboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func levelTag(_ lint: SupabaseLint) -> String {
        switch (lint.level ?? "WARN").uppercased() {
        case "ERROR": return "ERROR"
        case "INFO": return "INFO"
        default: return "WARN"
        }
    }

    private func levelTint(_ lint: SupabaseLint) -> Color {
        switch (lint.level ?? "WARN").uppercased() {
        case "ERROR": return HeadroomPalette.red
        case "INFO": return HeadroomPalette.dim
        default: return HeadroomPalette.amber
        }
    }

    private func lintHelp(_ lint: SupabaseLint) -> String {
        [lint.detail, lint.description, lint.name]
            .compactMap { $0 }
            .first ?? lint.name
    }

    private func openLint(_ lint: SupabaseLint, project: SupabaseProject) {
        let target = lint.remediation ?? project.advisorsURL
        guard let url = URL(string: target) else { return }
        NSWorkspace.shared.open(url)
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
            return (warns, HeadroomPalette.amber,
                    "\(warns) advisor warning" + (warns == 1 ? "" : "s"))
        }
        return nil
    }

    private func toggleFavorite(_ ref: String) {
        var values = favorites
        if values.contains(ref) {
            values.remove(ref)
        } else {
            values.insert(ref)
        }
        favoriteRefsRaw = values.sorted().joined(separator: ",")
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

    private func serviceSummary(_ project: SupabaseProject) -> String {
        let services = project.services ?? []
        if services.isEmpty {
            return project.healthError ?? project.status ?? "No service detail"
        }
        let unhealthy = services.filter { $0.healthy != true }.map(\.name)
        if unhealthy.isEmpty {
            return services.map(\.name).joined(separator: " · ")
        }
        return unhealthy.joined(separator: " · ") + " down"
    }

    private func open(_ project: SupabaseProject) {
        guard let raw = project.dashboardURL,
              let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
}
