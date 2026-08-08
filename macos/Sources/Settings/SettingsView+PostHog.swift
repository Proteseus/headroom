import SwiftUI

extension SettingsView {
    static let posthogUSHost = "https://us.posthog.com"
    static let posthogEUHost = "https://eu.posthog.com"

    var posthogTokenDraft: String {
        posthogToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalized host without a trailing slash, for comparing cloud regions.
    var posthogHostNormalized: String {
        posthogHostDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Cloud region URL when the draft is US or EU; nil means Custom / self-hosted.
    var posthogCloudHost: String? {
        switch posthogHostNormalized.lowercased() {
        case Self.posthogUSHost: return Self.posthogUSHost
        case Self.posthogEUHost: return Self.posthogEUHost
        default: return nil
        }
    }

    @ViewBuilder
    var posthogSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                tokenBackedStatus(
                    stored: posthogTokenStored, sourceID: "posthog"
                ).label(showSymbol: true)
            }
            if posthogTokenStored {
                LabeledContent("Credential", value: HeadroomCopy.inKeychain)
            }
            SecureField(
                "Personal API key",
                text: $posthogToken,
                prompt: keyFieldPrompt(stored: posthogTokenStored)
            )
                .onSubmit {
                    if !posthogTokenDraft.isEmpty { savePostHogToken() }
                }
            Picker("Region", selection: Binding(
                get: { posthogCloudHost ?? "custom" },
                set: { newValue in
                    if newValue == "custom" {
                        if posthogCloudHost != nil {
                            posthogHostDraft = ""
                        }
                        return
                    }
                    guard newValue != posthogHostNormalized else { return }
                    posthogHostDraft = newValue
                    Task { await savePostHogHost() }
                }
            )) {
                Text("US Cloud").tag(Self.posthogUSHost)
                Text("EU Cloud").tag(Self.posthogEUHost)
                Text("Custom").tag("custom")
            }
            .disabled(isSyncing)
            if posthogCloudHost == nil {
                TextField(
                    "Host",
                    text: $posthogHostDraft,
                    prompt: Text("https://posthog.example.com")
                )
                .onSubmit {
                    Task { await savePostHogHost() }
                }
                // Return alone used to be the only way to commit this, so
                // typing a host and clicking elsewhere threw the edit away
                // with nothing on screen to suggest it had.
                HStack {
                    Button(HeadroomCopy.settingsSave) {
                        Task { await savePostHogHost() }
                    }
                    .disabled(isSyncing || posthogHostDraft
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
            }
            Picker("Window", selection: Binding(
                get: { posthogRange },
                set: { newValue in
                    guard newValue != posthogRange else { return }
                    posthogRange = newValue
                    Task { await applyPostHogRange(newValue) }
                }
            )) {
                Text("Today").tag("day")
                Text("Last 24 hours").tag("24h")
                Text("Last 7 days").tag("7d")
                Text("Last 30 days").tag("30d")
            }
            .disabled(isSyncing)
            HStack {
                if posthogTokenDraft.isEmpty {
                    Button(HeadroomCopy.settingsRefresh) {
                        Task { await refreshPostHog() }
                    }
                    .disabled(!posthogTokenStored || isSyncing)
                } else {
                    Button(posthogTokenStored
                           ? HeadroomCopy.settingsReplace
                           : HeadroomCopy.settingsConnect) {
                        savePostHogToken()
                    }
                    .disabled(isSyncing)
                }
                if posthogTokenStored {
                    Button(HeadroomCopy.settingsDisconnect, role: .destructive) {
                        disconnectPostHog()
                    }
                    .disabled(isSyncing)
                }
                Spacer()
                Button(HeadroomCopy.settingsCreateKey) {
                    let base = posthogCloudHost == Self.posthogEUHost
                        ? Self.posthogEUHost
                        : "https://app.posthog.com"
                    openURL("\(base)/settings/user-api-keys")
                }
                .buttonStyle(.link)
            }
            if let posthogMessage {
                Text(posthogMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Personal API key stays in Keychain (project:read, query:read). Self-hosted? Pick Custom and paste the URL.")
        }

        Section {
            if !posthogProjectsEditable {
                Text(posthogConfig.available.isEmpty
                     ? "Project settings need a running, up to date host."
                     : "Showing projects from the last poll. Update the host to choose which to track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = posthogConfig.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.orange)
            } else if posthogConfig.available.isEmpty {
                Text(posthogTokenStored
                      ? "0 projects this key can see."
                      : "Connect a key to list projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !posthogConfig.available.isEmpty {
                ForEach(posthogConfig.available) { project in
                    Toggle(isOn: Binding(
                        get: {
                            posthogSelectedProjects.isEmpty
                                || posthogSelectedProjects.contains(project.id)
                        },
                        set: { on in
                            Task {
                                await setPostHogProject(
                                    project.id, enabled: on)
                            }
                        }
                    )) {
                        Text(project.name)
                    }
                    .disabled(savingPostHogProjects || !posthogProjectsEditable)
                }
                if posthogProjectsEditable, posthogSelectedProjects.isEmpty {
                    Text("All projects tracked. Untick any to narrow the list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if savingPostHogProjects {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(HeadroomCopy.settingsRefresh) {
                    Task { await refreshPostHog() }
                }
                .disabled(isSyncing)
            }
        } header: {
            Text("Projects")
        } footer: {
            Text(posthogProjectsEditable
                 ? "Tick which projects to track. Listing uses project:read; event counts use query:read."
                 : "The project list comes from PostHog once the host can answer /config/posthog.")
        }
    }

    var posthogSelectedProjects: Set<String> {
        Set(splitList(posthogProjectsDraft))
    }

    func savePostHogToken() {
        let token = posthogTokenDraft
        guard !token.isEmpty else { return }
        do {
            try TokenStore.posthog.save(token)
            posthogToken = ""
            posthogTokenStored = true
            posthogMessage = "Saved — refreshing…"
            Task { await refreshPostHog() }
        } catch {
            posthogMessage = error.localizedDescription
        }
    }

    func disconnectPostHog() {
        TokenStore.posthog.delete()
        posthogTokenStored = false
        posthogToken = ""
        posthogMessage = "Disconnected"
        Task { await refreshSources(["posthog"]) }
    }

    func applyPostHogRange(_ range: String) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            let saved = try await client.setPostHogRange(range)
            posthogRange = saved
            await client.waitForRefresh(sources: ["posthog"])
            await reloadSources()
            posthogMessage = sources
                .first(where: { $0.id == "posthog" })?
                .detail ?? "Window updated"
        } catch {
            posthogMessage = error.localizedDescription
        }
    }

    /// Poll PostHog, then rebuild the project checklist.
    func refreshPostHog() async {
        await connectAndRefresh(["posthog"])
        await reloadPostHogConfiguration()
    }

    func reloadPostHogConfiguration() async {
        do {
            let config = try await client.fetchPostHogConfiguration()
            applyPostHogConfiguration(config)
            posthogProjectsEditable = true
        } catch {
            posthogProjectsEditable = false
            await seedPostHogProjectsFromUsage()
        }
    }

    func seedPostHogProjectsFromUsage() async {
        do {
            let snapshot = try await client.fetchUsage()
            let rows = snapshot.posthog?.projects ?? []
            guard !rows.isEmpty else {
                posthogConfig = PostHogConfiguration(
                    projects: [],
                    available: [],
                    host: posthogHostDraft,
                    ok: snapshot.posthog?.ok,
                    configured: snapshot.posthog?.configured,
                    error: snapshot.posthog?.error
                )
                return
            }
            posthogConfig = PostHogConfiguration(
                projects: [],
                available: rows.map {
                    PostHogProjectOption(
                        id: $0.id, name: $0.displayName)
                },
                host: posthogHostDraft,
                ok: snapshot.posthog?.ok,
                configured: snapshot.posthog?.configured,
                error: nil
            )
            posthogProjectsDraft = ""
        } catch {
            // Leave whatever we already had.
        }
    }

    func applyPostHogConfiguration(_ config: PostHogConfiguration) {
        posthogConfig = config
        posthogProjectsDraft = config.projects.joined(separator: ", ")
        if let host = config.host, !host.isEmpty {
            posthogHostDraft = host
        }
    }

    func setPostHogProject(_ projectID: String, enabled: Bool) async {
        var projects = splitList(posthogProjectsDraft)
        let available = posthogConfig.available.map(\.id)
        if enabled {
            if projects.isEmpty { return }
            if !projects.contains(projectID) {
                projects.append(projectID)
            }
            if !available.isEmpty,
               Set(projects) == Set(available) {
                projects = []
            }
        } else if projects.isEmpty {
            projects = available.filter { $0 != projectID }
        } else {
            projects.removeAll { $0 == projectID }
        }
        posthogProjectsDraft = projects.joined(separator: ", ")
        await savePostHogConfiguration()
    }

    func savePostHogHost() async {
        await savePostHogConfiguration(includeHost: true)
    }

    func savePostHogConfiguration(includeHost: Bool = false) async {
        savingPostHogProjects = true
        defer { savingPostHogProjects = false }
        do {
            let host = includeHost
                ? posthogHostDraft.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                : nil
            let config = try await client.setPostHogConfiguration(
                projects: splitList(posthogProjectsDraft),
                host: (host?.isEmpty == false) ? host : nil)
            applyPostHogConfiguration(config)
            posthogMessage = config.projects.isEmpty
                ? "Saved. Reading every project this key can see."
                : "Saved."
            await connectAndRefresh(["posthog"])
        } catch {
            posthogMessage = error.localizedDescription
        }
    }
}
