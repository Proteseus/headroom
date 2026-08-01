import SwiftUI

extension SettingsView {
    @ViewBuilder
    var vercelSections: some View {
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

    var vercelSelectedTeams: Set<String> {
        Set(splitList(vercelTeamsDraft).map { $0.lowercased() })
    }

    func reloadVercelConfiguration() async {
        do {
            applyVercelConfiguration(
                try await client.fetchVercelConfiguration())
            vercelEditable = true
        } catch {
            vercelEditable = false
        }
    }

    func applyVercelConfiguration(_ config: VercelConfiguration) {
        vercelConfig = config
        vercelTeamsDraft = config.teams.joined(separator: ", ")
    }

    func saveVercelConfiguration() async {
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

    func setVercelTeam(_ slug: String, enabled: Bool) async {
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
}
