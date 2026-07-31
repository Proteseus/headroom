import AppKit
import SwiftUI

/// Settings → more than one login per provider.
///
/// One Mac often has two Claude logins (personal and work), and the CLIs
/// already keep each one in its own folder — `CLAUDE_CONFIG_DIR`, `CODEX_HOME`,
/// a second Cursor profile. Headroom only ever read the default, so the other
/// plan was invisible. Adding one here is exactly that: point a row at the
/// other folder and give it a name.
///
/// No token ever passes through this pane. The host reads the credentials the
/// CLI already wrote, which is why `/accounts` is loopback-only and why this
/// view sends a path rather than a secret.
struct AccountsSection: View {
    let endpoint: String
    /// Called once the host is back up, so Settings can reload its rows.
    var onChanged: () async -> Void

    @State private var providers: [AccountProvider] = []
    @State private var selectedProvider: String = ""
    @State private var label = ""
    @State private var message: String?
    @State private var isBusy = false
    /// False when the host predates /accounts, so the pane says so instead of
    /// offering an Add button that can only fail.
    @State private var supported = true

    private var client: HeadroomClient { HeadroomClient(endpoint: endpoint) }

    private var current: AccountProvider? {
        providers.first { $0.id == selectedProvider } ?? providers.first
    }

    var body: some View {
        Section {
            if !supported {
                // "Predates" is a changelog word. The reader wants the verb.
                Text("This host is too old for extra accounts. Update it from the Setup card above.")
                    .foregroundStyle(.secondary)
            } else if providers.isEmpty {
                Text(message ?? "Waiting for host…")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(providers) { provider in
                    ForEach(provider.accounts) { account in
                        AccountRow(
                            provider: provider,
                            account: account,
                            isBusy: isBusy,
                            onRemove: { Task { await remove(account) } }
                        )
                    }
                }
                addControls
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Extra accounts")
        } footer: {
            Text(footerText)
        }
        .task { await reload() }
    }

    @ViewBuilder
    private var addControls: some View {
        HStack {
            Picker("Provider", selection: $selectedProvider) {
                ForEach(providers) { provider in
                    Text(provider.title).tag(provider.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 140)

            TextField("Name (Work)", text: $label)

            Button(current?.wantsFolder == true ? "Choose folder…" : "Choose file…") {
                choose()
            }
            .disabled(isBusy || current?.isFull == true)
        }
        if current?.isFull == true {
            Text("\(current?.title ?? "This provider") is at its account limit.")
                .font(.caption)
                .foregroundStyle(HeadroomPalette.amber)
        }
    }

    private var footerText: String {
        guard let hint = current?.hint, let title = current?.title else {
            return "Point Headroom at a second credential location to meter another login of the same tool."
        }
        return "Each account is metered on its own ring, with its own burndown. \(title): \(hint). Adding or removing one restarts the host."
    }

    /// A path, chosen the way a person picks one. Typing it would be the
    /// likeliest place to get this wrong, and the host can only tell you
    /// afterwards that the folder isn't there.
    private func choose() {
        guard let provider = current else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = provider.wantsFolder
        panel.canChooseFiles = !provider.wantsFolder
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use"
        panel.message = provider.wantsFolder
            ? "Pick the \(provider.title) config folder for this account"
            : "Pick the \(provider.title) credential store for this account"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await add(provider: provider, root: url.path) }
    }

    private func add(provider: AccountProvider, root: String) async {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            message = "Give the account a name first."
            return
        }
        await write(action: "Added \(provider.title) · \(name).") {
            try await client.addAccount(
                provider: provider.id, label: name, root: root)
        }
        label = ""
    }

    private func remove(_ account: ProviderAccount) async {
        await write(action: "Removed \(account.label).") {
            try await client.removeAccount(account.id)
        }
    }

    /// Both writes restart the host, so both wait for it before reporting
    /// success — otherwise the reload lands on the dying process and shows
    /// the list the change was meant to replace.
    private func write(
        action: String,
        _ body: @escaping () async throws -> ProviderAccounts
    ) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        // launchd hands the same port to whatever host it just started, so
        // "still 200 on :8737" proves nothing. Uptime going backwards is what
        // says the process actually changed underneath.
        let before = try? await client.health().uptimeS
        do {
            let result = try await body()
            providers = result.providers
            message = "\(action) Restarting host…"
            await waitForRestart(previousUptime: before)
            await reload()
            await onChanged()
            message = action
        } catch {
            message = error.localizedDescription
        }
    }

    private func waitForRestart(previousUptime: Int?) async {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            guard let report = try? await client.health() else { continue }
            guard let before = previousUptime, let now = report.uptimeS else {
                return
            }
            if now < before { return }
        }
    }

    private func reload() async {
        do {
            let result = try await client.fetchAccounts()
            providers = result.providers
            supported = true
            if selectedProvider.isEmpty || !result.providers.contains(
                where: { $0.id == selectedProvider }) {
                selectedProvider = result.providers.first?.id ?? ""
            }
        } catch HeadroomClient.ClientError.badResponse(404) {
            supported = false
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct AccountRow: View {
    let provider: AccountProvider
    let account: ProviderAccount
    let isBusy: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(HeadroomPalette.providerTint(
                    id: provider.id, accent: provider.accent))
                .frame(width: 9, height: 9)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(provider.title) · \(account.label)")
                Text(account.root)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button("Remove", role: .destructive, action: onRemove)
                .disabled(isBusy)
        }
        .accessibilityElement(children: .combine)
    }
}
