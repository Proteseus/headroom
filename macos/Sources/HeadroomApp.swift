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
    @State private var supabaseToken = ""
    @State private var supabaseConnected = false
    @State private var supabaseMessage: String?

    var body: some View {
        Form {
            Section("Backend") {
                TextField("Usage endpoint", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                Picker("Refresh every", selection: $refreshInterval) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                }
                Text("Headroom and the ESP32 read the same backend.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            }
            Section("Server controls") {
                Toggle("Confirm before stopping", isOn: $confirmServerStops)
                Text("Stop sends SIGTERM only after the backend revalidates the process.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Supabase") {
                SecureField(
                    supabaseConnected
                        ? "Connected — paste to replace token"
                        : "Personal access token",
                    text: $supabaseToken
                )
                .textFieldStyle(.roundedBorder)
                HStack {
                    Button(supabaseConnected ? "Replace token" : "Connect") {
                        saveSupabaseToken()
                    }
                    .disabled(supabaseToken.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty)
                    if supabaseConnected {
                        Button("Disconnect", role: .destructive) {
                            disconnectSupabase()
                        }
                    }
                    Spacer()
                    Text(supabaseMessage ?? (
                        supabaseConnected ? "Stored in Keychain" : "Not connected"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text("Create a personal access token in Supabase account settings. Headroom never returns it through the backend API.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            supabaseConnected = SupabaseTokenStore.exists()
        }
    }

    private func saveSupabaseToken() {
        let token = supabaseToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            try SupabaseTokenStore.save(token)
            supabaseToken = ""
            supabaseConnected = true
            supabaseMessage = "Refreshing projects…"
            notifySupabaseRefresh()
        } catch {
            supabaseMessage = error.localizedDescription
        }
    }

    private func disconnectSupabase() {
        SupabaseTokenStore.delete()
        supabaseConnected = false
        supabaseMessage = "Disconnected"
        notifySupabaseRefresh()
    }

    private func notifySupabaseRefresh() {
        guard let usageURL = URL(string: endpoint) else { return }
        let base = usageURL.lastPathComponent == "usage"
            ? usageURL.deletingLastPathComponent()
            : usageURL
        let url = base
            .appendingPathComponent("supabase")
            .appendingPathComponent("refresh")
        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: request)
            try? await Task.sleep(for: .seconds(1))
            await MainActor.run {
                supabaseMessage = supabaseConnected
                    ? "Connected — refresh Headroom" : "Disconnected"
            }
        }
    }
}

private enum SupabaseTokenStore {
    static let service = "com.mz.headroom.supabase"
    static let account = "access-token"

    static func exists() -> Bool {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func save(_ token: String) throws {
        delete()
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not save Supabase token."]
            )
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
