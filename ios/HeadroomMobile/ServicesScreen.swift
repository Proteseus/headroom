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
                    .foregroundStyle(.orange)
            } else {
                ForEach(usage?.projects ?? []) { project in
                    DisclosureGroup {
                        ForEach(project.services ?? []) { service in
                            LabeledContent(
                                service.name,
                                value: service.status ?? (service.healthy == true ? "healthy" : "unhealthy")
                            )
                            .foregroundStyle(
                                service.healthy == false ? Color.red : Color.secondary
                            )
                        }
                    } label: {
                        Button {
                            if let raw = project.dashboardURL, let url = URL(string: raw) {
                                openURL(url)
                            }
                        } label: {
                            HStack {
                                Circle()
                                    .fill(project.healthy == true ? .green : .red)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading) {
                                    Text(project.name ?? project.ref)
                                        .foregroundStyle(.primary)
                                    Text([project.region, project.status].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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

    @ViewBuilder
    private var plausibleSection: some View {
        Section {
            let usage = store.snapshot.plausible
            if usage?.configured != true {
                Text(usage?.error ?? "Connect Plausible on the Mac.")
                    .foregroundStyle(.secondary)
            } else if usage?.ok != true {
                Label(usage?.error ?? "Plausible unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
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
                                        ? Color.green
                                        : Color.secondary.opacity(0.3)
                                )
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading) {
                                Text(site.domain)
                                    .foregroundStyle(.primary)
                                Text(plausibleDetail(site))
                                    .font(.caption)
                                    .foregroundStyle(
                                        site.error == nil ? Color.secondary : Color.orange
                                    )
                            }
                            Spacer()
                            if let live = site.realtime, live > 0 {
                                Text("\(live) live")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.green)
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
                    Text("\(compactNumber(today)) \(label)")
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
                            .fill(server.reachable == false ? .red : .green)
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
                            .foregroundStyle(.red)
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
            bits.append("\(compactNumber(today)) \(site.windowLabel)")
        }
        if let week = site.visitors7d, site.range != "7d" {
            bits.append("\(compactNumber(week)) / 7d")
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
