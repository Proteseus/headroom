import SwiftUI

extension SettingsView {
    var tokenDraft: String {
        supabaseToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    var supabaseSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                tokenBackedStatus(stored: tokenStored, sourceID: "supabase")
                    .label(showSymbol: true)
            }
            if tokenStored {
                LabeledContent("Credential", value: HeadroomCopy.inKeychain)
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
                        Task { await refreshSupabase() }
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
            Text("Personal access token from the Supabase dashboard — not a project anon/service key. Stays in Keychain.")
        }

        Section {
            if !supabaseProjectsEditable {
                Text(supabaseConfig.available.isEmpty
                     ? "Project settings need a running, up to date host."
                     : "Showing projects from the last poll. Update the host to choose which to track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = supabaseConfig.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.orange)
            } else if supabaseConfig.available.isEmpty {
                Text(tokenStored
                      ? "0 projects this token can see."
                      : "Connect a token to list projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !supabaseConfig.available.isEmpty {
                ForEach(supabaseConfig.available) { project in
                    Toggle(isOn: Binding(
                        get: {
                            // Empty watch list means "all" — every toggle on.
                            supabaseSelectedProjects.isEmpty
                                || supabaseSelectedProjects.contains(project.ref)
                        },
                        set: { on in
                            Task {
                                await setSupabaseProject(
                                    project.ref, enabled: on)
                            }
                        }
                    )) {
                        Text(project.name)
                    }
                    .disabled(savingSupabaseProjects || !supabaseProjectsEditable)
                }
                if supabaseProjectsEditable, supabaseSelectedProjects.isEmpty {
                    Text("All projects tracked. Untick any to narrow the list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if savingSupabaseProjects {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(HeadroomCopy.settingsRefresh) {
                    Task { await refreshSupabase() }
                }
                .disabled(isSyncing)
            }
        } header: {
            Text("Projects")
        } footer: {
            Text(supabaseProjectsEditable
                 ? "Tick which projects to track."
                 : "The project list comes from Supabase once the host can answer /config/supabase.")
        }
    }

    var supabaseSelectedProjects: Set<String> {
        Set(splitList(supabaseProjectsDraft))
    }

    func saveSupabaseToken() {
        let token = tokenDraft
        guard !token.isEmpty else { return }
        do {
            try TokenStore.supabase.save(token)
            supabaseToken = ""
            tokenStored = true
            supabaseMessage = "Saved — refreshing…"
            Task { await refreshSupabase() }
        } catch {
            supabaseMessage = error.localizedDescription
        }
    }

    func disconnectSupabase() {
        TokenStore.supabase.delete()
        tokenStored = false
        supabaseToken = ""
        supabaseMessage = "Disconnected"
        Task { await refreshSources(["supabase"]) }
    }

    /// Poll Supabase, then rebuild the project checklist (from /config when
    /// the host has it, otherwise from the /usage portfolio we just fetched).
    func refreshSupabase() async {
        await connectAndRefresh(["supabase"])
        await reloadSupabaseConfiguration()
    }

    func reloadSupabaseConfiguration() async {
        do {
            applySupabaseConfiguration(
                try await client.fetchSupabaseConfiguration())
            supabaseProjectsEditable = true
        } catch {
            // Host predates /config/supabase. Still list what /usage already
            // saw so this page is a project selector, not only a density
            // stepper with an "update the host" line.
            supabaseProjectsEditable = false
            await seedSupabaseProjectsFromUsage()
        }
    }

    /// Build the checklist from the live portfolio when Settings config is
    /// unavailable. Selection stays empty ("all") because an older host
    /// cannot persist a watch list.
    func seedSupabaseProjectsFromUsage() async {
        do {
            let snapshot = try await client.fetchUsage()
            let rows = snapshot.supabase?.projects ?? []
            guard !rows.isEmpty else {
                supabaseConfig = SupabaseConfiguration(
                    projects: [],
                    available: [],
                    ok: snapshot.supabase?.ok,
                    configured: snapshot.supabase?.configured,
                    error: snapshot.supabase?.error
                )
                return
            }
            supabaseConfig = SupabaseConfiguration(
                projects: [],
                available: rows.map {
                    SupabaseProjectOption(
                        ref: $0.ref,
                        name: ($0.name?.isEmpty == false ? $0.name! : $0.ref)
                    )
                },
                ok: snapshot.supabase?.ok,
                configured: snapshot.supabase?.configured,
                error: nil
            )
            supabaseProjectsDraft = ""
        } catch {
            // Leave whatever we already had.
        }
    }

    func applySupabaseConfiguration(_ config: SupabaseConfiguration) {
        supabaseConfig = config
        supabaseProjectsDraft = config.projects.joined(separator: ", ")
    }

    func setSupabaseProject(_ ref: String, enabled: Bool) async {
        var projects = splitList(supabaseProjectsDraft)
        let available = supabaseConfig.available.map(\.ref)
        if enabled {
            if projects.isEmpty {
                // Already tracking all — nothing to add.
                return
            }
            if !projects.contains(ref) { projects.append(ref) }
            // Selecting every available project collapses back to "all".
            if !available.isEmpty, Set(projects) == Set(available) {
                projects = []
            }
        } else if projects.isEmpty {
            // Was "all" — narrow to everything except this one.
            projects = available.filter { $0 != ref }
        } else {
            projects.removeAll { $0 == ref }
        }
        supabaseProjectsDraft = projects.joined(separator: ", ")
        await saveSupabaseConfiguration()
    }

    func saveSupabaseConfiguration() async {
        savingSupabaseProjects = true
        defer { savingSupabaseProjects = false }
        do {
            let config = try await client.setSupabaseConfiguration(
                projects: splitList(supabaseProjectsDraft))
            applySupabaseConfiguration(config)
            supabaseMessage = config.projects.isEmpty
                ? "Saved. Reading every project this token can see."
                : "Saved."
            await connectAndRefresh(["supabase"])
        } catch {
            supabaseMessage = error.localizedDescription
        }
    }
}
