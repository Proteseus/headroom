import LocalAuthentication
import SwiftUI

/// Supabase, Plausible and the listening ports, as sections rather than a
/// screen. They were their own tab until the phone was split by urgency
/// instead of by source; now they sit under the feed on `ActivityScreen`,
/// which owns the list and therefore the confirmation dialogs too — a
/// `confirmationDialog` hung off a `Section` presents from nowhere in
/// particular.
struct ServiceSections: View {
    @ObservedObject var store: MobileUsageStore
    @Environment(\.openURL) private var openURL
    /// Asking to stop a server is this view's whole outbound surface. The
    /// screen above it owns the confirm, the biometric check and the failure.
    var requestStop: (LocalServer) -> Void

    var body: some View {
        supabaseSection
        plausibleSection
        localServersSection
    }

    @ViewBuilder
    private var supabaseSection: some View {
        // Unconnected services stay out of the list entirely — connecting them
        // happens on the Mac, so a placeholder row here is dead weight.
        let usage = store.snapshot.supabase
        if usage?.configured == true {
            Section {
                if usage?.ok != true {
                    Label(usage?.error ?? HeadroomCopy.serviceStatus(HeadroomCopy.supabase, configured: usage?.configured),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(HeadroomPalette.amber)
                } else {
                    ForEach(usage?.projects ?? []) { project in
                        DisclosureGroup {
                            ForEach(project.services ?? []) { service in
                                LabeledContent(
                                    service.name,
                                    value: service.status ?? (service.healthy == true ? "healthy" : "unhealthy")
                                )
                                .foregroundStyle(
                                    service.healthy == false
                                        ? AnyShapeStyle(HeadroomPalette.red)
                                        : AnyShapeStyle(.secondary)
                                )
                            }
                            lintRows(project)
                        } label: {
                            Button {
                                if let raw = project.dashboardURL, let url = URL(string: raw) {
                                    openURL(url)
                                }
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(project.healthy == true
                                              ? HeadroomPalette.green
                                              : HeadroomPalette.red)
                                        .frame(width: 8, height: 8)
                                    VStack(alignment: .leading) {
                                        Text(project.name ?? project.ref)
                                            .foregroundStyle(.primary)
                                        Text([project.region, project.status].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let errors = project.lintErrorCount, errors > 0 {
                                        Label("\(errors)", systemImage: "shield.lefthalf.filled")
                                            .font(.caption)
                                            .foregroundStyle(HeadroomPalette.red)
                                    } else if let warns = project.lintWarnCount, warns > 0 {
                                        Label("\(warns)", systemImage: "shield.lefthalf.filled")
                                            .font(.caption)
                                            .foregroundStyle(HeadroomPalette.amber)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(HeadroomCopy.supabase)
                    Spacer()
                    if let count = usage?.projectCount {
                        Text("\(count) projects")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Security advisor findings under each project, worst first. Tapping one
    /// opens Supabase's remediation doc, or the project's advisor page.
    @ViewBuilder
    private func lintRows(_ project: SupabaseProject) -> some View {
        if let failure = project.advisorError {
            Label("\(HeadroomCopy.serviceNotReporting("Advisors")) · \(failure)", systemImage: "shield.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(project.lints ?? []) { lint in
            Button {
                let target = lint.remediation ?? project.advisorsURL
                if let url = URL(string: target) { openURL(url) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: lint.isError
                          ? "exclamationmark.shield.fill"
                          : "shield.lefthalf.filled")
                        .foregroundStyle(lint.isError
                                         ? HeadroomPalette.red
                                         : HeadroomPalette.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lint.title ?? lint.name)
                            .font(.callout)
                            .foregroundStyle(.primary)
                        if let entity = lint.entity {
                            Text(entity)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let detail = lint.detail ?? lint.description {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
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
    }

    @ViewBuilder
    private var plausibleSection: some View {
        let usage = store.snapshot.plausible
        if usage?.configured == true {
            Section {
                if usage?.ok != true {
                    Label(usage?.error ?? HeadroomCopy.serviceStatus(HeadroomCopy.plausible, configured: usage?.configured),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(HeadroomPalette.amber)
                } else {
                    ForEach(
                        Array(plausibleSites.enumerated()),
                        id: \.offset
                    ) { _, site in
                        Button {
                            if let raw = site.dashboardURL, let url = URL(string: raw) {
                                openURL(url)
                            }
                        } label: {
                            HStack {
                                Circle()
                                    .fill(
                                        (site.realtime ?? 0) > 0
                                            ? HeadroomPalette.green
                                            : Color.secondary.opacity(0.3)
                                    )
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading) {
                                    Text(site.domain)
                                        .foregroundStyle(.primary)
                                    Text(plausibleDetail(site))
                                        .font(.caption)
                                        .foregroundStyle(
                                            site.error == nil
                                                ? AnyShapeStyle(.secondary)
                                                : AnyShapeStyle(HeadroomPalette.amber)
                                        )
                                }
                                Spacer()
                                if let live = site.realtime, live > 0 {
                                    Text("\(live) live")
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(HeadroomPalette.green)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text(HeadroomCopy.plausible)
                    Spacer()
                    if let today = usage?.visitorsToday {
                        let label = usage?.windowLabel ?? "today"
                        Text("\(HeadroomFormat.compact(today)) \(label)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var localServersSection: some View {
        Section {
            let servers = store.snapshot.local?.servers ?? []
            if servers.isEmpty {
                Text(HeadroomCopy.noLocalServers)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(servers) { server in
                    HStack {
                        Circle()
                            .fill(server.reachable == false
                                  ? HeadroomPalette.red
                                  : HeadroomPalette.green)
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading) {
                            Text(server.name ?? "Server")
                            Text(serverDetail(server))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if store.stoppingServerID == server.id {
                            ProgressView()
                        } else if server.pid != nil {
                            Button("Stop", systemImage: "stop.circle") {
                                requestStop(server)
                            }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(HeadroomPalette.red)
                            // An archived PID may belong to something else by
                            // now. Never fire a kill at a stale process id.
                            .disabled(!store.mobilePermissions.servers || store.isStale)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(HeadroomCopy.localServers)
                Spacer()
                Label(serverComputerName, systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var serverComputerName: String {
        store.snapshot.currentMachine?.title
            ?? store.snapshot.local?.host
            ?? MobileConnection.hostLabel
    }

    private func plausibleDetail(_ site: PlausibleSite) -> String {
        if let error = site.error { return error }
        var bits: [String] = []
        if let today = site.visitorsToday {
            bits.append("\(HeadroomFormat.compact(today)) \(site.windowLabel)")
        }
        if let week = site.visitors7d, site.range != "7d" {
            bits.append("\(HeadroomFormat.compact(week)) / 7d")
        }
        if let bounce = site.bounceRate7d {
            bits.append("\(Int(bounce.rounded()))% bounce")
        }
        return bits.isEmpty ? "No stats yet" : bits.joined(separator: " · ")
    }

    private var plausibleSites: [PlausibleSite] {
        store.snapshot.plausible?.sites ?? []
    }

    private func serverDetail(_ server: LocalServer) -> String {
        [
            server.port.map { ":\($0)" },
            server.latencyMS.map { "\($0)ms" },
            server.cmd,
        ].compactMap { $0 }.joined(separator: " · ")
    }
}

enum MobileControlAuthorizer {
    static func authorize(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? LAError(.biometryNotAvailable)
        }
        try await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: reason
        )
    }
}
