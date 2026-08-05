import SwiftUI

extension SettingsView {
    var plausibleTokenDraft: String {
        plausibleToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    var plausibleSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                tokenBackedStatus(
                    stored: plausibleTokenStored, sourceID: "plausible"
                ).label(showSymbol: true)
            }
            if plausibleTokenStored {
                LabeledContent("Credential", value: HeadroomCopy.inKeychain)
            }
            SecureField(
                "Stats API key",
                text: $plausibleToken,
                prompt: keyFieldPrompt(stored: plausibleTokenStored)
            )
                .onSubmit {
                    if !plausibleTokenDraft.isEmpty { savePlausibleToken() }
                }
            // Self-hosted Plausible was unreachable from Settings: the key
            // was synced between Macs and read by the host, but had no
            // field, no payload and no setter — while PostHog, the same
            // shape of value, had all three.
            TextField(
                "Host",
                text: $plausibleHostDraft,
                prompt: Text("https://plausible.io")
            )
            .onSubmit { Task { await savePlausibleHost() } }
            HStack {
                Button(HeadroomCopy.settingsSave) {
                    Task { await savePlausibleHost() }
                }
                .disabled(isSyncing || plausibleHostDraft
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
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
                        Task { await refreshPlausible() }
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
            Text("API key stays in Keychain (stats:read). A Stats API key is enough for counts; listing sites below also needs sites:read.")
        }

        Section {
            if !plausibleSitesEditable {
                Text(plausibleConfig.available.isEmpty
                     ? "Site settings need a running, up to date host."
                     : "Showing sites from the last poll. Update the host to choose which to track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = plausibleConfig.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(HeadroomPalette.orange)
            } else if plausibleConfig.available.isEmpty {
                Text(plausibleTokenStored
                      ? "0 sites this key can see."
                      : "Connect a key to list sites.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !plausibleConfig.available.isEmpty {
                ForEach(plausibleConfig.available) { site in
                    Toggle(isOn: Binding(
                        get: {
                            plausibleSelectedSites.isEmpty
                                || plausibleSelectedSites.contains(site.domain)
                        },
                        set: { on in
                            Task {
                                await setPlausibleSite(
                                    site.domain, enabled: on)
                            }
                        }
                    )) {
                        Text(site.name)
                    }
                    .disabled(savingPlausibleSites || !plausibleSitesEditable)
                }
                if plausibleSitesEditable, plausibleSelectedSites.isEmpty {
                    Text("All sites tracked. Untick any to narrow the list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if savingPlausibleSites {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(HeadroomCopy.settingsRefresh) {
                    Task { await refreshPlausible() }
                }
                .disabled(isSyncing)
            }
        } header: {
            Text("Sites")
        } footer: {
            Text(plausibleSitesEditable
                 ? "Tick which sites to track. Listing needs a Sites API key with sites:read."
                 : "The site list comes from Plausible once the host can answer /config/plausible.")
        }
    }

    var plausibleSelectedSites: Set<String> {
        Set(splitList(plausibleSitesDraft).map { $0.lowercased() })
    }

    func savePlausibleToken() {
        let token = plausibleTokenDraft
        guard !token.isEmpty else { return }
        do {
            try TokenStore.plausible.save(token)
            plausibleToken = ""
            plausibleTokenStored = true
            plausibleMessage = "Saved — refreshing…"
            Task { await refreshPlausible() }
        } catch {
            plausibleMessage = error.localizedDescription
        }
    }

    func disconnectPlausible() {
        TokenStore.plausible.delete()
        plausibleTokenStored = false
        plausibleToken = ""
        plausibleMessage = "Disconnected"
        Task { await refreshSources(["plausible"]) }
    }

    func applyPlausibleRange(_ range: String) async {
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

    /// Poll Plausible, then rebuild the site checklist.
    func refreshPlausible() async {
        await connectAndRefresh(["plausible"])
        await reloadPlausibleConfiguration()
    }

    func reloadPlausibleConfiguration() async {
        do {
            applyPlausibleConfiguration(
                try await client.fetchPlausibleConfiguration())
            plausibleSitesEditable = true
        } catch {
            plausibleSitesEditable = false
            await seedPlausibleSitesFromUsage()
        }
    }

    func seedPlausibleSitesFromUsage() async {
        do {
            let snapshot = try await client.fetchUsage()
            let rows = snapshot.plausible?.sites ?? []
            guard !rows.isEmpty else {
                plausibleConfig = PlausibleConfiguration(
                    sites: [],
                    available: [],
                    ok: snapshot.plausible?.ok,
                    configured: snapshot.plausible?.configured,
                    error: snapshot.plausible?.error
                )
                return
            }
            plausibleConfig = PlausibleConfiguration(
                sites: [],
                available: rows.map {
                    PlausibleSiteOption(domain: $0.domain, name: $0.domain)
                },
                ok: snapshot.plausible?.ok,
                configured: snapshot.plausible?.configured,
                error: nil
            )
            plausibleSitesDraft = ""
        } catch {
            // Leave whatever we already had.
        }
    }

    func applyPlausibleConfiguration(_ config: PlausibleConfiguration) {
        plausibleConfig = config
        plausibleSitesDraft = config.sites.joined(separator: ", ")
        if let host = config.host, !host.isEmpty {
            plausibleHostDraft = host
        }
    }

    func savePlausibleHost() async {
        let host = plausibleHostDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        do {
            applyPlausibleConfiguration(
                try await client.setPlausibleConfiguration(
                    sites: splitList(plausibleSitesDraft), host: host))
            plausibleMessage = "Saved."
            await refreshPlausible()
        } catch {
            plausibleMessage = error.localizedDescription
        }
    }

    func setPlausibleSite(_ domain: String, enabled: Bool) async {
        var sites = splitList(plausibleSitesDraft)
        let available = plausibleConfig.available.map(\.domain)
        let key = domain.lowercased()
        if enabled {
            if sites.isEmpty { return }
            if !sites.map({ $0.lowercased() }).contains(key) {
                sites.append(domain)
            }
            if !available.isEmpty,
               Set(sites.map { $0.lowercased() }) == Set(available.map { $0.lowercased() }) {
                sites = []
            }
        } else if sites.isEmpty {
            sites = available.filter { $0.lowercased() != key }
        } else {
            sites.removeAll { $0.lowercased() == key }
        }
        plausibleSitesDraft = sites.joined(separator: ", ")
        await savePlausibleConfiguration()
    }

    func savePlausibleConfiguration() async {
        savingPlausibleSites = true
        defer { savingPlausibleSites = false }
        do {
            let config = try await client.setPlausibleConfiguration(
                sites: splitList(plausibleSitesDraft))
            applyPlausibleConfiguration(config)
            plausibleMessage = config.sites.isEmpty
                ? "Saved. Reading every site this key can see."
                : "Saved."
            await connectAndRefresh(["plausible"])
        } catch {
            plausibleMessage = error.localizedDescription
        }
    }
}
