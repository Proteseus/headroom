import AppKit
import SwiftUI

/// Mac Settings: sidebar of intent panes + detail Forms, nested Integrations
/// and Other Macs. Same taxonomy as iOS (`SettingsDestination`); accessory
/// apps keep the system `Settings` scene so SettingsLink / ⌘, keep working.
struct SettingsView: View {
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
    @AppStorage(ResetNotifications.defaultsKey)
    private var notifyOnQuotaReset = false

    @State private var sources: [SyncSource] = []
    @State private var sourcesMessage: String?
    @State private var isSyncing = false
    @State private var togglingSourceID: String?
    /// Service the pointer is dragging over, for the insertion line.
    @State private var dropTargetID: String?
    /// Live usage by account id — feeds the Active card's bars.
    @State private var usageProviders: [String: QuotaProviderInfo] = [:]
    /// Multi-account capability + current logins, from `/accounts`. Empty on
    /// hosts predating the endpoint, which simply hides "Add account…".
    @State private var accountProviders: [AccountProvider] = []
    /// Credential detection from `/setup`, for the Library's dimmed chips.
    @State private var detectedSources: [String: Bool] = [:]
    /// Provider whose add-account sheet is open.
    @State private var addingAccountProvider: AccountProvider?

    @State private var supabaseToken = ""
    @State private var tokenStored = false
    @State private var supabaseMessage: String?
    @State private var supabaseConfig = SupabaseConfiguration()
    @State private var supabaseProjectsDraft = ""
    @State private var savingSupabaseProjects = false
    @State private var supabaseProjectsEditable = true

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
    @State private var githubAvailable: [String] = []
    @State private var githubWatching: [String] = []
    @State private var githubDevRoot = "~/Dev"
    @State private var savingGitHubWatch = false
    /// False when the host predates /github/watch, so the fields don't sit
    /// there taking edits that can never be saved.
    @State private var githubWatchEditable = true

    /// Git and Vercel had no UI at all before Integrations became the one
    /// place connections live — both were edit-`~/.headroom/config.json`-and-
    /// restart. Drafts are held as typed and only parsed on save, same as the
    /// GitHub owner fields above.
    @State private var gitConfig = GitConfiguration()
    @State private var gitDevRootDraft = ""
    @State private var gitAuthorsDraft = ""
    @State private var gitMessage: String?
    @State private var savingGit = false
    /// False when the host predates /config/git, so the fields do not take
    /// edits that can never be saved.
    @State private var gitEditable = true

    @State private var vercelConfig = VercelConfiguration()
    @State private var vercelTeamsDraft = ""
    @State private var vercelMessage: String?
    @State private var savingVercel = false
    @State private var vercelEditable = true

    @State private var hostToken = ""
    @State private var hostTokenStored = false
    @State private var mobileTokenMessage: String?
    @State private var mobilePermissions = MobilePermissions.allEnabled
    @State private var changingMobilePermission: MobilePermission?
    @State private var agentGatewayEnabled = false
    @State private var codexBinary = "codex"
    @State private var agentProviderStatus: AgentProviderStatus?
    @State private var agentGatewayMessage: String?
    @State private var agentTaskSurface: AgentTaskSurface?
    @State private var pickedTaskFolder: String?
    @State private var changingAgentGateway = false
    @State private var claudeHooks: ClaudeHookConfiguration?
    @State private var claudeHooksMessage: String?
    @State private var changingClaudeHooks = false
    @State private var claudeQuestionMode = "notify"
    @State private var multiMac = MultiMacConfiguration.unknown
    @State private var multiMacMessage: String?
    @State private var changingMultiMac = false
    @State private var openAtLogin = LaunchAtLogin.isRequested
    @State private var openAtLoginNeedsApproval = LaunchAtLogin.needsApproval
    @State private var openAtLoginMessage: String?
    @State private var selection: SettingsDestination? = .general
    /// Bound so Back pops reliably; the unbound stack lost its path whenever
    /// the sidebar root re-rendered underneath a pushed leaf.
    @State private var path = NavigationPath()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @ObservedObject private var updates = UpdateChecker.shared
    @AppStorage(UpdateChecker.automaticKey) private var automaticUpdateChecks = true
    @State private var updateInstallMessage: String?

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
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                Section {
                    ForEach(SettingsDestination.macRoots, id: \.self) { dest in
                        Label(dest.title, systemImage: dest.symbol)
                            .tag(dest)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(HeadroomCopy.settings)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
        } detail: {
            NavigationStack(path: $path) {
                let dest = selection ?? .general
                pane(for: dest)
                    .navigationTitle(dest.title)
                    .navigationDestination(for: SettingsDestination.self) { sub in
                        pane(for: sub)
                            .navigationTitle(sub.title)
                    }
            }
        }
        .frame(width: 820, height: 600)
        .formStyle(.grouped)
        .background(SettingsWindowConfigurator())
        .onChange(of: selection) { _, _ in
            // Sidebar swapped the root; drop any pushed leaf so Back isn't
            // left pointing at a pane that is no longer under it.
            path = NavigationPath()
        }
        .task {
            tokenStored = TokenStore.supabase.exists()
            plausibleTokenStored = TokenStore.plausible.exists()
            githubTokenStored = TokenStore.github.exists()
            hostTokenStored = TokenStore.host.exists()
            refreshOpenAtLogin()
            await reloadSources()
            await reloadMobilePermissions()
            await reloadAgentGateway()
            agentTaskSurface = try? await client.fetchAgentTaskSurface()
            await reloadClaudeHooks()
            await reloadMultiMac()
            await reloadGitHubWatch()
            await reloadGitConfiguration()
            await reloadVercelConfiguration()
            await reloadSupabaseConfiguration()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // Login Items approval happens in System Settings; re-read on return.
            refreshOpenAtLogin()
        }
    }

    @ViewBuilder
    private func pane(for dest: SettingsDestination) -> some View {
        switch dest {
        case .general:
            generalPane
        case .otherMacs:
            otherMacsPane
        case .sources:
            sourcesPane
        case .codingAgents:
            codingAgentsPane
        case .iPhone:
            iPhonePane
        case .integrations:
            integrationsHub
        case .integration(let kind):
            integrationPane(kind)
        case .about:
            aboutPane
        case .connection, .permissions:
            // iOS-only destinations — Mac never selects them.
            EmptyView()
        }
    }

