import LocalAuthentication
import SwiftUI

struct ServicesScreen: View {
    @ObservedObject var store: MobileUsageStore
    @Environment(\.openURL) private var openURL
    @State private var serverToStop: LocalServer?
    @State private var controlError: String?

    var body: some View {
        List {
            ArchivedDataNotice(store: store)
            supabaseSection
            plausibleSection
            localServersSection
        }
        .navigationTitle(HeadroomCopy.services)
        .refreshable { await store.refresh(forceServerSync: true) }
        .confirmationDialog(
            "Stop \(serverToStop?.name ?? "server")?",
            isPresented: Binding(
                get: { serverToStop != nil },
                set: { if !$0 { serverToStop = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stop server", role: .destructive) {
                guard let server = serverToStop else { return }
                serverToStop = nil
                Task { await authenticateAndStop(server) }
            }
            Button("Cancel", role: .cancel) { serverToStop = nil }
        } message: {
            Text("Stops the process on your Mac.")
        }
        .alert(
            "Couldn’t complete action",
            isPresented: Binding(
                get: { controlError != nil },
                set: { if !$0 { controlError = nil } }
            )
        ) {
            Button("OK") { controlError = nil }
        } message: {
            Text(controlError ?? "")
        }
    }

    @ViewBuilder
    private var supabaseSection: some View {
        Section {
            let usage = store.snapshot.supabase
            if usage?.configured != true {
                Text(usage?.error ?? "Connect Supabase on the Mac.")
                    .foregroundStyle(.secondary)
            } else if usage?.ok != true {
                Label(usage?.error ?? "Supabase unavailable", systemImage: "exclamationmark.triangle")
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
                Text("Supabase")
                Spacer()
                if let count = store.snapshot.supabase?.projectCount {
                    Text("\(count) projects")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Security advisor findings under each project, worst first. Tapping one
    /// opens Supabase's remediation doc, or the project's advisor page.
    @ViewBuilder
    private func lintRows(_ project: SupabaseProject) -> some View {
        if let failure = project.advisorError {
            Label("Advisors unavailable · \(failure)", systemImage: "shield.slash")
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
        Section {
            let usage = store.snapshot.plausible
            if usage?.configured != true {
                Text(usage?.error ?? "Connect Plausible on the Mac.")
                    .foregroundStyle(.secondary)
            } else if usage?.ok != true {
                Label(usage?.error ?? "Plausible unavailable", systemImage: "exclamationmark.triangle")
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
                Text("Plausible")
                Spacer()
                if let today = store.snapshot.plausible?.visitorsToday {
                    let label = store.snapshot.plausible?.windowLabel ?? "today"
                    Text("\(HeadroomFormat.compact(today)) \(label)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var localServersSection: some View {
        Section(HeadroomCopy.localServers) {
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
                                serverToStop = server
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
        }
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

    @MainActor
    private func authenticateAndStop(_ server: LocalServer) async {
        do {
            try await MobileControlAuthorizer.authorize(
                reason: "Stop \(server.name ?? "this server") on your Mac"
            )
            await store.stopServer(server)
        } catch {
            controlError = error.localizedDescription
        }
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
