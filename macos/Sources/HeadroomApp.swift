import AppKit
import Security
import SwiftUI

@main
struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let store = UsageStore()
        self.store = store
        statusController = StatusItemController(store: store)
        store.start()
    }
}

private struct SettingsView: View {
    @AppStorage("usageEndpoint")
    private var endpoint = "http://127.0.0.1:8737/usage"
    @AppStorage("refreshInterval")
    private var refreshInterval = 60
    @AppStorage("activityRowLimit")
    private var activityRowLimit = 8
    @AppStorage("serverRowLimit")
    private var serverRowLimit = 5
    @AppStorage("confirmServerStops")
    private var confirmServerStops = true
    @AppStorage("supabaseRowLimit")
    private var supabaseRowLimit = 6

    @State private var sources: [SyncSource] = []
    @State private var sourcesMessage: String?
    @State private var isSyncing = false
    @State private var togglingSourceID: String?

    @State private var supabaseToken = ""
    @State private var tokenStored = false
    @State private var supabaseMessage: String?

    @State private var githubToken = ""
    @State private var githubTokenStored = false
    @State private var githubMessage: String?

    private var tokenDraft: String {
        supabaseToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var githubTokenDraft: String {
        githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
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
                    Text("Refresh")
                }
            } header: {
                Text("Backend")
            } footer: {
                Text("Mac and ESP32 both read this host. Source toggles also hide ESP32 pages.")
            }

            Section {
                if sources.isEmpty {
                    Text(sourcesMessage ?? "Waiting for host…")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sources) { source in
                        SourceRow(
                            source: source,
                            isBusy: togglingSourceID == source.id || isSyncing,
                            onToggle: { enabled in
                                Task { await setSource(source.id, enabled: enabled) }
                            },
                            onRefresh: {
                                Task { await refreshSources([source.id]) }
                            }
                        )
                    }
                }

