import AppKit
import SwiftUI

/// First-run + “host down” onboarding: start the bundled host, show what we
/// detected locally, and let the user confirm Sources before diving in.
struct SetupView: View {
    @ObservedObject var store: UsageStore
    var isFirstRun: Bool
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
            Text(isFirstRun ? "Welcome to Headroom" : "Start the host")
                .font(.title3.weight(.semibold))
            Text(isFirstRun
                 ? "A small local Python host reads Claude / Codex / Cursor credentials you already have. We’ll start it and enable only what’s signed in."
                 : "The menu bar needs the local host on port 8737. Start it once — it stays running at login.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hostCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: hostReady ? "checkmark.circle.fill" : "server.rack")
                    .foregroundStyle(hostReady ? HeadroomPalette.green : HeadroomPalette.amber)
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
                        Text(hostReady ? "Restart host" : "Start host & keep at login")
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
            if !HostController.isBundled {
                Text("This debug build has no bundled host. From a clone run ./scripts/install-host.sh, or use a Release .app.")
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
            Text("Detected from local sign-in. You can change this later in Settings → Sources.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.amber)
            }
            if setupRows.isEmpty {
                Text(hostReady ? "Loading…" : "Start the host to detect Claude / Codex / Cursor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(setupRows) { row in
                    Toggle(isOn: binding(for: row.id)) {
                        HStack {
                            Text(row.title)
                            Spacer()
                            Text(row.detected ? "Detected" : "Not found")
                                .font(.caption2)
                                .foregroundStyle(row.detected ? HeadroomPalette.green : .secondary)
                        }
                    }
                    .disabled(!hostReady || hostBusy)
                }
            }
        }
        .cardStyle()
    }

    private var footer: some View {
        HStack {
            if isFirstRun {
                Button("Skip for now") { onFinished() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(isFirstRun ? "Continue" : "Done") {
                Task { await saveAndFinish() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hostReady && isFirstRun == false)
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { setupRows.first(where: { $0.id == id })?.enabled ?? false },
            set: { value in
                if let idx = setupRows.firstIndex(where: { $0.id == id }) {
                    setupRows[idx].enabled = value
                }
            }
        )
    }

    private func bootstrap() async {
        await refreshHostStatus()
        if !hostReady, HostController.isBundled {
            await startHost()
        } else if hostReady {
            await loadSetup()
        }
    }

    private func refreshHostStatus() async {
        hostReady = await HostController.isReachable()
        if hostReady {
            hostMessage = "http://127.0.0.1:8737"
            await loadSetup()
        } else if hostMessage == nil {
            hostMessage = store.errorMessage
        }
    }

    private func startHost() async {
        hostBusy = true
        defer { hostBusy = false }
        do {
            let path = try HostController.installAndStart()
            hostMessage = "Installed login item → \(path)"
            let ok = await HostController.waitUntilReady()
            hostReady = ok
            if ok {
                hostMessage = "Host is up on http://127.0.0.1:8737"
                await loadSetup()
                await store.refresh()
            } else {
                hostMessage = "Started, but /health didn’t answer yet. Check ~/.headroom/logs/headroom.err"
            }
        } catch {
            hostMessage = error.localizedDescription
            hostReady = false
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

struct SetupSourceRow: Identifiable, Decodable, Sendable {
    var id: String
    var title: String
    var kind: String?
    var detected: Bool
    var enabled: Bool
}

struct SetupPayload: Decodable, Sendable {
    var ok: Bool?
    var sources: [SetupSourceRow]
}
