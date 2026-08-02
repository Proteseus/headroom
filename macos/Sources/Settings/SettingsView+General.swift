import SwiftUI

extension SettingsView {
    var generalPane: some View {
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
                Button {
                    leaf = .otherMacs
                } label: {
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(multiMac.enabled ? HeadroomCopy.on : HeadroomCopy.off)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    } label: {
                        Label(
                            HeadroomCopy.otherMacs,
                            systemImage: SettingsDestination.otherMacs.symbol
                        )
                    }
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Share sources and settings between Macs through iCloud Drive.")
            }

            // Activity and Local servers are Mac-wide; Supabase / Plausible
            // density lives on each integration's own page.
            //
            // Local servers carries its own on/off here because it is the one
            // dev-tool source with nothing to configure — no key, no account,
            // so no leaf under Integrations to hold the switch that used to
            // live in the Sources pane.
            Section {
                Stepper(
                    "\(HeadroomCopy.activity) rows: \(activityRowLimit)",
                    value: $activityRowLimit,
                    in: 3...14
                )
                if let local = sources.first(where: { $0.id == "local" }) {
                    Toggle(
                        HeadroomCopy.localServers,
                        isOn: Binding(
                            get: { local.enabled ?? true },
                            set: { on in
                                Task {
                                    await setSourceRows([local.id], enabled: on)
                                }
                            }
                        )
                    )
                    .disabled(togglingSourceID == local.id)
                }
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
        if let found = updates.available { return "\(found.version) available" }
        if updates.lastChecked != nil { return HeadroomCopy.upToDate }
        return UpdateCheck.installedVersion
    }

    var hostSection: some View {
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
