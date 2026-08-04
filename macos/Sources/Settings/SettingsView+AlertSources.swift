import SwiftUI

extension SettingsView {
    var sentryTokenDraft: String {
        sentryToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var datadogAPIDraft: String {
        datadogAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var datadogAppDraft: String {
        datadogAppKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var axiomTokenDraft: String {
        axiomToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    var sentrySections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                tokenBackedStatus(
                    stored: sentryTokenStored, sourceID: "sentry"
                ).label(showSymbol: true)
            }
            if sentryTokenStored {
                LabeledContent("Credential", value: HeadroomCopy.inKeychain)
            }
            SecureField(
                "Auth token",
                text: $sentryToken,
                prompt: keyFieldPrompt(stored: sentryTokenStored)
            )
                .onSubmit {
                    if !sentryTokenDraft.isEmpty { saveSentryToken() }
                }
            TextField("Organization slug", text: $sentryOrgDraft)
                .onSubmit { Task { await saveSentryOrg() } }
            HStack {
                if sentryTokenDraft.isEmpty {
                    Button(HeadroomCopy.settingsRefresh) {
                        Task { await refreshSentry() }
                    }
                    .disabled(!sentryTokenStored || isSyncing)
                } else {
                    Button(sentryTokenStored
                           ? HeadroomCopy.settingsReplace
                           : HeadroomCopy.settingsConnect) {
                        saveSentryToken()
                    }
                    .disabled(isSyncing)
                }
                if sentryTokenStored {
                    Button(HeadroomCopy.settingsDisconnect, role: .destructive) {
                        disconnectSentry()
                    }
                    .disabled(isSyncing)
                }
                Spacer()
                Button(HeadroomCopy.settingsCreateKey) {
                    openURL("https://sentry.io/settings/auth-tokens/")
                }
                .buttonStyle(.link)
            }
            if let sentryMessage {
                Text(sentryMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Token stays in Keychain (event:read). Fresh unresolved issues light Attention; aged debt stays in the feed quietly.")
        }
    }

    @ViewBuilder
    var datadogSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                tokenBackedStatus(
                    stored: datadogKeysStored, sourceID: "datadog"
                ).label(showSymbol: true)
            }
            if datadogKeysStored {
                LabeledContent("Credential", value: HeadroomCopy.inKeychain)
            }
            SecureField(
                "API key",
                text: $datadogAPIKey,
                prompt: keyFieldPrompt(stored: datadogKeysStored)
            )
            SecureField(
                "Application key",
                text: $datadogAppKey,
                prompt: keyFieldPrompt(stored: datadogKeysStored)
            )
                .onSubmit {
                    if !datadogAPIDraft.isEmpty, !datadogAppDraft.isEmpty {
                        saveDatadogKeys()
                    }
                }
            TextField("Site", text: $datadogSiteDraft)
                .onSubmit { Task { await saveDatadogSite() } }
            HStack {
                if datadogAPIDraft.isEmpty, datadogAppDraft.isEmpty {
                    Button(HeadroomCopy.settingsRefresh) {
                        Task { await refreshDatadog() }
                    }
                    .disabled(!datadogKeysStored || isSyncing)
                } else {
                    Button(datadogKeysStored
                           ? HeadroomCopy.settingsReplace
                           : HeadroomCopy.settingsConnect) {
                        saveDatadogKeys()
                    }
                    .disabled(isSyncing
                              || datadogAPIDraft.isEmpty
                              || datadogAppDraft.isEmpty)
                }
                if datadogKeysStored {
                    Button(HeadroomCopy.settingsDisconnect, role: .destructive) {
                        disconnectDatadog()
                    }
                    .disabled(isSyncing)
                }
                Spacer()
                Button(HeadroomCopy.settingsCreateKey) {
                    openURL("https://app.datadoghq.com/organization-settings/api-keys")
                }
                .buttonStyle(.link)
            }
            if let datadogMessage {
                Text(datadogMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Both keys stay in Keychain. App key needs monitors_read. Site is datadoghq.com, datadoghq.eu, us3.datadoghq.com, …. Only Alert / Warn monitors surface — not APM or host maps.")
        }
    }

    @ViewBuilder
    var axiomSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                tokenBackedStatus(
                    stored: axiomTokenStored, sourceID: "axiom"
                ).label(showSymbol: true)
            }
            if axiomTokenStored {
                LabeledContent("Credential", value: HeadroomCopy.inKeychain)
            }
            SecureField(
                "API token",
                text: $axiomToken,
                prompt: keyFieldPrompt(stored: axiomTokenStored)
            )
                .onSubmit {
                    if !axiomTokenDraft.isEmpty { saveAxiomToken() }
                }
            TextField("Host", text: $axiomHostDraft)
                .onSubmit { Task { await saveAxiomConfig() } }
            TextField("Org id (PAT)", text: $axiomOrgDraft)
                .onSubmit { Task { await saveAxiomConfig() } }
            HStack {
                if axiomTokenDraft.isEmpty {
                    Button(HeadroomCopy.settingsRefresh) {
                        Task { await refreshAxiom() }
                    }
                    .disabled(!axiomTokenStored || isSyncing)
                } else {
                    Button(axiomTokenStored
                           ? HeadroomCopy.settingsReplace
                           : HeadroomCopy.settingsConnect) {
                        saveAxiomToken()
                    }
                    .disabled(isSyncing)
                }
                if axiomTokenStored {
                    Button(HeadroomCopy.settingsDisconnect, role: .destructive) {
                        disconnectAxiom()
                    }
                    .disabled(isSyncing)
                }
                Spacer()
                Button(HeadroomCopy.settingsCreateKey) {
                    openURL("https://app.axiom.co/settings/api-tokens")
                }
                .buttonStyle(.link)
            }
            if let axiomMessage {
                Text(axiomMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Token stays in Keychain (monitors|read). Open monitor alerts light Attention. ~/.axiom.toml is also read when present.")
        }
    }

    func saveSentryToken() {
        let token = sentryTokenDraft
        guard !token.isEmpty else { return }
        do {
            try TokenStore.sentry.save(token)
            sentryToken = ""
            sentryTokenStored = true
            sentryMessage = "Saved — refreshing…"
            Task {
                await saveSentryOrg()
                await refreshSentry()
            }
        } catch {
            sentryMessage = error.localizedDescription
        }
    }

    func disconnectSentry() {
        TokenStore.sentry.delete()
        sentryTokenStored = false
        sentryToken = ""
        sentryMessage = "Disconnected"
        Task { await refreshSources(["sentry"]) }
    }

    func saveSentryOrg() async {
        let org = sentryOrgDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let config = try await client.setSentryConfiguration(org: org)
            sentryOrgDraft = config.org ?? org
            sentryMessage = "Saved."
        } catch {
            sentryMessage = error.localizedDescription
        }
    }