                Button {
                    Task { await refreshSources(nil) }
                } label: {
                    HStack {
                        Text("Refresh all sources")
                        Spacer()
                        if isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isSyncing || sources.isEmpty)

                if let sourcesMessage {
                    Text(sourcesMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("ESP32 footer dots mirror this list. Long-press Home on glance forces a sync.")
            }

            Section {
                LabeledContent("Status") {
                    Text(tokenStored ? "Keychain" : "Not connected")
                        .foregroundStyle(tokenStored ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
                SecureField("sbp_… or access token", text: $supabaseToken)
                    .onSubmit {
                        if !tokenDraft.isEmpty { saveSupabaseToken() }
                    }
                HStack {
                    if tokenDraft.isEmpty {
                        Button("Refresh") {
                            Task { await refreshSources(["supabase"]) }
                        }
                        .disabled(!tokenStored || isSyncing)
                    } else {
                        Button(tokenStored ? "Replace" : "Connect") {
                            saveSupabaseToken()
                        }
                        .disabled(isSyncing)
                        .keyboardShortcut(.defaultAction)
                    }
                    if tokenStored {
                        Button("Disconnect", role: .destructive) {
                            disconnectSupabase()
                        }
                        .disabled(isSyncing)
                    }
                    Spacer()
                    Button("Create token…") {
                        openURL("https://supabase.com/dashboard/account/tokens")
                    }
                    .buttonStyle(.link)
                }
                if let supabaseMessage {
                    Text(supabaseMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Supabase")
            } footer: {
                Text("PAT stays in Keychain and never appears in /usage.")
            }

            Section {
                LabeledContent("Status") {
                    Text(githubTokenStored ? "Keychain" : "Not connected")
                        .foregroundStyle(githubTokenStored ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
                SecureField("ghp_… (repo + actions:read)", text: $githubToken)
                    .onSubmit {
                        if !githubTokenDraft.isEmpty { saveGitHubToken() }
                    }
                HStack {
                    if githubTokenDraft.isEmpty {
                        Button("Refresh") {
                            Task { await refreshSources(["github"]) }
                        }
                        .disabled(!githubTokenStored || isSyncing)
                    } else {
                        Button(githubTokenStored ? "Replace" : "Connect") {
                            saveGitHubToken()
                        }
                        .disabled(isSyncing)
                    }
                    if githubTokenStored {
                        Button("Disconnect", role: .destructive) {
                            disconnectGitHub()
                        }
                        .disabled(isSyncing)
                    }
                    Spacer()
                    Button("Create token…") {
                        openURL("https://github.com/settings/tokens")
                    }
                    .buttonStyle(.link)
                }
                if let githubMessage {
                    Text(githubMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("GitHub Actions")
            } footer: {
                Text("Watches envisioning/* remotes. Failed and running workflows show in Activity.")
            }

            Section("Dashboard") {
                Stepper(
                    "Activity rows: \(activityRowLimit)",
                    value: $activityRowLimit,
                    in: 3...14
                )
                Stepper(
                    "Local servers: \(serverRowLimit)",
                    value: $serverRowLimit,
                    in: 1...8
                )
                Stepper(
                    "Supabase projects: \(supabaseRowLimit)",
                    value: $supabaseRowLimit,
                    in: 1...20
                )
                Toggle("Confirm before stopping servers", isOn: $confirmServerStops)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .task {
            tokenStored = SupabaseTokenStore.exists()
            githubTokenStored = GitHubTokenStore.exists()
            await reloadSources()
        }
    }

    private func saveSupabaseToken() {
        let token = tokenDraft
        guard !token.isEmpty else { return }
        do {
            try SupabaseTokenStore.save(token)
            supabaseToken = ""
            tokenStored = true
            supabaseMessage = "Saved — refreshing…"
            Task { await refreshSources(["supabase"]) }
        } catch {
            supabaseMessage = error.localizedDescription
        }
    }

    private func disconnectSupabase() {
        SupabaseTokenStore.delete()
        tokenStored = false
        supabaseToken = ""
        supabaseMessage = "Disconnected"
        Task { await refreshSources(["supabase"]) }
    }

    private func saveGitHubToken() {
        let token = githubTokenDraft
        guard !token.isEmpty else { return }
        do {
            try GitHubTokenStore.save(token)
            githubToken = ""
            githubTokenStored = true
            githubMessage = "Saved — refreshing Actions…"
            Task { await refreshSources(["github"]) }
        } catch {
            githubMessage = error.localizedDescription
        }
    }

    private func disconnectGitHub() {
        GitHubTokenStore.delete()
        githubTokenStored = false
        githubToken = ""
        githubMessage = "Disconnected"
        Task { await refreshSources(["github"]) }
    }

    private func setSource(_ id: String, enabled: Bool) async {
        togglingSourceID = id
        defer { togglingSourceID = nil }
        do {
            var map = Dictionary(
                uniqueKeysWithValues: sources.map { ($0.id, $0.enabled ?? true) })
            map[id] = enabled
            _ = try await BackendClient.setSources(endpoint: endpoint, enabled: map)
            try? await Task.sleep(for: .milliseconds(600))
            await reloadSources()
            sourcesMessage = enabled
                ? "Enabled \(id) — ESP32 will show it on next poll."
                : "Disabled \(id) — ESP32 will hide that page."
        } catch {
            sourcesMessage = error.localizedDescription
        }
    }

    private func refreshSources(_ ids: [String]?) async {
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await BackendClient.refresh(endpoint: endpoint, sources: ids)
            try? await Task.sleep(for: .milliseconds(900))
            await reloadSources()
            if ids == ["supabase"] {
                supabaseMessage = sources
                    .first(where: { $0.id == "supabase" })?
                    .detail ?? "Supabase refreshed"
            }
            sourcesMessage = "Synced."
        } catch {
            sourcesMessage = error.localizedDescription
        }
        tokenStored = SupabaseTokenStore.exists()
        githubTokenStored = GitHubTokenStore.exists()
    }

    private func reloadSources() async {
        do {
            let snapshot = try await BackendClient.fetchUsage(endpoint: endpoint)
            sources = snapshot.sources ?? []
            if sources.isEmpty {
                sourcesMessage = "Host has no sources payload — restart com.mz.headroom."
            }
        } catch {
            sourcesMessage = error.localizedDescription
        }
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SourceRow: View {
    let source: SyncSource
    let isBusy: Bool
    let onToggle: (Bool) -> Void
    let onRefresh: () -> Void

    private var enabled: Bool { source.enabled ?? true }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.title ?? source.id)
                Text(secondaryLine)
                    .font(.caption)
                    .foregroundStyle(
                        source.ok == true || !enabled
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(Color.orange)
                    )
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                onRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isBusy || !enabled)
            .help("Force refresh")

            Toggle(
                "Enabled",
                isOn: Binding(
                    get: { enabled },
                    set: { onToggle($0) }
                )
            )
            .labelsHidden()
            .disabled(isBusy)
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .opacity(enabled ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    private var secondaryLine: String {
        var parts: [String] = []
        if let detail = source.detail ?? source.hint ?? source.error {
            parts.append(detail)
        }
        if let age = source.ageS {
            parts.append(ageLabel(age))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private var dotColor: Color {
        if !enabled { return .secondary }
        if source.ok == true {
            return source.stale == true ? .orange : .green
        }
        return .red
    }

    private func ageLabel(_ age: Int) -> String {
        let stale = source.stale == true
        if age < 5 {
            return stale ? "stale · just now" : "just now"
        }
        if age < 60 {
            return stale ? "\(age)s stale" : "\(age)s ago"
        }
        let minutes = age / 60
        return stale ? "\(minutes)m stale" : "\(minutes)m ago"
    }
}

private enum BackendClient {
    enum ClientError: LocalizedError {
        case invalidEndpoint
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                "The headroom endpoint is invalid."
            case let .badResponse(code):
                "The backend returned HTTP \(code)."
            }
        }
    }

    private static func baseURL(from endpoint: String) throws -> URL {
        guard let usageURL = URL(string: endpoint) else {
            throw ClientError.invalidEndpoint
        }
        return usageURL.lastPathComponent == "usage"
            ? usageURL.deletingLastPathComponent()
            : usageURL
    }

    static func fetchUsage(endpoint: String) async throws -> UsageSnapshot {
        guard let url = URL(string: endpoint) else {
            throw ClientError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    static func refresh(endpoint: String, sources: [String]?) async throws {
        let url = try baseURL(from: endpoint)
            .appendingPathComponent("sync")
            .appendingPathComponent("refresh")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        if let sources, !sources.isEmpty {
            body = ["sources": sources]
        } else {
            body = [:]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 8
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badResponse(http.statusCode)
        }
    }

    static func setSources(endpoint: String, enabled: [String: Bool]) async throws -> [String: Bool] {
        let url = try baseURL(from: endpoint)
            .appendingPathComponent("sources")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["enabled": enabled])
        request.timeoutInterval = 8
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badResponse(http.statusCode)
        }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["enabled"] as? [String: Bool]) ?? enabled
    }
}

private enum SupabaseTokenStore {
    static let service = "com.mz.headroom.supabase"
    static let account = "access-token"

    static func exists() -> Bool {
        KeychainPassword.exists(service: service, account: account)
    }

    static func save(_ token: String) throws {
        try KeychainPassword.save(
            token, service: service, account: account,
            failure: "Could not save Supabase token.")
    }

    static func delete() {
        KeychainPassword.delete(service: service, account: account)
    }
}

private enum GitHubTokenStore {
    static let service = "com.mz.headroom.github"
    static let account = "access-token"

    static func exists() -> Bool {
        KeychainPassword.exists(service: service, account: account)
    }

    static func save(_ token: String) throws {
        try KeychainPassword.save(
            token, service: service, account: account,
            failure: "Could not save GitHub token.")
    }

    static func delete() {
        KeychainPassword.delete(service: service, account: account)
    }
}

private enum KeychainPassword {
    static func exists(service: String, account: String) -> Bool {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func save(
        _ token: String, service: String, account: String, failure: String
    ) throws {
        delete(service: service, account: account)
        var attributes = baseQuery(service: service, account: account)
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: failure]
            )
        }
    }

    static func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