    private var generalPane: some View {
        Form {
            hostSection

            Section {
                Toggle(HeadroomCopy.openAtLogin, isOn: Binding(
                    get: { openAtLogin },
                    set: { setOpenAtLogin($0) }
                ))
                if openAtLoginNeedsApproval {
                    Button(HeadroomCopy.openLoginItemsSettings) {
                        LaunchAtLogin.openLoginItemsSettings()
                    }
                }
            } footer: {
                if let openAtLoginMessage {
                    Text(openAtLoginMessage)
                } else if openAtLoginNeedsApproval {
                    Text("macOS is waiting for you to allow Headroom in Login Items.")
                } else {
                    Text("Start the menu bar when you log in. The background host is separate and keeps its own LaunchAgent.")
                }
            }
            .onAppear(perform: refreshOpenAtLogin)

            Section {
                Toggle(
                    HeadroomCopy.notifyOnQuotaReset,
                    isOn: $notifyOnQuotaReset
                )
                .onChange(of: notifyOnQuotaReset) { _, enabled in
                    if enabled {
                        Task { await ResetNotifications.requestAuthorization() }
                    }
                }
            } footer: {
                Text("Codex hands a window back when you spend a reset credit. Turning this on is what asks macOS for permission.")
            }

            Section {
                NavigationLink(value: SettingsDestination.otherMacs) {
                    LabeledContent {
                        Text(multiMac.enabled ? HeadroomCopy.on : HeadroomCopy.off)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(
                            HeadroomCopy.otherMacs,
                            systemImage: SettingsDestination.otherMacs.symbol
                        )
                    }
                }
            } footer: {
                Text("Share sources and settings between Macs through iCloud Drive.")
            }

            // Activity and Local servers are Mac-wide; Supabase / Plausible
            // density lives on each integration's own page.
            Section {
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
                Toggle("Confirm before stopping servers", isOn: $confirmServerStops)
            } header: {
                Text(HeadroomCopy.settingsDashboard)
            }

            updatesSection

            Section {
                Button(HeadroomCopy.showWelcome) {
                    NotificationCenter.default.post(
                        name: .headroomShowWelcome, object: nil)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var updatesSection: some View {
        Section {
            LabeledContent(HeadroomCopy.appUpdates) {
                Text(updateStatus)
                    .foregroundStyle(.secondary)
            }
            Toggle(HeadroomCopy.automaticUpdateChecks, isOn: $automaticUpdateChecks)
            Button(
                updates.isChecking
                    ? HeadroomCopy.checkingForUpdates
                    : HeadroomCopy.checkForUpdates
            ) {
                Task { await updates.check() }
            }
            .disabled(updates.isChecking)

            if let found = updates.available, UpdateCheck.canSelfUpdate {
                Button(HeadroomCopy.installUpdate) {
                    do {
                        try UpdateInstaller.install(found)
                    } catch {
                        updateInstallMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        } footer: {
            // A manual check still runs from a copy that cannot install what
            // it finds, so say why the result will not turn into a button
            // rather than leaving a dead end.
            if let updateInstallMessage {
                Text(updateInstallMessage)
            } else if !UpdateCheck.canSelfUpdate {
                Text(HeadroomCopy.updatesNotFromHere)
            } else if updates.lastError != nil {
                Text(HeadroomCopy.updateCheckFailed)
            } else {
                Text("Headroom looks weekly for a newer notarized build, and asks before installing one.")
            }
        }
    }

    private var updateStatus: String {
        if let found = updates.available { return "\(found.version) available" }
        if updates.lastChecked != nil { return HeadroomCopy.upToDate }
        return UpdateCheck.installedVersion
    }

    private var hostSection: some View {
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
                Text(HeadroomCopy.settingsRefresh)
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
                    Text(hostTokenStored
                         ? HeadroomCopy.inKeychain
                         : "Not set")
                        .font(.caption)
                        .foregroundStyle(
                            hostTokenStored
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(HeadroomPalette.amber))
                }
            }
        } header: {
            Text("Host")
        } footer: {
            Text(endpointIsRemote
                 ? "Remote hosts need the host token (~/.headroom/token) — not the mobile token used by iPhone."
                 : "Mac, iPhone, and ESP32 all read this host. If it’s down, tap Start host or run ./scripts/install-host.sh from a clone. Source toggles also hide ESP32 pages.")
        }
    }

    private var otherMacsPane: some View {
        Form {
            Section {
                Toggle(
                    "Share settings between my Macs",
                    isOn: Binding(
                        get: { multiMac.enabled },
                        set: { enabled in
                            multiMac.enabled = enabled
                            Task { await saveMultiMac(enabled) }
                        }
                    )
                )
                .disabled(endpointIsRemote || changingMultiMac)

                LabeledContent("This Mac") {
                    HStack(spacing: 6) {
                        Text(multiMac.machine.name)
                            .foregroundStyle(.secondary)
                        if changingMultiMac {
                            ProgressView().controlSize(.small)
                        }
                    }
                }

                if multiMac.enabled {
                    // Ordered before the peer count on purpose: when macOS is
                    // blocking the read, "no other Macs yet" is not merely
                    // unhelpful, it is wrong. Publishing still works, so every
                    // Mac reports the same reassuring nothing.
                    if multiMac.mode == "cloudkit",
                       !MachineCloudSync.isAvailable {
                        // Only this side can know: the host has no idea how the
                        // app was signed. A development build silently doing
                        // nothing here is the most confusing outcome available.
                        //
                        // Two different reasons, and they need different
                        // answers. A notarized release with no iCloud profile
                        // is not something its owner can fix by downloading
                        // another copy of what they already have, which is
                        // exactly what the old wording sent them off to do.
                        Label(
                            MachineCloudSync.isDeveloperIDSigned
                            ? "This release was built without the iCloud "
                                + "profile, so multi-Mac sync is off."
                            : "Local builds cannot use iCloud. A notarized "
                                + "release carries the profile that turns "
                                + "multi-Mac sync on.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(HeadroomPalette.amber)
                    } else if let failure = MachineCloudSync.lastFailure {
                        // Ahead of the host's trouble_detail because that field
                        // only ever describes the folder transport. A CloudKit
                        // round that threw used to fall all the way through to
                        // "No other Macs yet", which reads as a working sync
                        // that nobody else has joined.
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(HeadroomPalette.amber)
                    } else if let detail = multiMac.troubleDetail {
                        Label(detail, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(HeadroomPalette.amber)
                    } else if multiMac.peers.isEmpty {
                        Text("No other Macs yet. Turn this on over there too.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(multiMac.peers) { peer in
                            LabeledContent(peer.title) {
                                Text(peer.lastSeenLabel)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    // Only in folder mode is there a path worth showing.
                    // CloudKit has nowhere for anyone to look.
                    if !multiMac.directory.isEmpty {
                        Text(multiMac.directory)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let multiMacMessage {
                    Text(multiMacMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(endpointIsRemote
                     ? "Multi-Mac settings must be changed on the Mac running the Headroom host."
                     : "Enabled sources, provider order, and accent colours follow you between Macs over iCloud. Credentials, file paths, and this Mac's local servers and commits are never shared. Quota percentages already match everywhere, because your provider counts the account rather than the machine.")
            }
        }
        .formStyle(.grouped)
    }

    private var codingAgentsPane: some View {
        Form {
            if let surface = agentTaskSurface, !surface.startable.isEmpty {
                Section {
                    StartAgentTaskView(
                        surface: withPickedFolder(surface),
                        tint: { HeadroomPalette.providerTint(id: $0) },
                        addFolder: chooseTaskFolder,
                        start: startAgentTask
                    )
                } header: {
                    Text(HeadroomCopy.startTask)
                } footer: {
                    Text("Claude runs headless and reports through its hooks. Codex needs a thread of Headroom's own — a session you start in a terminal talks to its own App Server and cannot reach this one.")
                }
            } else {
                Section {
                    Text("No agent is connected yet, so there is nothing to start.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text(HeadroomCopy.startTask)
                }
            }

            Section {
                ForEach(
                    SettingsIntegration.members(of: .agents), id: \.self
                ) { kind in
                    integrationRow(kind)
                }
            } footer: {
                Text("Connecting an agent is set up under \(HeadroomCopy.settingsIntegrations), with everything else Headroom talks to.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var claudeCodeSections: some View {
        Group {
            Section {
                LabeledContent(HeadroomCopy.claudeCodeHooks) {
                    if changingClaudeHooks {
                        ProgressView().controlSize(.small)
                    } else {
                        SettingsConnectionStatus
                            .claudeHooks(state: claudeHooks?.state)
                            .label(showSymbol: true)
                    }
                }
                HStack {
                    Button(claudeHooks?.installed == true
                           ? HeadroomCopy.reinstallHooks
                           : HeadroomCopy.installHooks) {
                        Task { await changeClaudeHooks("install") }
                    }
                    .disabled(endpointIsRemote || changingClaudeHooks)
                    if claudeHooks?.installed == true {
                        Button(HeadroomCopy.removeHooks) {
                            Task { await changeClaudeHooks("uninstall") }
                        }
                        .disabled(endpointIsRemote || changingClaudeHooks)
                    }
                    Button(HeadroomCopy.sendTestAttention) {
                        Task { await changeClaudeHooks("test") }
                    }
                    .disabled(endpointIsRemote || changingClaudeHooks)
                    Spacer()
                }
                Picker(
                    HeadroomCopy.agentQuestionMode,
                    selection: Binding(
                        get: { claudeQuestionMode },
                        set: { mode in
                            claudeQuestionMode = mode
                            Task { await changeClaudeQuestionMode(mode) }
                        }
                    )
                ) {
                    Text(HeadroomCopy.agentQuestionNotify).tag("notify")
                    Text(HeadroomCopy.agentQuestionAnswer).tag("answer")
                    Text(HeadroomCopy.agentQuestionOff).tag("off")
                }
                .disabled(endpointIsRemote || changingClaudeHooks)
                Text(HeadroomCopy.agentQuestionModeHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let path = claudeHooks?.settingsPath {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let claudeHooksMessage {
                    Text(claudeHooksMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(endpointIsRemote
                     ? "Claude Code settings must be changed on the Mac running the Headroom host."
                     : "Hooks observe the Claude Code sessions already running on this Mac and can return permission answers. The iPhone permission separately controls whether answers may come from the phone.")
            }
        }
    }

    @ViewBuilder
    private var codexSections: some View {
        Group {
            Section {
                Toggle(
                    "Enable Codex attention gateway",
                    isOn: Binding(
                        get: { agentGatewayEnabled },
                        set: { enabled in
                            agentGatewayEnabled = enabled
                            Task { await saveAgentGateway() }
                        }
                    )
                )
                .disabled(endpointIsRemote || changingAgentGateway)

                TextField("Codex executable", text: $codexBinary)
                    .textFieldStyle(.roundedBorder)
                    .disabled(endpointIsRemote || changingAgentGateway)
                if let path = agentProviderStatus?.resolvedBinary {
                    Text(HeadroomCopy.usingCodex(at: path))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Choose…") {
                        chooseCodexBinary()
                    }
                    .disabled(endpointIsRemote || changingAgentGateway)
                    Button("Apply & test") {
                        Task { await saveAgentGateway() }
                    }
                    .disabled(
                        endpointIsRemote
                        || changingAgentGateway
                        || codexBinary.trimmingCharacters(
                            in: .whitespacesAndNewlines).isEmpty
                    )
                    Spacer()
                    if changingAgentGateway {
                        ProgressView().controlSize(.small)
                    } else if let status = agentProviderStatus {
                        Label(
                            agentStatusLabel(status),
                            systemImage: agentStatusSymbol(status)
                        )
                        .font(.caption)
                        .foregroundStyle(agentStatusColor(status))
                    }
                }
                if let agentGatewayMessage {
                    Text(agentGatewayMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(endpointIsRemote
                     ? "Codex settings must be changed on the Mac running the Headroom host."
                     : "Codex runs as a Headroom-owned App Server, so a session you start in a terminal talks to its own and cannot reach this one. The iPhone permission separately controls whether answers may come from the phone.")
            }
        }
    }

    private var iPhonePane: some View {
        Form {
            Section {
                Link(
                    HeadroomCopy.openTestFlightInvite,
                    destination: HeadroomCopy.testFlightInvite
                )
            } footer: {
                Text("Install the iPhone app from TestFlight. The Apple Watch app installs with it.")
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
            } footer: {
                Text("Copy mobile token (~/.headroom/mobile-token), open Headroom on iPhone, tap this Mac, paste once. Do not use the host token (that’s for the ESP32). Tailscale names remain available as a fallback.")
            }
        }
        .formStyle(.grouped)
    }

    private var sourcesPane: some View {
        SettingsSourcesPane(
            sources: sources,
            usage: usageProviders,
            accountProviders: accountProviders,
            detected: detectedSources,
            busyID: togglingSourceID,
            isSyncing: isSyncing,
            message: sourcesMessage,
            dropTargetID: dropTargetID,
            onToggleRows: { ids, enabled in
                Task { await setSourceRows(ids, enabled: enabled) }
            },
            onDismissRows: { ids in
                Task { await dismissSourceRows(ids) }
            },
            onRemoveAccount: { id in
                Task { await removeAccount(id) }
            },
            onAddAccount: { provider in
                addingAccountProvider = provider
            },
            onRefresh: { ids in
                Task { await refreshSources(ids) }
            },
            onMoveService: { dragged, target in
                dropTargetID = nil
                Task { await moveService(dragged, before: target) }
            },
            onNudgeService: { id, offset in
                Task { await nudgeService(id, by: offset) }
            },
            onDropTarget: { id, targeted in
                dropTargetID = targeted ? id : nil
            },
            onAccent: { ids, hex in
                Task { await setAccents(ids, hex: hex) }
            }
        )
        .sheet(item: $addingAccountProvider) { provider in
            AddAccountSheet(provider: provider, endpoint: endpoint) {
                await reloadSources()
            }
        }
    }

    /// Everything Headroom connects to, in one list.
    ///
    /// Grouped rather than flat because the agents can run code on this Mac
    /// and the rest only read — a distinction worth seeing without opening
    /// each leaf.
    private var integrationsHub: some View {
        Form {
            ForEach(SettingsIntegration.Group.allCases, id: \.self) { group in
                Section {
                    ForEach(
                        SettingsIntegration.members(of: group), id: \.self
                    ) { kind in
                        integrationRow(kind)
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    switch group {
                    case .agents:
                        Text("These two can start work on this Mac. Everything else here only reads.")
                    case .code:
                        Text("Commits, Actions failures, and deploys feed \(HeadroomCopy.activity).")
                    case .services:
                        Text("Keys stay in the Keychain on this Mac. The iPhone never sees them.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// One hub row. Shared with the Coding agents pane, which links to the two
    /// agent leaves rather than keeping a second copy of their settings.
    ///
    /// `LabeledContent` + `Label` keeps Form's icon column aligned across
    /// symbols of different widths — a bare `Label`/`Spacer`/`Text` stack
    /// opts that out and leaves titles drifting row to row.
    private func integrationRow(_ kind: SettingsIntegration) -> some View {
        NavigationLink(value: SettingsDestination.integration(kind)) {
            LabeledContent {
                integrationStatus(kind).label()
            } label: {
                Label(kind.title, systemImage: kind.symbol)
            }
        }
    }

    /// "Connected" is the wrong word for the two that need no credential, so
    /// they say what is actually true of them instead.
    private func integrationStatus(_ kind: SettingsIntegration) -> SettingsConnectionStatus {
        switch kind {
        case .claudeCode:
            let ok = claudeHooks?.installed == true
            return SettingsConnectionStatus(
                ok ? HeadroomCopy.hooksInstalled : HeadroomCopy.hooksOff,
                tone: ok ? .ok : .attention
            )
        case .codex:
            return SettingsConnectionStatus(
                agentGatewayEnabled
                    ? HeadroomCopy.gatewayOn : HeadroomCopy.gatewayOff,
                tone: agentGatewayEnabled ? .ok : .attention
            )
        case .git:
            // A host predating /config/git leaves the defaults in place, and
            // "0 repos" would be an answer rather than the non-answer it is.
            guard gitEditable else { return .unknown }
            guard gitConfig.devRootExists else { return .folderMissing }
            let count = gitConfig.repos.count
            let title = count == 1 ? "1 repo" : "\(count) repos"
            return SettingsConnectionStatus(
                title,
                tone: count > 0 ? .ok : .attention
            )
        case .vercel:
            guard vercelEditable else { return .unknown }
            return .signedIn(vercelConfig.signedIn)
        case .github, .supabase, .plausible:
            return .connected(integrationConnected(kind))
        }
    }

    private func integrationConnected(_ kind: SettingsIntegration) -> Bool {
        switch kind {
        case .supabase: return tokenStored
        case .plausible: return plausibleTokenStored
        case .github: return githubTokenStored
        case .claudeCode: return claudeHooks?.installed == true
        case .codex: return agentGatewayEnabled
        // Unknown is not a warning: amber here would put a colour on an old
        // host rather than on anything the user can act about.
        case .git:
            return !gitEditable
                || (gitConfig.devRootExists && !gitConfig.repos.isEmpty)
        case .vercel: return !vercelEditable || vercelConfig.signedIn
        }
    }

    @ViewBuilder
    private func integrationPane(_ kind: SettingsIntegration) -> some View {
        Form {
            switch kind {
            case .claudeCode: claudeCodeSections
            case .codex: codexSections
            case .git: gitSections
            case .github: githubSections
            case .vercel: vercelSections
            case .supabase: supabaseSections
            case .plausible: plausibleSections
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var supabaseSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                SettingsConnectionStatus.keychain(tokenStored).label()
            }
            SecureField("sbp_… or access token", text: $supabaseToken)
                .onSubmit {
                    if !tokenDraft.isEmpty { saveSupabaseToken() }
                }
            HStack {
                if tokenDraft.isEmpty {
                    Button(HeadroomCopy.settingsRefresh) {
                        // Promote + fetch: a Keychain key with the source still
                        // in Library used to refresh into a no-op.
                        Task { await refreshSources(["supabase"]) }
                    }
                    .disabled(!tokenStored || isSyncing)
                } else {
                    Button(tokenStored
                           ? HeadroomCopy.settingsReplace
                           : HeadroomCopy.settingsConnect) {
                        saveSupabaseToken()
                    }
                    .disabled(isSyncing)
                    .keyboardShortcut(.defaultAction)
                }
                if tokenStored {
                    Button(HeadroomCopy.settingsDisconnect, role: .destructive) {
                        disconnectSupabase()
                    }
                    .disabled(isSyncing)
                }
                Spacer()
                Button(HeadroomCopy.settingsCreateToken) {
                    openURL("https://supabase.com/dashboard/account/tokens")
                }
                .buttonStyle(.link)
            }
            if let supabaseMessage {
                Text(supabaseMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("PAT stays in Keychain.")
        }

        Section {
            if !supabaseProjectsEditable {
                Text("Project settings need a running, up to date host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !supabaseConfig.available.isEmpty {
                ForEach(supabaseConfig.available) { project in
                    Toggle(isOn: Binding(
                        get: {
                            supabaseSelectedProjects.contains(project.ref)
                        },
                        set: { on in
                            Task {
                                await setSupabaseProject(
                                    project.ref, enabled: on)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                            if project.name != project.ref {
                                Text(project.ref)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .disabled(savingSupabaseProjects || !supabaseProjectsEditable)
                }
                if supabaseSelectedProjects.isEmpty {
                    Text("None selected — Headroom reads every project this token can see.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Stepper(
                "Show up to \(supabaseRowLimit)",
                value: $supabaseRowLimit,
                in: 1...20
            )
            HStack {
                if savingSupabaseProjects {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(HeadroomCopy.settingsRefresh) {
                    Task {
                        await reloadSupabaseConfiguration()
                        await refreshSources(["supabase"])
                    }
                }
                .disabled(isSyncing)
            }
        } header: {
            Text(HeadroomCopy.settingsDashboard)
        } footer: {
            Text("Tick which projects to track. The stepper only caps how many this Mac draws.")
        }
    }

    @ViewBuilder
    private var plausibleSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                SettingsConnectionStatus.keychain(plausibleTokenStored).label()
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
                    Button(HeadroomCopy.settingsRefresh) {
                        Task { await refreshSources(["plausible"]) }
                    }
                    .disabled(!plausibleTokenStored || isSyncing)
                } else {
                    Button(plausibleTokenStored
                           ? HeadroomCopy.settingsReplace
                           : HeadroomCopy.settingsConnect) {
                        savePlausibleToken()
                    }
                    .disabled(isSyncing)
                }
                if plausibleTokenStored {
                    Button(HeadroomCopy.settingsDisconnect, role: .destructive) {
                        disconnectPlausible()
                    }
                    .disabled(isSyncing)
                }
                Spacer()
                Button(HeadroomCopy.settingsCreateKey) {
                    openURL("https://plausible.io/settings/api-keys")
                }
                .buttonStyle(.link)
            }
            if let plausibleMessage {
                Text(plausibleMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("API key stays in Keychain.")
        }

        Section {
            Stepper(
                "Sites: \(plausibleRowLimit)",
                value: $plausibleRowLimit,
                in: 1...20
            )
        } header: {
            Text(HeadroomCopy.settingsDashboard)
        } footer: {
            Text("How many sites this Mac draws.")
        }
    }

    @ViewBuilder
    private var gitSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                (gitConfig.devRootExists
                    ? SettingsConnectionStatus(
                        "\(gitConfig.repos.count) repos found",
                        tone: .ok
                      )
                    : .folderMissing
                ).label()
            }
            if !gitEditable {
                Text("Git settings need a running, up to date host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField(
                "Dev root",
                text: $gitDevRootDraft,
                prompt: Text("~/Dev")
            )
            TextField(
                "Commit authors",
                text: $gitAuthorsDraft,
                prompt: Text("you@example.com, Your Name (blank counts everyone)")
            )
            HStack {
                Button("Choose…") {
                    chooseDevRoot()
                }
                .disabled(!gitEditable)
                Button(HeadroomCopy.settingsSave) {
                    Task { await saveGitConfiguration() }
                }
                .disabled(savingGit || !gitEditable || gitDevRootDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if savingGit {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            if let gitMessage {
                Text(gitMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !gitConfig.repos.isEmpty {
                LabeledContent(HeadroomCopy.settingsScanning) {
                    Text(gitConfig.repos.prefix(12).joined(separator: ", ")
                         + (gitConfig.repos.count > 12 ? "…" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } footer: {
            // dev_root is out of SHARED_CONFIG_KEYS on purpose: it describes
            // one machine's disk. Authors are the same person everywhere, so
            // they do follow. Worth saying, because the two fields sit
            // together and behave differently.
            Text("Commits under \(gitConfig.devRootPath.isEmpty ? gitConfig.devRoot : gitConfig.devRootPath) and one level below it, shown under \(HeadroomCopy.activity). The folder stays on this Mac; commit authors follow you to your other Macs.")
        }
    }

    @ViewBuilder
    private var vercelSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                (vercelConfig.signedIn
                    ? SettingsConnectionStatus(
                        "Vercel CLI",
                        tone: .ok
                      )
                    : .signedIn(false)
                ).label()
            }
            if !vercelConfig.signedIn {
                Text("Run `vercel login` in a terminal. Headroom reads the CLI's own token and never asks for one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !vercelEditable {
                Text("Team settings need a running, up to date host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !vercelConfig.available.isEmpty {
                ForEach(vercelConfig.available) { team in
                    Toggle(isOn: Binding(
                        get: {
                            vercelSelectedTeams.contains(team.slug.lowercased())
                        },
                        set: { on in
                            Task { await setVercelTeam(team.slug, enabled: on) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(team.name)
                            if team.name.lowercased() != team.slug.lowercased() {
                                Text(team.slug)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(savingVercel || !vercelEditable)
                }
                if vercelSelectedTeams.isEmpty {
                    Text("None selected — Headroom uses the CLI’s current team.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField(
                    "Teams",
                    text: $vercelTeamsDraft,
                    prompt: Text("acme, ada (blank uses the CLI current team)")
                )
                HStack {
                    Button("Save teams") {
                        Task { await saveVercelConfiguration() }
                    }
                    .disabled(savingVercel || !vercelEditable)
                    if savingVercel {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            }
            HStack {
                if savingVercel {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(HeadroomCopy.settingsRefresh) {
                    Task {
                        await reloadVercelConfiguration()
                        await refreshSources(["vercel"])
                    }
                }
                .disabled(isSyncing)
            }
            if let vercelMessage {
                Text(vercelMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Deployments show under \(HeadroomCopy.activity). Pick which teams to read — leave none selected and Headroom uses the CLI’s current team.")
        }
    }

    @ViewBuilder
    private var githubSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                SettingsConnectionStatus.keychain(githubTokenStored).label()
            }
            SecureField("ghp_… (repo)", text: $githubToken)
                .onSubmit {
                    if !githubTokenDraft.isEmpty { saveGitHubToken() }
                }
            HStack {
                if githubTokenDraft.isEmpty {
                    Button(HeadroomCopy.settingsRefresh) {
                        Task { await refreshSources(["github"]) }
                    }
                    .disabled(!githubTokenStored || isSyncing)
                } else {
                    Button(githubTokenStored
                           ? HeadroomCopy.settingsReplace
                           : HeadroomCopy.settingsConnect) {
                        saveGitHubToken()
                    }
                    .disabled(isSyncing)
                }
                if githubTokenStored {
                    Button(HeadroomCopy.settingsDisconnect, role: .destructive) {
                        disconnectGitHub()
                    }
                    .disabled(isSyncing)
                }
                Spacer()
                Button(HeadroomCopy.settingsCreateToken) {
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
            if !githubWatchEditable {
                Text("Repo settings need a running, up to date host.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !githubAvailable.isEmpty {
                ForEach(githubAvailable, id: \.self) { repo in
                    Toggle(repo, isOn: Binding(
                        get: { githubSelectedAlways.contains(repo) },
                        set: { on in
                            Task { await setGitHubAlwaysRepo(repo, enabled: on) }
                        }
                    ))
                    .disabled(savingGitHubWatch || !githubWatchEditable)
                }
            }
            DisclosureGroup("Advanced") {
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
                    .disabled(savingGitHubWatch || !githubWatchEditable)
                    if savingGitHubWatch {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            }
            if !githubWatching.isEmpty {
                LabeledContent(HeadroomCopy.settingsWatching) {
                    Text(githubWatching.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } footer: {
            Text("Tick repos under \(githubDevRoot) to always watch them. Owners and the discover cap still filter anything not ticked. Failures show under \(HeadroomCopy.activity).")
        }
    }

    private var aboutPane: some View {
        Form {
            Section {
                AboutHeadroomView()
            }
        }
        .formStyle(.grouped)
    }

    /// Mirrors `sources_config.FOCUS_LIMIT`.
    private var focusLimit: Int { 3 }

    /// AI services in pinned order, each carrying its account ids as a block.
    /// The wire order stays account-level; the pane reorders services.
    private var aiServiceBlocks: [(id: String, rowIDs: [String])] {
        SourceService.services(from: sources)
            .filter { $0.group == .ai }
            .map { ($0.id, $0.rows.map(\.id)) }
    }

    /// Drop `dragged` into `target`'s slot, moving the service's accounts as
    /// one block. The list sent is the whole AI group including disabled
    /// rows — a service you turned off keeps its place rather than sinking.
    private func moveService(_ dragged: String, before target: String) async {
        guard dragged != target else { return }
        var blocks = aiServiceBlocks
        guard let from = blocks.firstIndex(where: { $0.id == dragged }) else {
            return
        }
        let moved = blocks.remove(at: from)
        guard let to = blocks.firstIndex(where: { $0.id == target }) else {
            return
        }
        blocks.insert(moved, at: to)
        await commitOrder(blocks.flatMap(\.rowIDs), movedID: dragged)
    }

    /// Keyboard / VoiceOver path to the same reorder, so pinning isn't
    /// drag-only.
    private func nudgeService(_ id: String, by offset: Int) async {
        var blocks = aiServiceBlocks
        guard let from = blocks.firstIndex(where: { $0.id == id }) else {
            return
        }
        let to = from + offset
        guard blocks.indices.contains(to) else { return }
        blocks.swapAt(from, to)
        await commitOrder(blocks.flatMap(\.rowIDs), movedID: id)
    }

    /// Repaint a service everywhere — every account of it, one POST each,
    /// then one reload. `nil` restores the shipped color.
    private func setAccents(_ ids: [String], hex: String?) async {
        togglingSourceID = ids.first
        defer { togglingSourceID = nil }
        do {
            for id in ids {
                _ = try await client.setSourceAccent(id, hex: hex)
            }
            // Colors are presentation only — the host republished the cached
            // document, so re-reading it is the whole update.
            await reloadSources()
            sourcesMessage = hex == nil
                ? "Restored the default color."
                : "Color updated — menu bar, rings and iPhone follow."
        } catch {
            sourcesMessage = error.localizedDescription
        }
    }

    /// Remove an extra login. The host re-execs to rebuild its registry, so
    /// this waits for the restart the same way the add sheet does.
    private func removeAccount(_ id: String) async {
        togglingSourceID = id
        defer { togglingSourceID = nil }
        let before = try? await client.health().uptimeS
        do {
            _ = try await client.removeAccount(id)
            sourcesMessage = "Removed \(id). Restarting host…"
            await AddAccountSheet.waitForRestart(
                client: client, previousUptime: before)
            await reloadSources()
            sourcesMessage = "Removed \(id)."
        } catch {
            sourcesMessage = error.localizedDescription
        }
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

    private func reloadAgentGateway() async {
        do {
            let configuration = try await client.fetchAgentGatewayConfiguration()
            agentGatewayEnabled = configuration.enabled
            codexBinary = configuration.codexBinary
            agentProviderStatus = configuration.provider
        } catch {
            agentGatewayMessage = error.localizedDescription
        }
    }

    private func reloadClaudeHooks() async {
        do {
            claudeHooks = try await client.fetchClaudeHookConfiguration()
            claudeQuestionMode = claudeHooks?.questionMode ?? "notify"
        } catch {
            claudeHooksMessage = error.localizedDescription
        }
    }

    private func reloadMultiMac() async {
        do {
            multiMac = try await client.fetchMultiMacConfiguration()
        } catch {
            multiMacMessage = error.localizedDescription
        }
    }

    private func saveMultiMac(_ enabled: Bool) async {
        guard !changingMultiMac else { return }
        changingMultiMac = true
        multiMacMessage = nil
        defer { changingMultiMac = false }
        do {
            multiMac = try await client.setMultiMacConfiguration(enabled: enabled)
            if multiMac.enabled {
                multiMacMessage = multiMac.peers.isEmpty
                    ? nil
                    : "Found \(multiMac.peers.count) other Mac"
                        + (multiMac.peers.count == 1 ? "." : "s.")
            } else {
                // The folder is left where it is. Turning sync off should stop
                // this Mac publishing, not reach into iCloud and delete a
                // record the other Macs are still reading.
                multiMacMessage = "This Mac has stopped sharing."
            }
        } catch {
            multiMacMessage = error.localizedDescription
            await reloadMultiMac()
        }
    }

    private func changeClaudeQuestionMode(_ mode: String) async {
        await changeClaudeHooks("install", questionMode: mode)
    }

    private func changeClaudeHooks(
        _ action: String,
        questionMode: String? = nil
    ) async {
        guard !changingClaudeHooks else { return }
        changingClaudeHooks = true
        claudeHooksMessage = nil
        defer { changingClaudeHooks = false }
        do {
            claudeHooks = try await client.changeClaudeHooks(
                action,
                questionMode: questionMode ?? (action == "install"
                                               ? claudeQuestionMode
                                               : nil)
            )
            if let mode = claudeHooks?.questionMode {
                claudeQuestionMode = mode
            }
            switch action {
            case "install":
                claudeHooksMessage =
                    "Claude Code will now send attention events to Headroom."
            case "uninstall":
                claudeHooksMessage =
                    "Headroom-owned hooks were removed. Other Claude hooks were preserved."
            case "test":
                claudeHooksMessage =
                    "Test attention added. Check Attention on this Mac or iPhone."
            default:
                break
            }
        } catch {
            claudeHooksMessage = error.localizedDescription
            await reloadClaudeHooks()
        }
    }

    private func saveAgentGateway() async {
        guard !changingAgentGateway else { return }
        let binary = codexBinary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !binary.isEmpty else { return }
        changingAgentGateway = true
        agentGatewayMessage = nil
        defer { changingAgentGateway = false }
        do {
            var configuration = try await client.setAgentGatewayConfiguration(
                enabled: agentGatewayEnabled,
                codexBinary: binary
            )
            for _ in 0..<5 {
                guard configuration.enabled,
                      configuration.provider.connection == "starting"
                else { break }
                try? await Task.sleep(for: .milliseconds(400))
                configuration = try await client.fetchAgentGatewayConfiguration()
            }
            agentGatewayEnabled = configuration.enabled
            codexBinary = configuration.codexBinary
            agentProviderStatus = configuration.provider
            agentGatewayMessage = configuration.enabled
                ? (configuration.provider.connection == "ready"
                    ? "Codex App Server is ready."
                    : configuration.provider.error)
                : "Gateway is off."
        } catch {
            agentGatewayMessage = error.localizedDescription
            await reloadAgentGateway()
        }
    }

    /// A folder the Mac just picked is offered immediately, before the host
    /// has been asked to start anything in it.
    private func withPickedFolder(_ surface: AgentTaskSurface) -> AgentTaskSurface {
        guard let pickedTaskFolder,
              !surface.folders.contains(pickedTaskFolder) else { return surface }
        var copy = surface
        copy.folders = [pickedTaskFolder] + surface.folders
        return copy
    }

    private func chooseTaskFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder for the agent to work in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedTaskFolder = url.path
    }

    private func startAgentTask(
        provider: String, cwd: String, prompt: String
    ) async -> AgentTaskOutcome {
        do {
            let started = try await client.startAgentTask(
                provider: provider, cwd: cwd, prompt: prompt)
            agentTaskSurface = try? await client.fetchAgentTaskSurface()
            let agent = agentTaskSurface?.providers.first {
                $0.provider == started.provider
            }?.title ?? started.provider
            let folder = (started.task.cwd ?? cwd)
                .split(separator: "/").last.map(String.init) ?? cwd
            // The Mac has no feed of its own, so the confirmation also says
            // where the requests will turn up.
            return AgentTaskOutcome(
                ok: true,
                message: HeadroomCopy.agentIsWorking(agent, in: folder)
                    + " · " + HeadroomCopy.watchOnPhone
            )
        } catch {
            return AgentTaskOutcome(
                ok: false, message: error.localizedDescription)
        }
    }

    private func chooseCodexBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Codex CLI executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        codexBinary = url.path
    }

    private func agentStatusLabel(_ status: AgentProviderStatus) -> String {
        if !status.available { return "Executable not found" }
        switch status.connection {
        case "ready": return "Ready"
        case "starting": return "Starting…"
        case "disconnected": return "Disconnected"
        case "stopped", "disabled": return "Off"
        default: return status.connection.capitalized
        }
    }

    private func agentStatusSymbol(_ status: AgentProviderStatus) -> String {
        if !status.available || status.connection == "disconnected" {
            return "exclamationmark.triangle.fill"
        }
        return status.connection == "ready"
            ? "checkmark.circle.fill"
            : "circle.dotted"
    }

    private func agentStatusColor(
        _ status: AgentProviderStatus
    ) -> AnyShapeStyle {
        if !status.available || status.connection == "disconnected" {
            return AnyShapeStyle(HeadroomPalette.amber)
        }
        if status.connection == "ready" {
            return AnyShapeStyle(HeadroomPalette.green)
        }
        return AnyShapeStyle(.secondary)
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
        do {
            applyGitHubWatch(try await client.fetchGitHubWatch())
            githubWatchEditable = true
        } catch {
            githubWatchEditable = false
        }
    }

    private func applyGitHubWatch(_ watch: GitHubWatch) {
        githubOwners = watch.owners.joined(separator: ", ")
        githubAlwaysRepos = watch.alwaysRepos.joined(separator: ", ")
        githubMaxDiscovered = watch.maxDiscovered
        githubAvailable = watch.available
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

    private var githubSelectedAlways: Set<String> {
        Set(splitList(githubAlwaysRepos))
    }

    private var vercelSelectedTeams: Set<String> {
        Set(splitList(vercelTeamsDraft).map { $0.lowercased() })
    }

    private var supabaseSelectedProjects: Set<String> {
        Set(splitList(supabaseProjectsDraft))
    }

    /// Checklist path: flip one always-watch repo and persist immediately so
    /// Settings does not need a separate Save for the common case.
    private func setGitHubAlwaysRepo(_ repo: String, enabled: Bool) async {
        var repos = splitList(githubAlwaysRepos)
        if enabled {
            if !repos.contains(repo) { repos.append(repo) }
        } else {
            repos.removeAll { $0 == repo }
        }
        githubAlwaysRepos = repos.joined(separator: ", ")
        await saveGitHubWatch()
    }

    private func setVercelTeam(_ slug: String, enabled: Bool) async {
        let key = slug.lowercased()
        var teams = splitList(vercelTeamsDraft)
        if enabled {
            if !teams.map({ $0.lowercased() }).contains(key) {
                teams.append(slug)
            }
        } else {
            teams.removeAll { $0.lowercased() == key }
        }
        vercelTeamsDraft = teams.joined(separator: ", ")
        await saveVercelConfiguration()
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

    private func reloadGitConfiguration() async {
        do {
            applyGitConfiguration(try await client.fetchGitConfiguration())
            gitEditable = true
        } catch {
            gitEditable = false
        }
    }

    private func applyGitConfiguration(_ config: GitConfiguration) {
        gitConfig = config
        gitDevRootDraft = config.devRoot
        gitAuthorsDraft = config.authors.joined(separator: ", ")
    }

    private func saveGitConfiguration() async {
        savingGit = true
        defer { savingGit = false }
        do {
            let config = try await client.setGitConfiguration(
                devRoot: gitDevRootDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines),
                authors: splitList(gitAuthorsDraft)
            )
            applyGitConfiguration(config)
            gitMessage = config.repos.isEmpty
                ? "Saved. No repos under \(config.devRootPath) yet."
                : "Scanning \(config.repos.count) "
                    + (config.repos.count == 1 ? "repo." : "repos.")
            // GitHub discovers its repos under the same root, so a move that
            // only refreshed git would leave Actions watching the old one.
            await refreshSources(["git", "github"])
            await reloadGitHubWatch()
        } catch {
            gitMessage = error.localizedDescription
        }
    }

    /// A folder picker beside the field, because the most likely edit is
    /// "somewhere else on this disk" and typing a path is the worst way to say
    /// that. Mirrors `chooseCodexBinary()`.
    private func chooseDevRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            gitDevRootDraft = url.path
            Task { await saveGitConfiguration() }
        }
    }

    private func reloadVercelConfiguration() async {
        do {
            applyVercelConfiguration(
                try await client.fetchVercelConfiguration())
            vercelEditable = true
        } catch {
            vercelEditable = false
        }
    }

    private func applyVercelConfiguration(_ config: VercelConfiguration) {
        vercelConfig = config
        vercelTeamsDraft = config.teams.joined(separator: ", ")
    }

    private func saveVercelConfiguration() async {
        savingVercel = true
        defer { savingVercel = false }
        do {
            let config = try await client.setVercelConfiguration(
                teams: splitList(vercelTeamsDraft))
            applyVercelConfiguration(config)
            vercelMessage = config.teams.isEmpty
                ? "Saved. Using the CLI’s current team."
                : "Saved."
            await refreshSources(["vercel"])
        } catch {
            vercelMessage = error.localizedDescription
        }
    }

    private func reloadSupabaseConfiguration() async {
        do {
            applySupabaseConfiguration(
                try await client.fetchSupabaseConfiguration())
            supabaseProjectsEditable = true
        } catch {
            supabaseProjectsEditable = false
        }
    }

    private func applySupabaseConfiguration(_ config: SupabaseConfiguration) {
        supabaseConfig = config
        supabaseProjectsDraft = config.projects.joined(separator: ", ")
    }

    private func setSupabaseProject(_ ref: String, enabled: Bool) async {
        var projects = splitList(supabaseProjectsDraft)
        if enabled {
            if !projects.contains(ref) { projects.append(ref) }
        } else {
            projects.removeAll { $0 == ref }
        }
        supabaseProjectsDraft = projects.joined(separator: ", ")
        await saveSupabaseConfiguration()
    }

    private func saveSupabaseConfiguration() async {
        savingSupabaseProjects = true
        defer { savingSupabaseProjects = false }
        do {
            let config = try await client.setSupabaseConfiguration(
                projects: splitList(supabaseProjectsDraft))
            applySupabaseConfiguration(config)
            supabaseMessage = config.projects.isEmpty
                ? "Saved. Reading every project this token can see."
                : "Saved."
            await refreshSources(["supabase"])
        } catch {
            supabaseMessage = error.localizedDescription
        }
    }

    private func disconnectGitHub() {
        TokenStore.github.delete()
        githubTokenStored = false
        githubToken = ""
        githubMessage = "Disconnected"
        Task { await refreshSources(["github"]) }
    }

    /// Toggle a whole service or a single account — same path, different id
    /// lists. One POST either way, so three Claude accounts flip together
    /// instead of racing three writes.
    private func setSourceRows(_ ids: [String], enabled: Bool) async {
        guard let first = ids.first else { return }
        togglingSourceID = first
        defer { togglingSourceID = nil }
        do {
            var map = Dictionary(
                uniqueKeysWithValues: sources.map { ($0.id, $0.enabled ?? true) })
            for id in ids { map[id] = enabled }
            // Turning on also un-dismisses: a Library chip tap and an Active
            // toggle are the same write, and both must land the row in
            // Active. Turning off sends no dismissed key — that's a pause,
            // and the row stays put.
            _ = try await client.setSources(
                map,
                dismissed: enabled
                    ? Dictionary(uniqueKeysWithValues: ids.map { ($0, false) })
                    : nil)
            // Toggling on kicks a refresh host-side; wait for it to land rather
            // than guessing how long it takes.
            if enabled {
                await client.waitForRefresh(sources: ids)
            }
            await reloadSources()
            let names = ids.joined(separator: ", ")
            sourcesMessage = enabled
                ? "Enabled \(names) — ESP32 will show it on next poll."
                : "Paused \(names) — stays listed, stops fetching; ESP32 will hide that page."
        } catch {
            sourcesMessage = error.localizedDescription
        }
    }

    /// The row's ✕: back to the Library. The host flips `dismissed` and
    /// disables the rows in the same write.
    private func dismissSourceRows(_ ids: [String]) async {
        guard let first = ids.first else { return }
        togglingSourceID = first
        defer { togglingSourceID = nil }
        do {
            _ = try await client.setSources(
                [:],
                dismissed: Dictionary(
                    uniqueKeysWithValues: ids.map { ($0, true) }))
            await reloadSources()
            sourcesMessage =
                "Moved \(ids.joined(separator: ", ")) to the Library."
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
            usageProviders = Dictionary(
                (snapshot.providers ?? []).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            if let range = snapshot.plausible?.range {
                plausibleRange = range
            }
            if sources.isEmpty {
                sourcesMessage = "Host has no sources payload — restart com.centaur-labs.headroom."
            }
        } catch {
            sourcesMessage = error.localizedDescription
        }
        // Capability and detection are additive context: a host predating
        // either endpoint just means no "Add account…" links and no dimmed
        // chips, never an error in the pane.
        if let accounts = try? await client.fetchAccounts() {
            accountProviders = accounts.providers
        }
        if let setup = try? await client.fetchSetup() {
            detectedSources = Dictionary(
                setup.sources.map { ($0.id, $0.detected) },
                uniquingKeysWith: { first, _ in first })
        }
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyMobileToken() {
        guard let value = HostController.mobileToken else {
            mobileTokenMessage = "Start the host first"
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        mobileTokenMessage = "Copied"
    }

    private func refreshOpenAtLogin() {
        openAtLogin = LaunchAtLogin.isRequested
        openAtLoginNeedsApproval = LaunchAtLogin.needsApproval
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        openAtLoginMessage = nil
        do {
            try LaunchAtLogin.setEnabled(enabled)
            refreshOpenAtLogin()
        } catch {
            refreshOpenAtLogin()
            openAtLoginMessage = error.localizedDescription
        }
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
        window.styleMask.insert([.titled, .closable, .miniaturizable])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
