import AppKit
import Security
import SwiftUI

@main
struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let store = UsageStore()
        self.store = store
        statusController = StatusItemController(store: store)

        if let exportDir = Self.argValue("--export-screenshots") {
            // Keep the process alive until export finishes; accessory apps can
            // otherwise exit before a detached Task runs.
            DispatchQueue.main.async {
                Task { @MainActor in
                    await Self.exportScreenshots(
                        to: exportDir,
                        fixture: Self.argValue("--fixture"),
                        store: store
                    )
                    NSApp.terminate(nil)
                }
            }
            return
        }

        store.start()
    }

    private static func argValue(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: flag), args.indices.contains(idx + 1)
        else { return nil }
        return args[idx + 1]
    }

    private static func exportScreenshots(
        to directory: String,
        fixture: String?,
        store: UsageStore
    ) async {
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: out, withIntermediateDirectories: true)
        } catch {
            fputs("mkdir failed: \(error)\n", stderr)
            return
        }

        AttentionAck.dismissedFingerprint = nil
        UserDefaults.standard.set("overview", forKey: "selectedDashboard")

        if let fixture {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: fixture))
                let snapshot = try JSONDecoder().decode(
                    UsageSnapshot.self, from: data)
                store.applySnapshot(snapshot, healthy: true)
            } catch {
                fputs("fixture decode failed: \(error)\n", stderr)
                return
            }
        } else {
            await store.refresh()
        }

        // Let SwiftUI settle bindings before rasterizing.
        try? await Task.sleep(for: .milliseconds(500))

        let dashboard = DashboardView(store: store)
            .environment(\.colorScheme, .light)
        if let image = renderHosting(dashboard, size: NSSize(width: 390, height: 620)) {
            writePNG(image, to: out.appendingPathComponent("macos-popover.png"))
        } else {
            fputs("dashboard render returned nil\n", stderr)
        }

        let attention = store.snapshot.attention
        let showPip = AttentionAck.shouldShowPip(for: attention)
        let icon = MeterIconRenderer.render(
            snapshot: store.snapshot,
            healthy: store.errorMessage == nil,
            attentionLevel: showPip ? attention?.level : nil
        )
        if let rep = scaleIconRep(icon, pixels: 72),
           let png = rep.representation(using: .png, properties: [:]) {
            let iconURL = out.appendingPathComponent("macos-menubar-icon.png")
            do {
                try png.write(to: iconURL)
                fputs("wrote \(iconURL.path)\n", stderr)
            } catch {
                fputs("icon write failed: \(error)\n", stderr)
            }
        } else {
            fputs("icon scale failed\n", stderr)
        }
        fputs("exported screenshots to \(directory)\n", stderr)
    }

    private static func scaleIconRep(_ icon: NSImage, pixels: Int) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .none
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
        // Template icons draw black; force a concrete appearance so bars are
        // visible when composited onto a light menubar strip.
        icon.isTemplate = false
        icon.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func renderHosting<V: View>(
        _ view: V,
        size: NSSize
    ) -> NSImage? {
        let host = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func writePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            fputs("failed to encode \(url.lastPathComponent)\n", stderr)
            return
        }
        do {
            try png.write(to: url)
            fputs("wrote \(url.path)\n", stderr)
        } catch {
            fputs("write failed \(url.path): \(error)\n", stderr)
        }
    }
}

private struct SettingsView: View {
    @AppStorage("usageEndpoint")
    private var endpoint = "http://127.0.0.1:8737/usage"
    @AppStorage("refreshInterval")
    private var refreshInterval = 60
    @AppStorage("activityRowLimit")
    private var activityRowLimit = 8
    @AppStorage("serverRowLimit")
    private var serverRowLimit = 5
    @AppStorage("confirmServerStops")
    private var confirmServerStops = true
    @AppStorage("supabaseRowLimit")
    private var supabaseRowLimit = 6

    @State private var sources: [SyncSource] = []
    @State private var sourcesMessage: String?
    @State private var isSyncing = false
    @State private var togglingSourceID: String?

    @State private var supabaseToken = ""
    @State private var tokenStored = false
    @State private var supabaseMessage: String?

    @State private var githubToken = ""
    @State private var githubTokenStored = false
    @State private var githubMessage: String?

    @State private var hostToken = ""
    @State private var hostTokenStored = false

