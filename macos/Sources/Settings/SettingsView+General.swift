import SwiftUI

extension SettingsView {
    var generalPane: some View {
        Form {
            hostSection

            timezoneSection

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

    /// Drop an Integrations catalog row into another's slot.
    func moveServicePanel(_ dragged: String, before target: String) async {
        guard dragged != target else { return }
        var order = integrationsOrder
        guard let from = order.firstIndex(of: dragged) else { return }
        order.remove(at: from)
        guard let to = order.firstIndex(of: target) else { return }
        order.insert(dragged, at: to)
        await commitServicesOrder(order)
    }

    func nudgeServicePanel(_ id: String, by offset: Int) async {
        var order = integrationsOrder
        guard let from = order.firstIndex(of: id) else { return }
        let to = from + offset
        guard order.indices.contains(to) else { return }
        order.swapAt(from, to)
        await commitServicesOrder(order)
    }

    func commitServicesOrder(_ order: [String]) async {
        do {
            let stored = try await client.setIntegrationsOrder(order)
            integrationsOrder = IntegrationWatch.ordered(from: stored).map(\.rawValue)
            servicesOrder = IntegrationWatch.activityBlocks(from: stored).map(\.rawValue)
            await reloadSources()
        } catch {
            sourcesMessage = error.localizedDescription
        }
    }

    /// The zone every day boundary is drawn in.
    ///
    /// Loaded here rather than in the window's `.task` so opening Settings
    /// to flip one switch does not also pay for a pane nobody looked at.
    var timezoneSection: some View {
        Section {
            TextField(
                "Time zone",
                text: $timezoneDraft,
                prompt: Text(TimeZone.current.identifier)
            )
            .onSubmit { Task { await saveTimezone() } }
            HStack {
                Button(HeadroomCopy.settingsSave) {
                    Task { await saveTimezone() }
                }
                .disabled(timezoneDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Use this Mac’s") {
                    timezoneDraft = TimeZone.current.identifier
                }
                .disabled(timezoneDraft == TimeZone.current.identifier)
                Spacer()
            }
            if let timezoneMessage {
                Text(timezoneMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Day boundaries")
        } footer: {
            // The default is UTC, which is right for nobody in particular —
            // and until this field existed it could only be changed by hand
            // editing ~/.headroom/config.json.
            Text("Where daily burn, resets and history start a new day. Follows you to your other Macs, so one person's charts agree about when today began.")
        }
        .task { await reloadTimezone() }
    }

    func reloadTimezone() async {
        guard let config = try? await client.fetchTimezoneConfiguration(),
              let zone = config.timezone, !zone.isEmpty
        else { return }
        timezoneDraft = zone
    }

    func saveTimezone() async {
        let zone = timezoneDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !zone.isEmpty else { return }
        do {
            let config = try await client.setTimezoneConfiguration(zone)
            timezoneDraft = config.timezone ?? zone
            timezoneMessage = "Saved."
        } catch {
            timezoneMessage = error.localizedDescription
        }
    }

    var updatesSection: some View {
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

    var updateStatus: String {
        if let found = updates.available {
            return HeadroomCopy.newVersionAvailable(
                from: UpdateCheck.installedVersion,
                to: found.version
            )
        }
        if updates.lastChecked != nil { return HeadroomCopy.upToDate }
        return UpdateCheck.installedVersion
    }

    var hostSection: some View {
        Section {
            TextField(text: $endpoint) {
                Text("Endpoint")
            }
            // No poll-interval control here on purpose. docs/product.md names
            // poll intervals as a tradeoff with a right answer, and the app
            // already overrode the chosen number three ways — retry backoff,
            // a 15s floor, and the idle escalation — so it only applied while
            // the popover was active and nothing was failing.
            if endpointIsRemote {
                SecureField(
                    "Host token",
                    text: $hostToken,
                    prompt: keyFieldPrompt(stored: hostTokenStored)
                )
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
                                : AnyShapeStyle(HeadroomPalette.orange))
                }
            }

            Divider()

            LabeledContent(HeadroomCopy.hostRunning) {
                Text(hostLocationLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent(HeadroomCopy.hostProcess) {
                Text(hostProcessLabel)
                    .foregroundStyle(.secondary)
            }
            if !endpointIsRemote, HostController.isBundled {
                Toggle(HeadroomCopy.hostKeepRunning, isOn: Binding(
                    get: { hostKeepRunning },
                    set: { setHostKeepRunning($0) }
                ))
                .disabled(hostLifecycleBusy)
                Text(hostKeepRunning
                     ? HeadroomCopy.hostKeepRunningOn
                     : HeadroomCopy.hostKeepRunningOff)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hostLifecycleMessage {
                    Text(hostLifecycleMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent(HeadroomCopy.hostStatus) {
                if hostHealthLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(
                        hostHealth != nil && hostHealth?.ok != false
                            ? HeadroomCopy.hostReachable
                            : HeadroomCopy.hostUnavailable,
                        systemImage: hostHealth != nil && hostHealth?.ok != false
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle"
                    )
                    .foregroundStyle(
                        hostHealth != nil && hostHealth?.ok != false
                            ? HeadroomPalette.green
                            : HeadroomPalette.orange
                    )
                }
            }
            if let hostHealth {
                LabeledContent(HeadroomCopy.hostVersion) {
                    Text(hostHealth.version ?? HeadroomCopy.hostNotAvailable)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(HeadroomCopy.hostBuild) {
                    Text(hostHealth.build ?? HeadroomCopy.hostNotAvailable)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent(HeadroomCopy.hostUptime) {
                    Text(hostUptimeLabel(hostHealth.uptimeS))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(HeadroomCopy.hostSourcesReporting) {
                    Text("\(hostHealth.sources.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let hostHealthMessage {
                Text(hostHealthMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(HeadroomCopy.hostRefreshDetails) {
                Task { await reloadHostHealth() }
            }
            .disabled(hostHealthLoading)
        } header: {
            Text("Host")
        } footer: {
            Text(endpointIsRemote
                 ? "Remote hosts need the host token (~/.headroom/token) — not the mobile token used by iPhone."
                 : "Mac, iPhone, and ESP32 all read this host. If it’s down, tap Start host or run ./scripts/install-host.sh from a clone. Source toggles also hide ESP32 pages.")
        }
    }

    func saveHostToken() {
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

    var hostLocationLabel: String {
        guard let url = URL(string: endpoint), let host = url.host() else {
            return endpoint
        }
        let address = url.port.map { "\(host):\($0)" } ?? host
        return endpointIsRemote ? "Remote · \(address)" : "This Mac · \(address)"
    }

    var hostProcessLabel: String {
        if endpointIsRemote { return HeadroomCopy.hostRemoteEndpoint }
        guard HostController.isBundled else { return HeadroomCopy.hostLocalProcess }
        return HostLifecycle.current == .appOwned
            ? HeadroomCopy.hostOwnedByApp
            : HeadroomCopy.hostLocalLaunchAgent
    }

    /// On means launchd owns the host. Off means this app does, and quitting
    /// Headroom stops it. The toggle reads as "keep running" rather than naming
    /// a LaunchAgent, because the choice is about what a quit does.
    func setHostKeepRunning(_ keepRunning: Bool) {
        hostKeepRunning = keepRunning
        hostLifecycleBusy = true
        hostLifecycleMessage = nil
        let mode: HostLifecycle = keepRunning ? .launchAgent : .appOwned
        HostLifecycle.store(mode)
        Task {
            let outcome = await HostLifecycleCoordinator.shared.apply(mode)
            switch outcome.readiness {
            case .ready:
                hostLifecycleMessage = nil
            case let .foreign(build):
                hostLifecycleMessage = """
                    Another host already owns :8737\(build.map { " (\($0))" } ?? "").
                    """
            case .silent:
                hostLifecycleMessage =
                    outcome.errorMessage ?? HeadroomCopy.hostUnavailable
            }
            await reloadHostHealth()
            hostLifecycleBusy = false
        }
    }

    func hostUptimeLabel(_ seconds: Int?) -> String {
        guard let seconds else { return HeadroomCopy.hostNotAvailable }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    func reloadHostHealth() async {
        hostHealthLoading = true
        hostHealthMessage = nil
        defer { hostHealthLoading = false }
        do {
            hostHealth = try await client.health()
        } catch {
            hostHealth = nil
            hostHealthMessage = error.localizedDescription
        }
    }

    func refreshOpenAtLogin() {
        openAtLogin = LaunchAtLogin.isRequested
        openAtLoginNeedsApproval = LaunchAtLogin.needsApproval
    }

    func setOpenAtLogin(_ enabled: Bool) {
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
