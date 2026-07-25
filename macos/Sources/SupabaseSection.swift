import AppKit
import SwiftUI

/// Supabase project health. Unhealthy and pinned projects float to the top so
/// a long portfolio still shows the ones that matter without expanding.
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
            $0.healthy == false || favorites.contains($0.ref)
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
                    .foregroundStyle(.orange)
            } else {
                Text("\(data?.projectCount ?? allProjects.count) projects")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
            Text(data?.error ?? "Connect Supabase to monitor projects.")
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
                    .fill(project.healthy == true ? .green : .red)
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
                Text(serviceSummary(project))
                    .font(.caption)
                    .foregroundStyle(
                        project.healthy == true
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(Color.red)
                    )
                    .padding(.leading, 15)
            }
        }
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