    private var tokenDraft: String {
        supabaseToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var githubTokenDraft: String {
        githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var client: HeadroomClient { HeadroomClient(endpoint: endpoint) }

    /// The host waves loopback callers through, so the token only matters when
    /// pointing this app at another machine.
    private var endpointIsRemote: Bool {
        guard let host = URL(string: endpoint)?.host() else { return false }
        return !(host == "127.0.0.1" || host == "localhost" || host == "::1")
    }

    var body: some View {
        Form {
            Section {
                TextField(text: $endpoint) {
                    Text("Endpoint")
                }
                Picker(selection: $refreshInterval) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                } label: {
                    Text("Refresh")
                }
                if endpointIsRemote {
                    SecureField("Host token", text: $hostToken)
                    HStack {
                        Button(hostTokenStored ? "Replace token" : "Save token") {
                            saveHostToken()
                        }
                        .disabled(hostToken.trimmingCharacters(
                            in: .whitespacesAndNewlines).isEmpty)
                        if hostTokenStored {
                            Button("Forget", role: .destructive) {
                                TokenStore.host.delete()
                                hostTokenStored = false
                                hostToken = ""
                            }
                        }
                        Spacer()
                        Text(hostTokenStored ? "Keychain" : "Not set")
                            .font(.caption)
                            .foregroundStyle(
                                hostTokenStored
                                    ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(Color.orange))
                    }
                }
            } header: {
                Text("Backend")
            } footer: {
                Text(endpointIsRemote
                     ? "Remote hosts require the token from ~/.headroom/token."
                     : "Mac and ESP32 both read this host. Source toggles also hide ESP32 pages.")
            }

            Section {
                if sources.isEmpty {
                    Text(sourcesMessage ?? "Waiting for host…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sources) { source in
                        SourceRow(
                            source: source,
                            isBusy: togglingSourceID == source.id || isSyncing,
                            onToggle: { enabled in
                                Task { await setSource(source.id, enabled: enabled) }
                            },
                            onRefresh: {
                                Task { await refreshSources([source.id]) }
                            }
                        )
                    }
                }

                Button {
                    Task { await refreshSources(nil) }
                } label: {
                    HStack {
                        Text("Refresh all sources")
                        Spacer()
                        if isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isSyncing || sources.isEmpty)

                if let sourcesMessage {
                    Text(sourcesMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("ESP32 footer dots mirror this list. Long-press Home on glance forces a sync.")
            }

            Section {
                LabeledContent("Status") {
                    Text(tokenStored ? "Keychain" : "Not connected")
                        .foregroundStyle(tokenStored ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
                SecureField("sbp_… or access token", text: $supabaseToken)
                    .onSubmit {
                        if !tokenDraft.isEmpty { saveSupabaseToken() }
                    }
                HStack {
                    if tokenDraft.isEmpty {
                        Button("Refresh") {
                            Task { await refreshSources(["supabase"]) }
                        }
                        .disabled(!tokenStored || isSyncing)
                    } else {
                        Button(tokenStored ? "Replace" : "Connect") {
                            saveSupabaseToken()
                        }
                        .disabled(isSyncing)
                        .keyboardShortcut(.defaultAction)
                    }
                    if tokenStored {
                        Button("Disconnect", role: .destructive) {
                            disconnectSupabase()
                        }
                        .disabled(isSyncing)
                    }
                    Spacer()
                    Button("Create token…") {
                        openURL("https://supabase.com/dashboard/account/tokens")
                    }
                    .buttonStyle(.link)
                }
                if let supabaseMessage {
                    Text(supabaseMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Supabase")
            } footer: {
                Text("PAT stays in Keychain and never appears in /usage.")
            }

            Section {
                LabeledContent("Status") {
                    Text(githubTokenStored ? "Keychain" : "Not connected")
                        .foregroundStyle(githubTokenStored ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
                SecureField("ghp_… (repo + actions:read)", text: $githubToken)
                    .onSubmit {
                        if !githubTokenDraft.isEmpty { saveGitHubToken() }
                    }
                HStack {
                    if githubTokenDraft.isEmpty {
                        Button("Refresh") {
                            Task { await refreshSources(["github"]) }
                        }
                        .disabled(!githubTokenStored || isSyncing)
                    } else {
                        Button(githubTokenStored ? "Replace" : "Connect") {
                            saveGitHubToken()
                        }
                        .disabled(isSyncing)
                    }
                    if githubTokenStored {
                        Button("Disconnect", role: .destructive) {
                            disconnectGitHub()
                        }
                        .disabled(isSyncing)
                    }
                    Spacer()
                    Button("Create token…") {
                        openURL("https://github.com/settings/tokens")
                    }
                    .buttonStyle(.link)
                }
                if let githubMessage {
                    Text(githubMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("GitHub Actions")
            } footer: {
                Text("Watches repos matching github_org_prefix / github_always_repos in ~/.headroom/config.json. Failed and running workflows show under GitHub.")
            }

            Section("Dashboard") {
                Stepper(
                    "GitHub rows: \(activityRowLimit)",
                    value: $activityRowLimit,
                    in: 3...14
                )
                Stepper(
                    "Local servers: \(serverRowLimit)",
                    value: $serverRowLimit,
                    in: 1...8
                )
                Stepper(
                    "Supabase projects: \(supabaseRowLimit)",
                    value: $supabaseRowLimit,
                    in: 1...20
                )
                Toggle("Confirm before stopping servers", isOn: $confirmServerStops)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .task {
            tokenStored = TokenStore.supabase.exists()
            githubTokenStored = TokenStore.github.exists()
            hostTokenStored = TokenStore.host.exists()
            await reloadSources()
        }
    }

    private func saveHostToken() {
        let token = hostToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try TokenStore.host.save(token)
            hostToken = ""
            hostTokenStored = true
            Task { await reloadSources() }
        } catch {
            sourcesMessage = error.localizedDescription
        }
    }

    private func saveSupabaseToken() {
        let token = tokenDraft
        guard !token.isEmpty else { return }
        do {
            try TokenStore.supabase.save(token)
            supabaseToken = ""
            tokenStored = true
            supabaseMessage = "Saved — refreshing…"
            Task { await refreshSources(["supabase"]) }
        } catch {
            supabaseMessage = error.localizedDescription
        }
    }

    private func disconnectSupabase() {
        TokenStore.supabase.delete()
        tokenStored = false
        supabaseToken = ""
        supabaseMessage = "Disconnected"
        Task { await refreshSources(["supabase"]) }
    }

    private func saveGitHubToken() {
        let token = githubTokenDraft
        guard !token.isEmpty else { return }
        do {
            try TokenStore.github.save(token)
            githubToken = ""
            githubTokenStored = true
            githubMessage = "Saved — refreshing Actions…"
            Task { await refreshSources(["github"]) }
        } catch {
            githubMessage = error.localizedDescription
        }
    }

    private func disconnectGitHub() {
        TokenStore.github.delete()
        githubTokenStored = false
        githubToken = ""
        githubMessage = "Disconnected"
        Task { await refreshSources(["github"]) }
    }

    private func setSource(_ id: String, enabled: Bool) async {
        togglingSourceID = id
        defer { togglingSourceID = nil }
        do {
            var map = Dictionary(
                uniqueKeysWithValues: sources.map { ($0.id, $0.enabled ?? true) })
            map[id] = enabled
            _ = try await client.setSources(map)
            // Toggling on kicks a refresh host-side; wait for it to land rather
            // than guessing how long it takes.
            if enabled {
                await client.waitForRefresh(sources: [id])
            }
            await reloadSources()
            sourcesMessage = enabled
                ? "Enabled \(id) — ESP32 will show it on next poll."
                : "Disabled \(id) — ESP32 will hide that page."
        } catch {
            sourcesMessage = error.localizedDescription
        }
    }

    private func refreshSources(_ ids: [String]?) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await client.refresh(sources: ids)
            // /sync/refresh answers 202 and works in the background.
            await client.waitForRefresh(sources: ids)
            await reloadSources()
            if ids == ["supabase"] {
                supabaseMessage = sources
                    .first(where: { $0.id == "supabase" })?
                    .detail ?? "Supabase refreshed"
            }
            sourcesMessage = "Synced."
        } catch {
            sourcesMessage = error.localizedDescription
        }
        tokenStored = TokenStore.supabase.exists()
        githubTokenStored = TokenStore.github.exists()
    }

    private func reloadSources() async {
        do {
            let snapshot = try await client.fetchUsage()
            sources = snapshot.sources ?? []
            if sources.isEmpty {
                sourcesMessage = "Host has no sources payload — restart com.mz.headroom."
            }
        } catch {
            sourcesMessage = error.localizedDescription
        }
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SourceRow: View {
    let source: SyncSource
    let isBusy: Bool
    let onToggle: (Bool) -> Void
    let onRefresh: () -> Void

    private var enabled: Bool { source.enabled ?? true }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title ?? source.id)
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(
                        source.ok == true || !enabled
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(Color.orange)
                    )
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isBusy || !enabled)
            .help("Force refresh")

            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { enabled },
                    set: { onToggle($0) }
                )
            )
            .labelsHidden()
            .disabled(isBusy)
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .opacity(enabled ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let detail = source.detail ?? source.hint ?? source.error {
            parts.append(detail)
        }
        if let age = source.ageS {
            parts.append(ageLabel(age))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var dotColor: Color {
        if !enabled { return .secondary }
        if source.ok == true {
            return source.stale == true ? .orange : .green
        }
        return .red
    }

    private func ageLabel(_ age: Int) -> String {
        let stale = source.stale == true
        if age < 5 {
            return stale ? "stale · just now" : "just now"
        }
        if age < 60 {
            return stale ? "\(age)s stale" : "\(age)s ago"
        }
        let minutes = age / 60
        return stale ? "\(minutes)m stale" : "\(minutes)m ago"
    }
}

