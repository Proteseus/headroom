import SwiftUI

extension SettingsView {
    var githubTokenDraft: String {
        githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    var githubSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                tokenBackedStatus(
                    stored: githubTokenStored, sourceID: "github"
                ).label(showSymbol: true)
            }
            if githubTokenStored {
                LabeledContent("Credential", value: HeadroomCopy.inKeychain)
            }
            SecureField("ghp_… (repo)", text: $githubToken)
                .onSubmit {
                    if !githubTokenDraft.isEmpty { saveGitHubToken() }
                }
            HStack {
                if githubTokenDraft.isEmpty {
                    Button(HeadroomCopy.settingsRefresh) {
                        Task { await connectAndRefresh(["github"]) }
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
            Text("CI on GitHub — failed and running Actions, plus review/assignment inbox on watched repos. Not local commits (that is Git). Tick repos under \(githubDevRoot) to always watch them; owners and the discover cap still filter anything not ticked.")
        }
    }

    var githubSelectedAlways: Set<String> {
        Set(splitList(githubAlwaysRepos))
    }

    func saveGitHubToken() {
        let token = githubTokenDraft
        guard !token.isEmpty else { return }
        do {
            try TokenStore.github.save(token)
            githubToken = ""
            githubTokenStored = true
            githubMessage = "Saved — refreshing Actions…"
            Task { await connectAndRefresh(["github"]) }
        } catch {
            githubMessage = error.localizedDescription
        }
    }

    func disconnectGitHub() {
        TokenStore.github.delete()
        githubTokenStored = false
        githubToken = ""
        githubMessage = "Disconnected"
        Task { await refreshSources(["github"]) }
    }

    func reloadGitHubWatch() async {
        do {
            applyGitHubWatch(try await client.fetchGitHubWatch())
            githubWatchEditable = true
        } catch {
            githubWatchEditable = false
        }
    }

    func applyGitHubWatch(_ watch: GitHubWatch) {
        githubOwners = watch.owners.joined(separator: ", ")
        githubAlwaysRepos = watch.alwaysRepos.joined(separator: ", ")
        githubMaxDiscovered = watch.maxDiscovered
        githubAvailable = watch.available
        githubWatching = watch.watching
        if let root = watch.devRoot, !root.isEmpty { githubDevRoot = root }
    }

    /// Checklist path: flip one always-watch repo and persist immediately so
    /// Settings does not need a separate Save for the common case.
    func setGitHubAlwaysRepo(_ repo: String, enabled: Bool) async {
        var repos = splitList(githubAlwaysRepos)
        if enabled {
            if !repos.contains(repo) { repos.append(repo) }
        } else {
            repos.removeAll { $0 == repo }
        }
        githubAlwaysRepos = repos.joined(separator: ", ")
        await saveGitHubWatch()
    }

    func saveGitHubWatch() async {
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
}
