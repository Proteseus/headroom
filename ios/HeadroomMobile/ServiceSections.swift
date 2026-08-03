import LocalAuthentication
import SwiftUI

/// Ordered Activity blocks — same catalog pin as Mac Integrations.
/// Feed kinds (git / Actions / Vercel) paint once as a chronological Recent
/// section at the first feed watch; service panels keep their own blocks.
struct ServiceSections: View {
    @ObservedObject var store: MobileUsageStore
    var requestStop: (LocalServer) -> Void

    var body: some View {
        let blocks = IntegrationWatch.activityBlocks(
            from: store.snapshot.integrationsOrder ?? store.snapshot.servicesOrder
        )
        ForEach(blocks) { watch in
            activityBlock(watch, blocks: blocks)
        }
    }

    @ViewBuilder
    private func activityBlock(
        _ watch: IntegrationWatch, blocks: [IntegrationWatch]
    ) -> some View {
        let feed = (store.snapshot.activity ?? []).filter {
            !ActivityStatusStyle.resolve($0.status).needsAttention
        }
        switch watch {
        case .git, .github, .vercel, .sentry, .datadog, .axiom:
            if IntegrationWatch.isLeadFeedWatch(watch, in: blocks),
               !feed.isEmpty {
                Section {
                    ForEach(feed) { item in
                        ActivityRow(item: item)
                    }
                } header: {
                    Text(HeadroomCopy.recentActivity)
                }
            }
        case .supabase:
            supabaseSection
        case .plausible:
            plausibleSection
        case .posthog:
            posthogSection
        case .servers:
            localServersSection
        case .builds:
            xcodeBuildsSection
        case .openrouter, .aiGateway:
            EmptyView()
        }
    }

    @ViewBuilder
    private var supabaseSection: some View {
        let usage = store.snapshot.supabase
        if usage?.configured == true {
            Section {
                if usage?.ok != true {
                    Label(usage?.error ?? HeadroomCopy.serviceStatus(HeadroomCopy.supabase, configured: usage?.configured),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(HeadroomPalette.orange)
                } else if let projects = usage?.projects {
                    ForEach(projects) { project in
                        HStack {
                            NavigationLink {
                                SupabaseProjectDetail(project: project)
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(project.healthy == false
                                              ? HeadroomPalette.red
                                              : HeadroomPalette.green)
                                        .frame(width: 8, height: 8)
                                    Text(project.name ?? project.ref ?? "Project")
                                }
                            }
                            PermalinkButton(
                                url: Permalink.url(from: project.dashboardURL))
                        }
                    }
                }
            } header: {
                Text(HeadroomCopy.supabase)
            }
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
                        .foregroundStyle(HeadroomPalette.orange)
                } else if let sites = usage?.sites {
                    ForEach(sites) { site in
                        HStack {
                            NavigationLink {
                                PlausibleSiteDetail(site: site)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(site.domain ?? "Site")
                                    Text(plausibleDetail(site))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            PermalinkButton(
                                url: Permalink.url(from: site.dashboardURL))
                        }
                    }
                }
            } header: {
                Text(HeadroomCopy.plausible)
            }
        }
    }

    @ViewBuilder
    private var posthogSection: some View {
        let usage = store.snapshot.posthog
        if usage?.configured == true {
            Section {
                if usage?.ok != true {
                    Label(usage?.error ?? HeadroomCopy.serviceStatus(HeadroomCopy.posthog, configured: usage?.configured),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(HeadroomPalette.orange)
                } else {
                    ForEach(posthogProjects) { project in
                        HStack {
                            NavigationLink {
                                PostHogProjectDetail(project: project)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(project.name ?? "Project")
                                    Text(posthogDetail(project))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            PermalinkButton(
                                url: Permalink.url(from: project.dashboardURL))
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
                        PermalinkButton(url: Permalink.localServer(server))
                        if store.stoppingServerID == server.id {
                            ProgressView()
                        } else if server.pid != nil {
                            Button("Stop", systemImage: "stop.circle") {
                                requestStop(server)
                            }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(HeadroomPalette.red)
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

    @ViewBuilder
    private var xcodeBuildsSection: some View {
        let builds = store.snapshot.local?.builds ?? []
        if !builds.isEmpty {
            Section {
                ForEach(builds) { build in
                    NavigationLink {
                        LocalBuildDetail(
                            build: build,
                            hostName: serverComputerName
                        )
                    } label: {
                        HStack {
                            Circle()
                                .fill(HeadroomPalette.green)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text(build.name ?? "Xcode")
                                Text(buildDetail(build))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text(HeadroomCopy.xcodeBuilds)
                    Spacer()
                    Label(serverComputerName, systemImage: "desktopcomputer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        return bits.isEmpty ? "No stats yet" : bits.joined(separator: " · ")
    }

    private func posthogDetail(_ project: PostHogProject) -> String {
        if let error = project.error { return error }
        var bits: [String] = []
        if let today = project.eventsToday {
            bits.append("\(HeadroomFormat.compact(today)) \(project.windowLabel)")
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

    private func buildDetail(_ build: LocalBuild) -> String {
        [
            build.action,
            build.kind,
            build.ageS.map(ageLabel),
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func ageLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return HeadroomCopy.agoShort(TimeInterval(seconds))
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
