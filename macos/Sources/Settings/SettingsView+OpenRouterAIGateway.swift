import SwiftUI

/// Two small, symmetric balance-only integrations — prepaid credits with no
/// checklist, unlike Supabase/Plausible/PostHog's project pickers.
extension SettingsView {
    var openrouterTokenDraft: String {
        openrouterToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var aiGatewayTokenDraft: String {
        aiGatewayToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    var openrouterSections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                tokenBackedStatus(
                    stored: openrouterTokenStored, sourceID: "openrouter"
                ).label(showSymbol: true)
            }
            if openrouterTokenStored {
                LabeledContent("Credential", value: HeadroomCopy.inKeychain)
            }
            SecureField(
                "Management API key",
                text: $openrouterToken,
                prompt: keyFieldPrompt(stored: openrouterTokenStored)
            )
                .onSubmit {
                    if !openrouterTokenDraft.isEmpty { saveOpenRouterToken() }
                }
            HStack {
                if openrouterTokenDraft.isEmpty {
                    Button(HeadroomCopy.settingsRefresh) {
                        Task { await connectAndRefresh(["openrouter"]) }
                    }
                    .disabled(!openrouterTokenStored || isSyncing)
                } else {
                    Button(openrouterTokenStored
                           ? HeadroomCopy.settingsReplace
                           : HeadroomCopy.settingsConnect) {
                        saveOpenRouterToken()
                    }
                    .disabled(isSyncing)
                    .keyboardShortcut(.defaultAction)
                }
                if openrouterTokenStored {
                    Button(HeadroomCopy.settingsDisconnect, role: .destructive) {
                        disconnectOpenRouter()
                    }
                    .disabled(isSyncing)
                }
                Spacer()
                Button(HeadroomCopy.settingsCreateToken) {
                    openURL("https://openrouter.ai/settings/keys")
                }
                .buttonStyle(.link)
            }
            if let openrouterMessage {
                Text(openrouterMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Needs a Management API key — a regular inference key cannot read the account balance. Stored in Keychain, never in /usage.")
        }
    }

    @ViewBuilder
    var aiGatewaySections: some View {
        Section {
            LabeledContent(HeadroomCopy.settingsStatus) {
                tokenBackedStatus(
                    stored: aiGatewayTokenStored, sourceID: "ai-gateway"
                ).label(showSymbol: true)
            }
            if aiGatewayTokenStored {
                LabeledContent("Credential", value: HeadroomCopy.inKeychain)
            }
            SecureField(
                "AI Gateway API key",
                text: $aiGatewayToken,
                prompt: keyFieldPrompt(stored: aiGatewayTokenStored)
            )
                .onSubmit {
                    if !aiGatewayTokenDraft.isEmpty { saveAIGatewayToken() }
                }
            HStack {
                if aiGatewayTokenDraft.isEmpty {
                    Button(HeadroomCopy.settingsRefresh) {
                        Task { await connectAndRefresh(["ai-gateway"]) }
                    }
                    .disabled(!aiGatewayTokenStored || isSyncing)
                } else {
                    Button(aiGatewayTokenStored
                           ? HeadroomCopy.settingsReplace
                           : HeadroomCopy.settingsConnect) {
                        saveAIGatewayToken()
                    }
                    .disabled(isSyncing)
                    .keyboardShortcut(.defaultAction)
                }
                if aiGatewayTokenStored {
                    Button(HeadroomCopy.settingsDisconnect, role: .destructive) {
                        disconnectAIGateway()
                    }
                    .disabled(isSyncing)
                }
                Spacer()
                Button(HeadroomCopy.settingsCreateToken) {
                    openURL("https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai-gateway&title=AI%20Gateway")
                }
                .buttonStyle(.link)
            }
            if let aiGatewayMessage {
                Text(aiGatewayMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Separate from Vercel deploys — this watches AI Gateway credits via a Gateway API key (not the CLI deploy login). Key stays in Keychain.")
        }
    }

    func saveOpenRouterToken() {
        let token = openrouterTokenDraft
        guard !token.isEmpty else { return }
        do {
            try TokenStore.openrouter.save(token)
            openrouterToken = ""
            openrouterTokenStored = true
            openrouterMessage = "Saved — refreshing…"
            Task { await connectAndRefresh(["openrouter"]) }
        } catch {
            openrouterMessage = error.localizedDescription
        }
    }

    func disconnectOpenRouter() {
        TokenStore.openrouter.delete()
        openrouterTokenStored = false
        openrouterToken = ""
        openrouterMessage = "Disconnected"
        Task { await refreshSources(["openrouter"]) }
    }

    func saveAIGatewayToken() {
        let token = aiGatewayTokenDraft
        guard !token.isEmpty else { return }
        do {
            try TokenStore.aiGateway.save(token)
            aiGatewayToken = ""
            aiGatewayTokenStored = true
            aiGatewayMessage = "Saved — refreshing…"
            Task { await connectAndRefresh(["ai-gateway"]) }
        } catch {
            aiGatewayMessage = error.localizedDescription
        }
    }

    func disconnectAIGateway() {
        TokenStore.aiGateway.delete()
        aiGatewayTokenStored = false
        aiGatewayToken = ""
        aiGatewayMessage = "Disconnected"
        Task { await refreshSources(["ai-gateway"]) }
    }
}