    func refreshSentry() async {
        await connectAndRefresh(["sentry"])
        if let config = try? await client.fetchSentryConfiguration(),
           let org = config.org, !org.isEmpty {
            sentryOrgDraft = org
        }
    }

    func saveDatadogKeys() {
        let api = datadogAPIDraft
        let app = datadogAppDraft
        guard !api.isEmpty, !app.isEmpty else { return }
        do {
            try TokenStore.datadogAPI.save(api)
            try TokenStore.datadogApp.save(app)
            datadogAPIKey = ""
            datadogAppKey = ""
            datadogKeysStored = true
            datadogMessage = "Saved — refreshing…"
            Task {
                await saveDatadogSite()
                await refreshDatadog()
            }
        } catch {
            datadogMessage = error.localizedDescription
        }
    }

    func disconnectDatadog() {
        TokenStore.datadogAPI.delete()
        TokenStore.datadogApp.delete()
        datadogKeysStored = false
        datadogAPIKey = ""
        datadogAppKey = ""
        datadogMessage = "Disconnected"
        Task { await refreshSources(["datadog"]) }
    }

    func saveDatadogSite() async {
        let site = datadogSiteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !site.isEmpty else { return }
        do {
            let config = try await client.setDatadogConfiguration(site: site)
            datadogSiteDraft = config.site ?? site
            datadogMessage = "Saved."
        } catch {
            datadogMessage = error.localizedDescription
        }
    }

    func refreshDatadog() async {
        await connectAndRefresh(["datadog"])
        if let config = try? await client.fetchDatadogConfiguration(),
           let site = config.site, !site.isEmpty {
            datadogSiteDraft = site
        }
    }

    func saveAxiomToken() {
        let token = axiomTokenDraft
        guard !token.isEmpty else { return }
        do {
            try TokenStore.axiom.save(token)
            axiomToken = ""
            axiomTokenStored = true
            axiomMessage = "Saved — refreshing…"
            Task {
                await saveAxiomConfig()
                await refreshAxiom()
            }
        } catch {
            axiomMessage = error.localizedDescription
        }
    }

    func disconnectAxiom() {
        TokenStore.axiom.delete()
        axiomTokenStored = false
        axiomToken = ""
        axiomMessage = "Disconnected"
        Task { await refreshSources(["axiom"]) }
    }

    func saveAxiomConfig() async {
        let host = axiomHostDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let org = axiomOrgDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let config = try await client.setAxiomConfiguration(
                host: host.isEmpty ? nil : host,
                orgId: org
            )
            if let saved = config.host, !saved.isEmpty {
                axiomHostDraft = saved
            }
            axiomOrgDraft = config.orgId ?? org
            axiomMessage = "Saved."
        } catch {
            axiomMessage = error.localizedDescription
        }
    }

    func refreshAxiom() async {
        await connectAndRefresh(["axiom"])
        if let config = try? await client.fetchAxiomConfiguration() {
            if let host = config.host, !host.isEmpty {
                axiomHostDraft = host
            }
            if let org = config.orgId {
                axiomOrgDraft = org
            }
        }
    }
}
