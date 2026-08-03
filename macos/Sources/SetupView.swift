import AppKit
import SwiftUI

/// The “host down” card: start the bundled host, show what we detected
/// locally, and let the user fix Sources without a trip to Settings.
///
/// First run is no longer this view's job. It moved to `WelcomeView` in its own
/// window, because a `.transient` popover cannot hold a screen someone reads
/// once and cannot point at the menu bar icon it hangs from.
struct SetupView: View {
    @ObservedObject var store: UsageStore
    var onFinished: () -> Void

    @State private var hostBusy = false
    @State private var hostMessage: String?
    @State private var hostReady = false
    @State private var setupRows: [SetupSourceRow] = []
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            hostCard
            sourcesCard
            footer
        }
        .padding(16)
        .task { await bootstrap() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start the host")
                .font(.title3.weight(.semibold))
            Text("Needs the local host on :8737. Starts at login.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hostCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: hostReady ? "checkmark.circle.fill" : "server.rack")
                    .foregroundStyle(hostReady ? HeadroomPalette.green : HeadroomPalette.orange)
                Text(hostReady ? "Host is running" : "Host isn’t running")
                    .font(.headline)
                Spacer()
            }
            if let hostMessage {
                Text(hostMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await startHost() }
                } label: {
                    if hostBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(hostReady ? "Restart host" : "Start host")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(hostBusy)

                Button("Retry check") {
                    Task { await refreshHostStatus() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(hostBusy)

                Spacer()
            }
            if let skew = store.hostSkew {
                // The store already reinstalls on sight, so this reports what
                // is happening rather than asking for a restart that ran.
                Text(skew.hostIsNewer
                     ? "\(skew.title). \(skew.summary). Quit and reopen Headroom."
                     : "\(skew.title). \(skew.summary). Replacing it now.")
                    .font(.caption2)
                    .foregroundStyle(HeadroomPalette.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if hostReady, let version = store.hostVersionLabel {
                Text(version)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(appVersionLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if !HostController.isBundled {
                Text("No bundled host. Run ./scripts/install-host.sh or use a Release .app.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What to track")
                .font(.headline)
            Text("From local sign-in. Change either list later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.orange)
            }
            if setupRows.isEmpty {
                Text(hostReady ? "Loading…" : "Start the host to detect sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SetupSourcesList(
                    rows: $setupRows,
                    enabled: hostReady && !hostBusy
                )
            }
        }
        .cardStyle()
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                Task { await saveAndFinish() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hostReady)
        }
    }

    private var appVersionLabel: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "App \(short) (\(build))"
    }

    private func bootstrap() async {
        await refreshHostStatus()
        if !hostReady, HostController.isBundled {
            await startHost()
        }
        // Everything under this card moves on its own: launchd restarts the
        // host, the store's poll loop recovers, an update lands underneath.
        // Read once and the three lines here are three different moments —
        // "Host is up" stacked over "Could not connect to the server."
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !hostBusy else { continue }
            await refreshHostStatus()
        }
    }

    private func refreshHostStatus() async {
        let ready = await HostController.isReachable()
        let changed = ready != hostReady
        hostReady = ready
        guard ready else {
            hostMessage = HostController.isBundled
                ? "Nothing is answering on :8737 yet."
                : store.errorMessage
            return
        }
        hostMessage = "Host is up on http://127.0.0.1:8737"
        // The sources list costs a fetch; only re-read it when the host came
        // back, or when we never got one.
        if changed || setupRows.isEmpty {
            await store.checkHostVersion()
            await loadSetup()
        }
    }

    /// Install the LaunchAgent and start the bundled host. Routed through the
    /// store so this can't race the automatic update the poll loop may already
    /// be running — both end up awaiting the same install.
    private func startHost() async {
        hostBusy = true
        defer { hostBusy = false }
        guard HostController.isBundled else {
            hostMessage = HostController.HostError.notBundled.errorDescription
            hostReady = false
            return
        }
        switch await store.updateHost() {
        case .ready:
            hostReady = true
            hostMessage = "Host is up on http://127.0.0.1:8737"
            await loadSetup()
        case let .foreign(build):
            // Ours started and stood down: something else owns the port. Saying
            // "up" here is how the card ends up contradicting itself.
            hostReady = true
            hostMessage = """
                Another host already owns :8737\(build.map { " (\($0))" } ?? "").
                Quit it, or run ./scripts/uninstall-host.sh, then try again.
                """
            await loadSetup()
        case .silent:
            hostReady = false
            hostMessage = store.errorMessage
                ?? "Started, but /health didn’t answer yet. Check ~/.headroom/logs/headroom.err"
        }
    }

    private func loadSetup() async {
        do {
            let payload = try await HeadroomClient().fetchSetup()
            setupRows = payload.sources
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func saveAndFinish() async {
        if hostReady, !setupRows.isEmpty {
            let map = Dictionary(uniqueKeysWithValues: setupRows.map { ($0.id, $0.enabled) })
            do {
                _ = try await HeadroomClient().setSources(map)
                await store.refresh()
            } catch {
                loadError = error.localizedDescription
                return
            }
        }
        onFinished()
    }
}

/// The grouped source toggles, shared by the welcome window and the host-down
/// card so the two lists cannot drift apart.
///
/// Quota meters and dev-tool watchers do different jobs — asking about them in
/// one flat list makes the user sort it out row by row.
struct SetupSourcesList: View {
    @Binding var rows: [SetupSourceRow]
    var enabled: Bool

    private var grouped: [(group: SourceGroup, rows: [SetupSourceRow])] {
        SourceGroup.allCases.compactMap { group in
            let matching = rows.filter { $0.sourceGroup == group }
            return matching.isEmpty ? nil : (group, matching)
        }
    }

    var body: some View {
        ForEach(grouped, id: \.group) { section in
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.group.title)
                        .font(.subheadline.weight(.semibold))
                    Text(section.group.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)

                ForEach(section.rows) { row in
                    Toggle(isOn: binding(for: row.id)) {
                        HStack {
                            Text(row.title)
                            Spacer()
                            Text(row.detected ? "Detected" : "Not found")
                                .font(.caption2)
                                .foregroundStyle(
                                    row.detected ? HeadroomPalette.green : .secondary)
                        }
                    }
                    .disabled(!enabled)
                }
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { rows.first(where: { $0.id == id })?.enabled ?? false },
            set: { value in
                if let idx = rows.firstIndex(where: { $0.id == id }) {
                    rows[idx].enabled = value
                }
            }
        )
    }
}

struct SetupSourceRow: Identifiable, Decodable, Sendable {
    var id: String
    var title: String
    var hint: String?
    var kind: String?
    /// "ai" or "devtools" — from the host registry.
    var group: String?
    var detected: Bool
    var enabled: Bool

    var sourceGroup: SourceGroup { SourceGroup(group: group, kind: kind) }
}

struct SetupPayload: Decodable, Sendable {
    var ok: Bool?
    var sources: [SetupSourceRow]
}
