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
    private var wakeObserver: NSObjectProtocol?

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
        // After sleep the poll loop may still be on the idle cadence, and the
        // host's own poller is cold — force a source sync so bars move again.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak store] _ in
            Task { @MainActor in
                store?.noteInteraction()
                await store?.refresh(forceSync: true)
            }
        }
        Task { @MainActor in
            await Self.ensureHostRunning(store: store)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// If nothing answers on :8737 and this .app has a bundled host, install
    /// the LaunchAgent and wait for /health so first open isn't an error card.
    private static func ensureHostRunning(store: UsageStore) async {
        if await HostController.isReachable() {
            await store.refresh()
            // launchd kept an older host alive across this app's update? Say so
            // rather than rendering its stale document as if it were current.
            await store.checkHostVersion()
            return
        }
        guard HostController.isBundled else { return }
        do {
            _ = try HostController.installAndStart()
            if await HostController.waitUntilReady() {
                await store.refresh()
                await store.checkHostVersion()
            }
        } catch {
            // SetupView surfaces the error; don't crash launch.
        }
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
        // Skip the first-run Welcome sheet so the overview is what we ship.
        UserDefaults.standard.set(true, forKey: "setupCompleted")

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
        let showPip = attention?.isWarning == true
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
    @AppStorage("plausibleRowLimit")
    private var plausibleRowLimit = 6

    @State private var sources: [SyncSource] = []
    @State private var sourcesMessage: String?
    @State private var isSyncing = false
    @State private var togglingSourceID: String?
    /// Row the pointer is dragging over, for the insertion line.
    @State private var dropTargetID: String?

    @State private var supabaseToken = ""
    @State private var tokenStored = false
    @State private var supabaseMessage: String?

    @State private var plausibleToken = ""
    @State private var plausibleTokenStored = false
    @State private var plausibleMessage: String?
    @State private var plausibleRange = "24h"

    @State private var githubToken = ""
    @State private var githubTokenStored = false
    @State private var githubMessage: String?
    /// Comma-separated drafts, so one field edits a list without a row editor.
    @State private var githubOwners = ""
    @State private var githubAlwaysRepos = ""
    @State private var githubMaxDiscovered = 6
    @State private var githubWatching: [String] = []
    @State private var githubDevRoot = "~/Dev"
    @State private var savingGitHubWatch = false

    @State private var hostToken = ""
    @State private var hostTokenStored = false
    @State private var mobileTokenMessage: String?
    @State private var mobilePermissions = MobilePermissions.allEnabled
    @State private var changingMobilePermission: MobilePermission?

    private var tokenDraft: String {
        supabaseToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var plausibleTokenDraft: String {
        plausibleToken.trimmingCharacters(in: .whitespacesAndNewlines)
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
                                    : AnyShapeStyle(HeadroomPalette.amber))
                    }
                }
            } header: {
                Text("Backend")
            } footer: {
                Text(endpointIsRemote
                     ? "Remote hosts need the host token (~/.headroom/token) — not the mobile token used by iPhone."
                     : "Mac, iPhone, and ESP32 all read this host. If it’s down, tap Start host or run ./scripts/install-host.sh from a clone. Source toggles also hide ESP32 pages.")
            }

            Section {
                LabeledContent("Discovery") {
                    Text("Automatic on local Wi‑Fi")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Copy mobile token") {
                        copyMobileToken()
                    }
                    Spacer()
                    if let mobileTokenMessage {
                        Text(mobileTokenMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(MobilePermission.allCases, id: \.rawValue) { permission in
                    HStack {
                        Text(permission.title)
                        Spacer()
                        if changingMobilePermission == permission {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Toggle(
                                permission.title,
                                isOn: Binding(
                                    get: { mobilePermissions[permission] },
                                    set: { enabled in
                                        Task {
                                            await setMobilePermission(
                                                permission,
                                                enabled: enabled
                                            )
                                        }
                                    }
                                )
                            )
                            .labelsHidden()
                        }
                    }
                }
            } header: {
                Text("iPhone pairing")
            } footer: {
                Text("Copy mobile token (~/.headroom/mobile-token), open Headroom on iPhone, tap this Mac, paste once. Do not use the host token (that’s for the ESP32). Tailscale names remain available as a fallback.")
            }

            if sources.isEmpty {
                Section {
                    Text(sourcesMessage ?? "Waiting for host…")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Sources")
                }
            } else {
                sourceGroupSection(.ai)
                sourceGroupSection(.devtools)
            }

            Section {
                LabeledContent("Status") {
                    Text(tokenStored ? "Keychain" : "Not connected")
                        .foregroundStyle(tokenStored ? AnyShapeStyle(.secondary) : AnyShapeStyle(HeadroomPalette.amber))
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
                Text("PAT stays in Keychain.")
            }

            Section {
                LabeledContent("Status") {
                    Text(plausibleTokenStored ? "Keychain" : "Not connected")
                        .foregroundStyle(plausibleTokenStored
                                         ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(HeadroomPalette.amber))
                }
                SecureField("Stats API key", text: $plausibleToken)
                    .onSubmit {
                        if !plausibleTokenDraft.isEmpty { savePlausibleToken() }
                    }
                Picker("Window", selection: Binding(
                    get: { plausibleRange },
                    set: { newValue in
                        guard newValue != plausibleRange else { return }
                        plausibleRange = newValue
                        Task { await applyPlausibleRange(newValue) }
                    }
                )) {
                    Text("Today").tag("day")
                    Text("Last 24 hours").tag("24h")
                    Text("Last 7 days").tag("7d")
                    Text("Last 30 days").tag("30d")
                }
                .disabled(isSyncing)
                HStack {
                    if plausibleTokenDraft.isEmpty {
                        Button("Refresh") {
                            Task { await refreshSources(["plausible"]) }
                        }
                        .disabled(!plausibleTokenStored || isSyncing)
                    } else {
                        Button(plausibleTokenStored ? "Replace" : "Connect") {
                            savePlausibleToken()
                        }
                        .disabled(isSyncing)
                    }
                    if plausibleTokenStored {
                        Button("Disconnect", role: .destructive) {
                            disconnectPlausible()
                        }
                        .disabled(isSyncing)
                    }
                    Spacer()
                    Button("Create key…") {
                        openURL("https://plausible.io/settings#api-keys")
                    }
                    .buttonStyle(.link)
                }
                if let plausibleMessage {
                    Text(plausibleMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Plausible")
            } footer: {
                Text("API key stays in Keychain.")
            }

            Section {
                LabeledContent("Status") {
                    Text(githubTokenStored ? "Keychain" : "Not connected")
                        .foregroundStyle(githubTokenStored ? AnyShapeStyle(.secondary) : AnyShapeStyle(HeadroomPalette.amber))
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
                Divider()
                TextField(
                    "Owners",
                    text: $githubOwners,
                    prompt: Text("acme/, ada/ (blank watches every repo found)")
                )
                TextField(
                    "Always watch",
                    text: $githubAlwaysRepos,
                    prompt: Text("acme/api, ada/site")
                )
                Stepper(
                    "Discover up to \(githubMaxDiscovered) repos",
                    value: $githubMaxDiscovered,
                    in: 0...50
                )
                HStack {
                    Button("Save repos") {
                        Task { await saveGitHubWatch() }
                    }
                    .disabled(savingGitHubWatch)
                    if savingGitHubWatch {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if !githubWatching.isEmpty {
                    LabeledContent("Watching") {
                        Text(githubWatching.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text(HeadroomCopy.githubActions)
            } footer: {
                Text("Owners filter the repos found under \(githubDevRoot). Always-watch takes owner/name and ignores that filter. Failures show under \(HeadroomCopy.activity).")
            }

            Section {
                Button {
                    Task { await refreshSources(nil) }
                } label: {
                    HStack {
                        Text(HeadroomCopy.refreshAll)
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
                Text("Sync")
            } footer: {
                Text("Refreshes both lists at once.")
            }

            Section("Dashboard") {
                Stepper(
                    "\(HeadroomCopy.activity) rows: \(activityRowLimit)",
                    value: $activityRowLimit,
                    in: 3...14
                )
                Stepper(
                    "\(HeadroomCopy.localServers): \(serverRowLimit)",
                    value: $serverRowLimit,
                    in: 1...8
                )
                Stepper(
                    "Supabase projects: \(supabaseRowLimit)",
                    value: $supabaseRowLimit,
                    in: 1...20
                )
                Stepper(
                    "Plausible sites: \(plausibleRowLimit)",
                    value: $plausibleRowLimit,
                    in: 1...20
                )
                Toggle("Confirm before stopping servers", isOn: $confirmServerStops)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
        .background(SettingsWindowConfigurator())
        .task {
            tokenStored = TokenStore.supabase.exists()
            plausibleTokenStored = TokenStore.plausible.exists()
            githubTokenStored = TokenStore.github.exists()
            hostTokenStored = TokenStore.host.exists()
            await reloadSources()
            await reloadMobilePermissions()
            await reloadGitHubWatch()
        }
    }

    /// One toggle list per `SourceGroup`. AI tools meter plans you're signed
    /// into; dev tools watch projects and want the keys in the sections below.
    @ViewBuilder
    private func sourceGroupSection(_ group: SourceGroup) -> some View {
        let rows = sources.filter { $0.sourceGroup == group }
        if !rows.isEmpty {
            Section {
                ForEach(rows) { source in
                    SourceRow(
                        source: source,
                        isBusy: togglingSourceID == source.id || isSyncing,
                        // Position only means something where it picks the
                        // top 3 — the metered providers.
                        isDraggable: group == .ai,
                        isDropTarget: dropTargetID == source.id,
                        onToggle: { enabled in
                            Task { await setSource(source.id, enabled: enabled) }
                        },
                        onRefresh: {
                            Task { await refreshSources([source.id]) }
                        },
                        onNudge: { offset in
                            Task { await nudgeSource(source.id, by: offset) }
                        }
                    )
                    .modifier(DragReorder(
                        enabled: group == .ai,
                        id: source.id,
                        onTargeted: { targeted in
                            dropTargetID = targeted ? source.id : nil
                        },
                        onDrop: { dragged in
                            dropTargetID = nil
                            Task { await moveSource(dragged, before: source.id) }
                        }
                    ))
                }
            } header: {
                Text(group.title)
            } footer: {
                Text(group == .ai
                     ? "\(group.subtitle) Drag to reorder — the top \(focusLimit) fill the menu bar, the widget, and the board."
                     : "\(group.subtitle) ESP32 dots mirror this list.")
            }
        }
    }

    /// Mirrors `sources_config.FOCUS_LIMIT`.
    private var focusLimit: Int { 3 }

    private var pinnedAIOrder: [String] {
        sources.filter { $0.sourceGroup == .ai }.map(\.id)
    }

    /// Drop `dragged` into `target`'s slot. The list sent is the whole AI
    /// group including disabled rows — a provider you turned off keeps its
    /// place rather than sinking to the bottom.
    private func moveSource(_ dragged: String, before target: String) async {
        guard dragged != target else { return }
        var order = pinnedAIOrder
        guard let from = order.firstIndex(of: dragged) else { return }
        order.remove(at: from)
        guard let to = order.firstIndex(of: target) else { return }
        order.insert(dragged, at: to)
        await commitOrder(order, movedID: dragged)
    }

    /// Keyboard / VoiceOver path to the same reorder, so pinning isn't
    /// drag-only.
    private func nudgeSource(_ id: String, by offset: Int) async {
        var order = pinnedAIOrder
        guard let from = order.firstIndex(of: id) else { return }
        let to = from + offset
        guard order.indices.contains(to) else { return }
        order.swapAt(from, to)
        await commitOrder(order, movedID: id)
    }

    private func commitOrder(_ order: [String], movedID: String) async {
        togglingSourceID = movedID
        defer { togglingSourceID = nil }
        // Reordering is local bookkeeping — nothing to refetch.
        do {
            _ = try await client.setSourceOrder(order)
            await reloadSources()
            sourcesMessage = "Reordered — top \(focusLimit) drive the menu bar."
        } catch {
            sourcesMessage = error.localizedDescription
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

    private func reloadMobilePermissions() async {
        if let permissions = try? await client.fetchMobilePermissions() {
            mobilePermissions = permissions
        }
    }

    private func setMobilePermission(
        _ permission: MobilePermission,
        enabled: Bool
    ) async {
        guard changingMobilePermission == nil else { return }
        changingMobilePermission = permission
        defer { changingMobilePermission = nil }
        var updated = mobilePermissions
        updated[permission] = enabled
        do {
            mobilePermissions = try await client.setMobilePermissions(updated)
        } catch {
            mobileTokenMessage = error.localizedDescription
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

    private func savePlausibleToken() {
        let token = plausibleTokenDraft
        guard !token.isEmpty else { return }
        do {
            try TokenStore.plausible.save(token)
            plausibleToken = ""
            plausibleTokenStored = true
            plausibleMessage = "Saved — refreshing…"
            Task { await refreshSources(["plausible"]) }
        } catch {
            plausibleMessage = error.localizedDescription
        }
    }

    private func disconnectPlausible() {
        TokenStore.plausible.delete()
        plausibleTokenStored = false
        plausibleToken = ""
        plausibleMessage = "Disconnected"
        Task { await refreshSources(["plausible"]) }
    }

    private func applyPlausibleRange(_ range: String) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let saved = try await client.setPlausibleRange(range)
            plausibleRange = saved
            await client.waitForRefresh(sources: ["plausible"])
            await reloadSources()
            plausibleMessage = sources
                .first(where: { $0.id == "plausible" })?
                .detail ?? "Window updated"
        } catch {
            plausibleMessage = error.localizedDescription
        }
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

    private func reloadGitHubWatch() async {
        guard let watch = try? await client.fetchGitHubWatch() else { return }
        applyGitHubWatch(watch)
    }

    private func applyGitHubWatch(_ watch: GitHubWatch) {
        githubOwners = watch.owners.joined(separator: ", ")
        githubAlwaysRepos = watch.alwaysRepos.joined(separator: ", ")
        githubMaxDiscovered = watch.maxDiscovered
        githubWatching = watch.watching
        if let root = watch.devRoot, !root.isEmpty { githubDevRoot = root }
    }

    /// Both fields take a comma- or newline-separated list; the host does the
    /// real validation and says which entry it refused.
    private func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func saveGitHubWatch() async {
        savingGitHubWatch = true
        defer { savingGitHubWatch = false }
        do {
            let watch = try await client.setGitHubWatch(
                owners: splitList(githubOwners),
                alwaysRepos: splitList(githubAlwaysRepos),
                maxDiscovered: githubMaxDiscovered
            )
            applyGitHubWatch(watch)
            githubMessage = watch.watching.isEmpty
                ? "Saved. Nothing matched under \(githubDevRoot) yet."
                : "Watching \(watch.watching.count) "
                    + (watch.watching.count == 1 ? "repo." : "repos.")
            await refreshSources(["github"])
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
            if ids == ["plausible"] {
                plausibleMessage = sources
                    .first(where: { $0.id == "plausible" })?
                    .detail ?? "Plausible refreshed"
            }
            sourcesMessage = "Synced."
        } catch {
            sourcesMessage = error.localizedDescription
        }
        tokenStored = TokenStore.supabase.exists()
        plausibleTokenStored = TokenStore.plausible.exists()
        githubTokenStored = TokenStore.github.exists()
    }

    private func reloadSources() async {
        do {
            let snapshot = try await client.fetchUsage()
            sources = snapshot.sources ?? []
            if let range = snapshot.plausible?.range {
                plausibleRange = range
            }
            if sources.isEmpty {
                sourcesMessage = "Host has no sources payload — restart com.centaur-labs.headroom."
            }
        } catch {
            sourcesMessage = error.localizedDescription
        }
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyMobileToken() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".headroom/mobile-token")
        guard let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            mobileTokenMessage = "Start the host first"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        mobileTokenMessage = "Copied"
    }
}

/// SwiftUI's Settings scene is panel-like in a menu-bar app. Promote it to a
/// regular, floating window and activate the app when the window is shown.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowObserverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class SettingsWindowObserverView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.title = "Headroom Settings"
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.styleMask.insert([
            .titled, .closable, .miniaturizable, .resizable,
        ])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Row-to-row drag reordering.
///
/// A grouped `Form` section is not a `List`, so `.onMove` gives no drag
/// handles here. `.draggable` + `.dropDestination` work in any container and
/// keep the Form styling — the payload is just the source id.
private struct DragReorder: ViewModifier {
    let enabled: Bool
    let id: String
    let onTargeted: (Bool) -> Void
    let onDrop: (String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(id) {
                    // Dragging the row itself would drag the live toggle.
                    Label(id.capitalized, systemImage: "line.3.horizontal")
                        .padding(6)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first else { return false }
                    onDrop(dragged)
                    return true
                } isTargeted: { targeted in
                    onTargeted(targeted)
                }
        } else {
            content
        }
    }
}

private struct SourceRow: View {
    let source: SyncSource
    let isBusy: Bool
    var isDraggable = false
    var isDropTarget = false
    let onToggle: (Bool) -> Void
    let onRefresh: () -> Void
    /// -1 up, +1 down. Keyboard / VoiceOver equivalent of the drag.
    var onNudge: ((Int) -> Void)?

    private var enabled: Bool { source.enabled ?? true }

    var body: some View {
        HStack(spacing: 10) {
            if isDraggable {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Drag to reorder")
                    .accessibilityHidden(true)
            }

            // Brand fill, health as the ring around it — one dot, both facts.
            // Without a brand the fill *is* the health color, so nothing is
            // lost on rows the registry gives no accent.
            Circle()
                .fill(brandColor ?? statusColor)
                .frame(width: 9, height: 9)
                .overlay {
                    if brandColor != nil {
                        Circle()
                            .strokeBorder(statusColor, lineWidth: 1.5)
                            .frame(width: 15, height: 15)
                    }
                }
                .frame(width: 16, height: 16)
                .accessibilityLabel(statusLabel)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title ?? source.id)
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(
                        source.ok == true || !enabled
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(HeadroomPalette.amber)
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
        // Drag is the affordance; these keep reordering reachable without a
        // pointer, and give the drop target a visible insertion line.
        .accessibilityAction(named: "Move up") { onNudge?(-1) }
        .accessibilityAction(named: "Move down") { onNudge?(1) }
        .overlay(alignment: .top) {
            if isDropTarget {
                Rectangle()
                    .fill(HeadroomPalette.green)
                    .frame(height: 2)
                    .offset(y: -4)
            }
        }
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

    /// Color is not the only carrier of health — VoiceOver gets it in words.
    private var statusLabel: String {
        if !enabled { return "Off" }
        if source.ok != true { return "Error" }
        return source.stale == true ? "Stale" : "Healthy"
    }

    /// Health: green / amber / red, the same words the rest of the app uses.
    private var statusColor: Color {
        if !enabled { return HeadroomPalette.dim }
        if source.ok == true {
            return source.stale == true ? HeadroomPalette.amber : HeadroomPalette.green
        }
        return HeadroomPalette.red
    }

    /// The registry's brand accent, so a row is identifiable at a glance in a
    /// list eight providers long. Rows with no brand keep the status color —
    /// health then reads off the fill exactly as it used to.
    private var brandColor: Color? {
        guard enabled else { return nil }
        return HeadroomPalette.color(hex: source.accent)
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
