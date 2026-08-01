import LocalAuthentication
import SwiftUI

/// Supabase, Plausible, PostHog and the listening ports, as sections rather
/// than a screen. They were their own tab until the phone was split by urgency
/// instead of by source; now they sit under the feed on `ActivityScreen`,
/// which owns the list and therefore the confirmation dialogs too — a
/// `confirmationDialog` hung off a `Section` presents from nowhere in
/// particular.
struct ServiceSections: View {
    @ObservedObject var store: MobileUsageStore
    /// Asking to stop a server is this view's whole outbound surface. The
    /// screen above it owns the confirm, the biometric check and the failure.
    var requestStop: (LocalServer) -> Void

    var body: some View {
        supabaseSection
        plausibleSection
        posthogSection
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
                        NavigationLink {
                            SupabaseProjectDetail(project: project)
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
                                    let subtitle = supabaseSubtitle(project)
                                    if !subtitle.isEmpty {
                                        Text(subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if let errors = project.lintErrorCount, errors > 0 {
                                    Text("\(errors)")
                                        .font(.caption.monospacedDigit().weight(.medium))
                                        .foregroundStyle(HeadroomPalette.red)
                                } else if let warns = project.lintWarnCount, warns > 0 {
                                    Text("\(warns)")
                                        .font(.caption.monospacedDigit().weight(.medium))
                                        .foregroundStyle(HeadroomPalette.amber)
                                }
                            }
                        }
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    ProviderMark(providerID: "supabase", size: 12)
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

    /// Region always; raw status / unhealthy services only when the dot is
    /// red — same rule as the Mac card, so `ACTIVE_HEALTHY` never rides next
    /// to a green light.
    private func supabaseSubtitle(_ project: SupabaseProject) -> String {
        let detail: String? = project.healthy == true
            ? nil
            : ((project.unhealthyServices ?? []).isEmpty
               ? project.status
               : (project.unhealthyServices ?? []).joined(separator: ", "))
        return [project.region, detail].compactMap { $0 }.joined(separator: " · ")
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
                        NavigationLink {
                            PlausibleSiteDetail(site: site)
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
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    ProviderMark(providerID: "plausible", size: 12)
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
    private var posthogSection: some View {
        let usage = store.snapshot.posthog
        if usage?.configured == true {
            Section {
                if usage?.ok != true {
                    Label(usage?.error ?? HeadroomCopy.serviceStatus(
                        HeadroomCopy.posthog, configured: usage?.configured),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(HeadroomPalette.amber)
                } else {
                    ForEach(posthogProjects) { project in
                        NavigationLink {
                            PostHogProjectDetail(project: project)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(
                                        (project.realtime ?? 0) > 0
                                            ? HeadroomPalette.green
                                            : Color.secondary.opacity(0.3)
                                    )
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading) {
                                    Text(project.displayName)
                                        .foregroundStyle(.primary)
                                    Text(posthogDetail(project))
                                        .font(.caption)
                                        .foregroundStyle(
                                            project.error == nil
                                                ? AnyShapeStyle(.secondary)
                                                : AnyShapeStyle(HeadroomPalette.amber)
                                        )
                                }
                                Spacer()
                                if let live = project.realtime, live > 0 {
                                    Text("\(live) live")
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(HeadroomPalette.green)
                                }
                            }
                        }
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    ProviderMark(providerID: "posthog", size: 12)
                    Text(HeadroomCopy.posthog)
                    Spacer()
                    if let events = usage?.eventsToday {
                        let label = usage?.windowLabel ?? "today"
                        Text("\(HeadroomFormat.compact(events)) \(label)")
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
                        NavigationLink {
                            LocalServerDetail(
                                server: server,
                                hostName: serverComputerName,
                                canStop: store.mobilePermissions.servers
                                    && !store.isStale
                                    && server.pid != nil,
                                isStopping: store.stoppingServerID == server.id,
                                onStop: { requestStop(server) }
                            )
                        } label: {
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
                            }
                        }
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

    private func posthogDetail(_ project: PostHogProject) -> String {
        if let error = project.error { return error }
        var bits: [String] = []
        if let events = project.eventsToday {
            bits.append("\(HeadroomFormat.compact(events)) events \(project.windowLabel)")
        }
        if let users = project.usersToday {
            bits.append("\(HeadroomFormat.compact(users)) users")
        }
        if let week = project.events7d, project.range != "7d" {
            bits.append("\(HeadroomFormat.compact(week)) / 7d")
        }
        return bits.isEmpty ? "No stats yet" : bits.joined(separator: " · ")
    }

    private var posthogProjects: [PostHogProject] {
        store.snapshot.posthog?.projects ?? []
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
