import AppKit
import SwiftUI

extension SettingsView {
    var codingAgentsPane: some View {
        Form {
            Section {
                Toggle(
                    HeadroomCopy.agentAlerts,
                    isOn: Binding(
                        get: { agentAlerts },
                        set: { enabled in
                            agentAlerts = enabled
                            Task { await saveAgentAlerts() }
                        }
                    )
                )
                .disabled(endpointIsRemote || changingAgentAlerts)
            } footer: {
                Text(HeadroomCopy.agentAlertsHelp)
            }

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
    var claudeCodeSections: some View {
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
    var codexSections: some View {
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

    func reloadAgentGateway() async {
        do {
            let configuration = try await client.fetchAgentGatewayConfiguration()
            agentGatewayEnabled = configuration.enabled
            agentAlerts = configuration.alerts ?? true
            codexBinary = configuration.codexBinary
            agentProviderStatus = configuration.provider
        } catch {
            agentGatewayMessage = error.localizedDescription
        }
    }

    func reloadClaudeHooks() async {
        do {
            claudeHooks = try await client.fetchClaudeHookConfiguration()
            claudeQuestionMode = claudeHooks?.questionMode ?? "notify"
        } catch {
            claudeHooksMessage = error.localizedDescription
        }
    }

    func changeClaudeQuestionMode(_ mode: String) async {
        await changeClaudeHooks("install", questionMode: mode)
    }

    func changeClaudeHooks(
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

    func saveAgentGateway() async {
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
            agentAlerts = configuration.alerts ?? agentAlerts
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

    func saveAgentAlerts() async {
        guard !changingAgentAlerts else { return }
        changingAgentAlerts = true
        defer { changingAgentAlerts = false }
        do {
            let configuration = try await client.setAgentAlerts(agentAlerts)
            agentAlerts = configuration.alerts ?? agentAlerts
        } catch {
            agentGatewayMessage = error.localizedDescription
            await reloadAgentGateway()
        }
    }

    /// A folder the Mac just picked is offered immediately, before the host
    /// has been asked to start anything in it.
    func withPickedFolder(_ surface: AgentTaskSurface) -> AgentTaskSurface {
        guard let pickedTaskFolder,
              !surface.folders.contains(pickedTaskFolder) else { return surface }
        var copy = surface
        copy.folders = [pickedTaskFolder] + surface.folders
        return copy
    }

    func chooseTaskFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder for the agent to work in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedTaskFolder = url.path
    }

    func startAgentTask(
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

    func chooseCodexBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Codex CLI executable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        codexBinary = url.path
    }

    func agentStatusLabel(_ status: AgentProviderStatus) -> String {
        if !status.available { return "Executable not found" }
        switch status.connection {
        case "ready": return "Ready"
        case "starting": return "Starting…"
        case "disconnected": return "Disconnected"
        case "stopped", "disabled": return "Off"
        default: return status.connection.capitalized
        }
    }

    func agentStatusSymbol(_ status: AgentProviderStatus) -> String {
        if !status.available || status.connection == "disconnected" {
            return "exclamationmark.triangle.fill"
        }
        return status.connection == "ready"
            ? "checkmark.circle.fill"
            : "circle.dotted"
    }

    func agentStatusColor(
        _ status: AgentProviderStatus
    ) -> AnyShapeStyle {
        if !status.available || status.connection == "disconnected" {
            return AnyShapeStyle(HeadroomPalette.orange)
        }
        if status.connection == "ready" {
            return AnyShapeStyle(HeadroomPalette.green)
        }
        return AnyShapeStyle(.secondary)
    }
}
