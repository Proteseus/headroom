import SwiftUI

/// Everything useful from the Management API for one project: identity,
/// Postgres host/version, per-service health, and security advisors.
struct SupabaseProjectDetail: View {
    let project: SupabaseProject
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            projectSection
            if let database = project.database, database.hasContent {
                databaseSection(database)
            }
            if let services = project.services, !services.isEmpty {
                servicesSection(services)
            }
            advisorsSection
            linksSection
        }
        .navigationTitle(project.name ?? project.ref)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var projectSection: some View {
        Section("Project") {
            HStack {
                Text("Health")
                Spacer()
                Circle()
                    .fill(project.healthy == true
                          ? HeadroomPalette.green
                          : HeadroomPalette.red)
                    .frame(width: 8, height: 8)
                Text(project.healthy == true ? "Healthy" : "Needs attention")
                    .foregroundStyle(.secondary)
            }
            metaRow("Status", project.status)
            metaRow("Region", project.region)
            metaRow("Ref", project.ref, monospaced: true)
            metaRow("Organization", project.organizationID, monospaced: true)
            metaRow("Created", createdLabel)
            if let error = project.healthError, !error.isEmpty {
                LabeledContent("Health error") {
                    Text(error)
                        .foregroundStyle(HeadroomPalette.amber)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let unhealthy = project.unhealthyServices, !unhealthy.isEmpty {
                LabeledContent("Unhealthy") {
                    Text(unhealthy.joined(separator: ", "))
                        .foregroundStyle(HeadroomPalette.red)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    @ViewBuilder
    private func databaseSection(_ database: SupabaseDatabase) -> some View {
        Section("Database") {
            metaRow("Host", database.host, monospaced: true)
            metaRow("Version", database.version, monospaced: true)
            metaRow("Engine", database.postgresEngine)
            metaRow("Release channel", database.releaseChannel)
        }
    }

    @ViewBuilder
    private func servicesSection(_ services: [SupabaseService]) -> some View {
        Section("Services") {
            ForEach(services) { service in
                HStack {
                    Circle()
                        .fill(service.healthy == true
                              ? HeadroomPalette.green
                              : HeadroomPalette.red)
                        .frame(width: 8, height: 8)
                    Text(service.name)
                    Spacer()
                    Text(service.status
                         ?? (service.healthy == true ? "healthy" : "unhealthy"))
                        .font(.caption.monospaced())
                        .foregroundStyle(
                            service.healthy == false
                                ? AnyShapeStyle(HeadroomPalette.red)
                                : AnyShapeStyle(.secondary)
                        )
                }
            }
        }
    }

    @ViewBuilder
    private var advisorsSection: some View {
        Section {
            if let failure = project.advisorError {
                Label(
                    "\(HeadroomCopy.serviceNotReporting("Advisors")) · \(failure)",
                    systemImage: "shield.slash"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if (project.lints ?? []).isEmpty {
                Text("No advisor findings")
                    .foregroundStyle(.secondary)
            }
            ForEach(project.lints ?? []) { lint in
                Button {
                    let target = lint.remediation ?? project.advisorsURL
                    if let url = URL(string: target) { openURL(url) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(lintLevelLabel(lint))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(lintLevelTint(lint))
                            .frame(width: 40, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lint.title ?? lint.name)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            if let entity = lint.entity {
                                Text(entity)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            if let detail = lint.detail ?? lint.description {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            if let categories = lint.categories, !categories.isEmpty {
                                Text(categories.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if project.lintTruncated == true, let total = project.lintTotal {
                Text("+ \(total - (project.lints ?? []).count) more in the dashboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Advisors")
                Spacer()
                if let total = project.lintTotal, total > 0 {
                    Text(advisorSummary)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var linksSection: some View {
        Section {
            if let raw = project.dashboardURL, let url = URL(string: raw) {
                Link("Open in Supabase", destination: url)
            }
            if let url = URL(string: project.advisorsURL) {
                Link("Security advisors", destination: url)
            }
        }
    }

    private var advisorSummary: String {
        var bits: [String] = []
        if let errors = project.lintErrorCount, errors > 0 {
            bits.append("\(errors) error\(errors == 1 ? "" : "s")")
        }
        if let warns = project.lintWarnCount, warns > 0 {
            bits.append("\(warns) warn\(warns == 1 ? "" : "s")")
        }
        if let infos = project.lintInfoCount, infos > 0 {
            bits.append("\(infos) info")
        }
        if bits.isEmpty, let total = project.lintTotal {
            return "\(total)"
        }
        return bits.joined(separator: " · ")
    }

    private var createdLabel: String? {
        guard let raw = project.createdAt, !raw.isEmpty else { return nil }
        if let date = Self.isoFormatter.date(from: raw)
            ?? Self.isoFractional.date(from: raw) {
            return HeadroomFormat.eventMoment(date)
        }
        return raw
    }

    @ViewBuilder
    private func metaRow(
        _ title: String,
        _ value: String?,
        monospaced: Bool = false
    ) -> some View {
        APIDetailMetaRow(title: title, value: value, monospaced: monospaced)
    }

    private func lintLevelLabel(_ lint: SupabaseLint) -> String {
        switch (lint.level ?? "WARN").uppercased() {
        case "ERROR": return "ERROR"
        case "INFO": return "INFO"
        default: return "WARN"
        }
    }

    private func lintLevelTint(_ lint: SupabaseLint) -> Color {
        switch (lint.level ?? "WARN").uppercased() {
        case "ERROR": return HeadroomPalette.red
        case "INFO": return .secondary
        default: return HeadroomPalette.amber
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension SupabaseDatabase {
    var hasContent: Bool {
        [host, version, postgresEngine, releaseChannel]
            .contains { ($0 ?? "").isEmpty == false }
    }
}
