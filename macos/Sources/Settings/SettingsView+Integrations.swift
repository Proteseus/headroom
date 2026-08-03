import SwiftUI

extension SettingsView {
    /// Everything Headroom connects to, in one list.
    ///
    /// Grouped rather than flat because the agents can run code on this Mac
    /// and the rest only read — a distinction worth seeing without opening
    /// each leaf.
    var integrationsHub: some View {
        Form {
            ForEach(SettingsIntegration.Group.allCases, id: \.self) { group in
                Section {
                    ForEach(
                        SettingsIntegration.members(of: group), id: \.self
                    ) { kind in
                        integrationRow(kind)
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    switch group {
                    case .agents:
                        Text("These two can start work on this Mac. Everything else here only reads.")
                    case .code:
                        Text("Git is local commits on this Mac (no token). GitHub Actions is CI via a PAT. Vercel is deploys from the CLI login. All three feed \(HeadroomCopy.activity).")
                    case .balances:
                        Text("Prepaid API credits. Paste a key on this Mac; the phone only reads the balance.")
                    case .services:
                        Text("Keys stay in the Keychain on this Mac. The iPhone never sees them.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// One hub row. Shared with the Coding agents pane, which links to the two
    /// agent leaves rather than keeping a second copy of their settings.
    ///
    /// `LabeledContent` + `Label` keeps Form's icon column aligned across
    /// symbols of different widths — a bare `Label`/`Spacer`/`Text` stack
    /// opts that out and leaves titles drifting row to row.
    func integrationRow(_ kind: SettingsIntegration) -> some View {
        Button {
            leaf = .integration(kind)
        } label: {
            LabeledContent {
                HStack(spacing: 6) {
                    integrationStatus(kind).label()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            } label: {
                Label {
                    Text(kind.title)
                } icon: {
                    ProviderMark(
                        providerID: kind.rawValue,
                        size: 16,
                        fallbackSystemImage: kind.symbol
                    )
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// "Connected" is the wrong word for the two that need no credential, so
    /// they say what is actually true of them instead.
    ///
    /// Token-backed rows (Supabase / Plausible / GitHub) used to say Connected
    /// from Keychain alone. That hid a rejected PAT behind a green caption —
    /// the live `sources[]` detail is what actually answered.
    func integrationStatus(_ kind: SettingsIntegration) -> SettingsConnectionStatus {
        switch kind {
        case .claudeCode:
            let ok = claudeHooks?.installed == true
            return SettingsConnectionStatus(
                ok ? HeadroomCopy.hooksInstalled : HeadroomCopy.hooksOff,
                tone: ok ? .ok : .attention
            )
        case .codex:
            return SettingsConnectionStatus(
                agentGatewayEnabled
                    ? HeadroomCopy.gatewayOn : HeadroomCopy.gatewayOff,
                tone: agentGatewayEnabled ? .ok : .attention
            )
        case .git:
            // A host predating /config/git leaves the defaults in place, and
            // "0 repos" would be an answer rather than the non-answer it is.
            guard gitEditable else { return .unknown }
            guard gitConfig.devRootExists else { return .folderMissing }
            let count = gitConfig.repos.count
            let title = count == 1 ? "1 repo" : "\(count) repos"
            return SettingsConnectionStatus(
                title,
                tone: count > 0 ? .ok : .attention
            )
        case .vercel:
            guard vercelEditable else { return .unknown }
            return .signedIn(vercelConfig.signedIn)
        case .github:
            return tokenBackedStatus(
                stored: githubTokenStored, sourceID: "github")
        case .supabase:
            return tokenBackedStatus(
                stored: tokenStored, sourceID: "supabase")
        case .plausible:
            return tokenBackedStatus(
                stored: plausibleTokenStored, sourceID: "plausible")
        case .posthog:
            return tokenBackedStatus(
                stored: posthogTokenStored, sourceID: "posthog")
        case .sentry:
            return tokenBackedStatus(
                stored: sentryTokenStored, sourceID: "sentry")
        case .datadog:
            return tokenBackedStatus(
                stored: datadogKeysStored, sourceID: "datadog")
        case .axiom:
            return tokenBackedStatus(
                stored: axiomTokenStored, sourceID: "axiom")
        case .openrouter:
            return tokenBackedStatus(
                stored: openrouterTokenStored, sourceID: "openrouter")
        case .aiGateway:
            return tokenBackedStatus(
                stored: aiGatewayTokenStored, sourceID: "ai-gateway")
        }
    }

    /// Key present + whether the last poll accepted it. Hub and detail share
    /// this so "Connected" never outranks "token rejected".
    func tokenBackedStatus(
        stored: Bool, sourceID: String
    ) -> SettingsConnectionStatus {
        if !stored {
            return .connected(false)
        }
        guard let source = sources.first(where: { $0.id == sourceID }) else {
            // Keychain yes, never seen in /usage — still better than lying.
            return SettingsConnectionStatus(
                HeadroomCopy.inKeychain,
                tone: .ok,
                symbol: "key.fill"
            )
        }
        if source.ok == true {
            return SettingsConnectionStatus(
                source.detail ?? HeadroomCopy.connected,
                tone: .good,
                symbol: "checkmark.circle.fill"
            )
        }
        if let error = source.error, !error.isEmpty {
            return SettingsConnectionStatus(
                error,
                tone: .attention,
                symbol: "exclamationmark.triangle.fill"
            )
        }
        if let detail = source.detail, !detail.isEmpty {
            return SettingsConnectionStatus(
                detail,
                tone: .attention,
                symbol: "exclamationmark.triangle.fill"
            )
        }
        return SettingsConnectionStatus(
            HeadroomCopy.inKeychain,
            tone: .attention,
            symbol: "key.fill"
        )
    }

    @ViewBuilder
    func integrationPane(_ kind: SettingsIntegration) -> some View {
        Form {
            visibilitySection(kind)
            switch kind {
            case .claudeCode: claudeCodeSections
            case .codex: codexSections
            case .git: gitSections
            case .github: githubSections
            case .vercel: vercelSections
            case .supabase: supabaseSections
            case .plausible: plausibleSections
            case .posthog: posthogSections
            case .sentry: sentrySections
            case .datadog: datadogSections
            case .axiom: axiomSections
            case .openrouter: openrouterSections
            case .aiGateway: aiGatewaySections
            }
        }
        .formStyle(.grouped)
    }

    /// The on/off for a dev tool, which used to live as a row in the Sources
    /// pane. Sources now lists AI providers only, so this leaf is the only
    /// place left to switch one off.
    ///
    /// Which kinds get it is read off the payload rather than a second list
    /// here: an integration whose source sits in the `devtools` group is
    /// exactly one that left the Sources pane. AI-group integrations
    /// (Claude, Codex, OpenRouter, AI Gateway) still have their row over
    /// there, and a second switch for the same bit is how the two pages got
    /// confusing in the first place. A host too old to send the source at
    /// all simply shows no toggle.
    @ViewBuilder
    private func visibilitySection(_ kind: SettingsIntegration) -> some View {
        if let source = sources.first(where: { $0.id == kind.rawValue }),
           source.sourceGroup == .devtools {
            Section {
                Toggle(HeadroomCopy.showInHeadroom, isOn: Binding(
                    get: { source.enabled ?? true },
                    set: { on in
                        Task { await setSourceRows([source.id], enabled: on) }
                    }
                ))
                .disabled(togglingSourceID == source.id)
            } footer: {
                Text("Off stops polling and hides its rows. The key stays in the Keychain — \(HeadroomCopy.settingsDisconnect) is what forgets it.")
            }
        }
    }

    var aboutPane: some View {
        Form {
            Section {
                AboutHeadroomView()
            }
        }
        .formStyle(.grouped)
    }
}
