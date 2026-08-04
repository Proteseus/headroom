import CryptoKit
import Foundation
import Security

/// The small, inspectable contract sent by the Mac when diagnostics are on.
///
/// This is intentionally an aggregate rather than an event stream. The app
/// owns consent, builds the payload from the already-decoded local snapshot,
/// and sends at most one batch per calendar week.
struct HeadroomTelemetryBatch: Codable, Equatable, Sendable {
    struct App: Codable, Equatable, Sendable {
        let version: String
        let build: String
        let hostVersion: String?
        let macOSMajor: Int
        let architecture: String

        enum CodingKeys: String, CodingKey {
            case version, build
            case hostVersion = "host_version"
            case macOSMajor = "macos_major"
            case architecture
        }
    }

    struct Providers: Codable, Equatable, Sendable {
        let enabled: [String]
        let used: [String]
        let healthy: [String]
    }

    let schema: Int
    let batchID: String
    /// HMAC-SHA256(install secret, period) as 64 lowercase hex chars. Changes
    /// every ISO week so the server can ignore duplicate installs without
    /// receiving a stable install id.
    let dedupeKey: String
    let period: String
    let app: App
    let providers: Providers
    /// Percent shares by normalized family, never raw model identifiers.
    let models: [String: [String: Int]]
    let features: [String: Bool]

    enum CodingKeys: String, CodingKey {
        case schema
        case batchID = "batch_id"
        case dedupeKey = "dedupe_key"
        case period, app, providers, models, features
    }
}

/// The public, privacy-thresholded Community Pulse contract. Counts are nil
/// when fewer than five Macs contributed, so the app cannot turn a tiny group
/// into an identifying fact.
struct HeadroomCommunityStats: Decodable, Sendable {
    struct Privacy: Decodable, Sendable {
        let minimumGroupSize: Int

        enum CodingKeys: String, CodingKey {
            case minimumGroupSize = "minimum_group_size"
        }
    }

    struct WeeklyActive: Decodable, Identifiable, Sendable {
        let period: String
        let count: Int?

        var id: String { period }
    }

    struct CountedItem: Decodable, Identifiable, Sendable {
        let name: String
        let count: Int

        var id: String { name }

        init(name: String, count: Int) {
            self.name = name
            self.count = count
        }
    }

    struct ModelShare: Decodable, Identifiable, Sendable {
        let name: String
        let share: Int

        var id: String { name }
    }

    struct Feature: Decodable, Identifiable, Sendable {
        let name: String
        let adoption: Int

        var id: String { name }
    }

    struct Services: Decodable, Sendable {
        let enabled: [CountedItem]
        let used: [CountedItem]
        let healthy: [CountedItem]
    }

    struct Latest: Decodable, Sendable {
        let period: String
        let reportingMacs: Int?
        let versions: [CountedItem]
        let architectures: [CountedItem]
        let macosMajors: [CountedItem]
        let countries: [CountedItem]
        let services: Services
        let modelShares: [ModelShare]
        let features: [Feature]

        enum CodingKeys: String, CodingKey {
            case period
            case reportingMacs = "reporting_macs"
            case versions
            case architectures
            case macosMajors = "macos_majors"
            case countries
            case services
            case modelShares = "model_shares"
            case features
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            period = try container.decode(String.self, forKey: .period)
            reportingMacs = try container.decodeIfPresent(Int.self, forKey: .reportingMacs)
            versions = try container.decodeIfPresent([CountedItem].self, forKey: .versions) ?? []
            architectures = try container.decodeIfPresent([CountedItem].self, forKey: .architectures) ?? []
            macosMajors = try container.decodeIfPresent([CountedItem].self, forKey: .macosMajors) ?? []
            countries = try container.decodeIfPresent([CountedItem].self, forKey: .countries) ?? []
            services = try container.decode(Services.self, forKey: .services)
            modelShares = try container.decodeIfPresent([ModelShare].self, forKey: .modelShares) ?? []
            features = try container.decodeIfPresent([Feature].self, forKey: .features) ?? []
        }
    }

    let schema: Int
    let generatedOn: String
    let privacy: Privacy
    let weeklyActiveMacs: [WeeklyActive]
    let latestRelease: LatestRelease?
    let latest: Latest?

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedOn = "generated_on"
        case privacy
        case weeklyActiveMacs = "weekly_active_macs"
        case latestRelease = "latest_release"
        case latest
    }

    struct LatestRelease: Decodable, Sendable {
        let version: String
        let published: String?
    }
}

enum HeadroomTelemetry {
    static let enabledKey = "telemetryEnabled"
    static let lastSubmittedPeriodKey = "telemetryLastSubmittedPeriod"
    static let endpointKey = "telemetryEndpoint"
    static let schemaVersion = 2
    static let defaultEndpoint = "https://headroom-telemetry.mz-508.workers.dev/v1/batches"
    static let sourceURL = URL(
        string: "https://github.com/michellzappa/headroom/tree/main/macos/Sources/Telemetry.swift"
    )!
    static let communityURL = URL(
        string: "https://headroom-telemetry.mz-508.workers.dev/community"
    )!
    static let communityAPIURL = URL(
        string: "https://headroom-telemetry.mz-508.workers.dev/v1/community"
    )!

    private static let installSecretService = "com.centaur-labs.headroom.telemetry"
    private static let installSecretAccount = "install-secret"
    private static let installSecretFileName = "install_secret"

    /// New installs and existing installs that predate this setting both start
    /// with the same visible choice: on. A user can turn it off at any time.
    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if !enabled {
            deletePendingBatch()
            // Keep the install secret. Deleting it would mint a new week key
            // and let someone re-count by toggling diagnostics off and on.
        }
        NotificationCenter.default.post(name: .headroomTelemetryChanged, object: nil)
    }

    static var endpoint: URL? {
        let raw = UserDefaults.standard.string(forKey: endpointKey)
            ?? defaultEndpoint
        guard let url = URL(string: raw),
              url.scheme == "https" || url.host == "127.0.0.1"
        else { return nil }
        return url
    }

    static var telemetryDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".headroom/telemetry")
    }

    static var pendingURL: URL {
        telemetryDirectory.appendingPathComponent("pending.json")
    }

    static var installSecretURL: URL {
        telemetryDirectory.appendingPathComponent(installSecretFileName)
    }

    static func loadPendingBatch() -> HeadroomTelemetryBatch? {
        guard enabled,
              let data = try? Data(contentsOf: pendingURL)
        else { return nil }
        return try? JSONDecoder().decode(HeadroomTelemetryBatch.self, from: data)
    }

    static func savePendingBatch(_ batch: HeadroomTelemetryBatch) {
        guard enabled else { return }
        let url = pendingURL
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(batch)
            let temporary = directory.appendingPathComponent(
                ".pending-\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(
                    url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            // Telemetry is strictly best effort. A full disk or a development
            // build without a home directory must not affect the dashboard.
        }
    }

    static func deletePendingBatch() {
        try? FileManager.default.removeItem(at: pendingURL)
    }

    static func currentPeriod(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year = calendar.component(.yearForWeekOfYear, from: date)
        let week = calendar.component(.weekOfYear, from: date)
        return String(format: "%04d-W%02d", year, week)
    }

    /// Opaque week key for server-side uniqueness. Not an install id: it
    /// rotates every ISO week and the underlying secret never leaves the Mac.
    static func weekDedupeKey(period: String) -> String {
        let secret = installSecret()
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(period.utf8),
            using: SymmetricKey(data: secret)
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// 32-byte secret, mirrored in local Keychain and `~/.headroom/telemetry`
    /// so Debug and Release builds on the same Mac share one week key. Not
    /// iCloud-synced: each Mac stays its own weekly reporter.
    static func installSecret() -> Data {
        if let keychain = readInstallSecretFromKeychain(),
           keychain.count == 32 {
            writeInstallSecretToFile(keychain)
            return keychain
        }
        if let file = readInstallSecretFromFile(), file.count == 32 {
            writeInstallSecretToKeychain(file)
            return file
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let secret = status == errSecSuccess
            ? Data(bytes)
            : Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        writeInstallSecretToKeychain(secret)
        writeInstallSecretToFile(secret)
        return secret
    }

    private static func readInstallSecretFromKeychain() -> Data? {
        guard let hex = KeychainPassword.read(
            service: installSecretService,
            account: installSecretAccount,
            scope: .local
        ) else { return nil }
        return dataFromHex(hex)
    }

    private static func writeInstallSecretToKeychain(_ secret: Data) {
        let hex = secret.map { String(format: "%02x", $0) }.joined()
        try? KeychainPassword.replace(
            hex,
            service: installSecretService,
            account: installSecretAccount,
            scope: .local,
            failure: "Could not save telemetry install secret."
        )
    }

    private static func readInstallSecretFromFile() -> Data? {
        guard let hex = try? String(
            contentsOf: installSecretURL, encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return dataFromHex(hex)
    }

    private static func writeInstallSecretToFile(_ secret: Data) {
        let directory = telemetryDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let hex = secret.map { String(format: "%02x", $0) }.joined()
            let temporary = directory.appendingPathComponent(
                ".secret-\(UUID().uuidString).tmp")
            try Data(hex.utf8).write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
            if FileManager.default.fileExists(atPath: installSecretURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    installSecretURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(
                    at: temporary, to: installSecretURL)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: installSecretURL.path
            )
        } catch {
            // Best effort — Keychain copy is enough for a signed build.
        }
    }

    private static func dataFromHex(_ hex: String) -> Data? {
        let cleaned = hex.lowercased()
        guard cleaned.count == 64, cleaned.allSatisfy(\.isHexDigit) else {
            return nil
        }
        var data = Data()
        data.reserveCapacity(32)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        return data
    }

    static func normalizedSourceID(_ id: String) -> String? {
        let base = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
        let allowed = Set([
            "claude", "codex", "cursor", "gemini", "zed", "copilot",
            "grok", "windsurf", "jetbrains", "openrouter", "ai-gateway",
            "vercel", "github", "git", "supabase", "plausible", "posthog",
            "sentry", "datadog", "axiom", "local",
        ])
        return allowed.contains(base) ? base : nil
    }

    static func normalizedModelFamily(_ model: String) -> String {
        let value = model.lowercased()
        if value.contains("sonnet") { return "sonnet" }
        if value.contains("opus") { return "opus" }
        if value.contains("haiku") { return "haiku" }
        if value.contains("gpt") { return "gpt" }
        if value.contains("codex") { return "codex" }
        if value.contains("gemini") { return "gemini" }
        if value.contains("cursor") { return "cursor" }
        return "other"
    }

    static func modelShares(_ history: UsageHistory?) -> [String: [String: Int]] {
        guard let rows = history?.topModels else { return [:] }
        var totals: [String: Double] = [:]
        for row in rows {
            guard let model = row.model, let tokens = row.tokens, tokens > 0 else {
                continue
            }
            let family = normalizedModelFamily(model)
            totals[family, default: 0] += tokens
        }
        let total = totals.values.reduce(0, +)
        guard total > 0 else { return [:] }
        let shares = totals.mapValues { Int(($0 / total * 100).rounded()) }
        let meaningful = shares
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(5)
        return ["claude": Dictionary(
            uniqueKeysWithValues: meaningful.map { ($0.key, $0.value) })]
    }
}

extension Notification.Name {
    static let headroomTelemetryChanged = Notification.Name(
        "headroomTelemetryChanged")
}

/// Builds and delivers the weekly batch. It intentionally lives in the app,
/// not the LaunchAgent: the background host never receives permission to make
/// outbound telemetry requests on its own.
@MainActor
final class TelemetryCoordinator {
    static let shared = TelemetryCoordinator()

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Builds the local aggregate without sending it. Settings uses this to
    /// show people exactly what the diagnostics toggle permits to leave the
    /// Mac.
    func preview() async -> HeadroomTelemetryBatch {
        await makeBatch(period: HeadroomTelemetry.currentPeriod())
    }

    private func run() async {
        while !Task.isCancelled {
            await submitIfDue()
            try? await Task.sleep(for: .seconds(6 * 60 * 60))
        }
    }

    private func submitIfDue() async {
        guard HeadroomTelemetry.enabled else { return }
        if let pending = HeadroomTelemetry.loadPendingBatch() {
            if await send(pending) {
                HeadroomTelemetry.deletePendingBatch()
            }
            return
        }

        let period = HeadroomTelemetry.currentPeriod()
        guard UserDefaults.standard.string(
            forKey: HeadroomTelemetry.lastSubmittedPeriodKey) != period
        else { return }

        let batch = await makeBatch(period: period)
        guard await send(batch) else {
            HeadroomTelemetry.savePendingBatch(batch)
            return
        }
        UserDefaults.standard.set(
            period,
            forKey: HeadroomTelemetry.lastSubmittedPeriodKey)
    }

    private func makeBatch(period: String) async -> HeadroomTelemetryBatch {
        let endpoint = HeadroomClient.currentEndpoint
        let isLocalHost = HeadroomClient.isLoopback(endpoint)
        let client = HeadroomClient()
        let snapshot = isLocalHost ? try? await client.fetchUsage() : nil
        let health = isLocalHost ? try? await client.health() : nil
        let agent = isLocalHost
            ? try? await client.fetchAgentGatewayConfiguration()
            : nil
        let multiMac = isLocalHost
            ? try? await client.fetchMultiMacConfiguration()
            : nil

        let sourceRows = snapshot?.sources ?? []
        let enabled: [String] = Set<String>(sourceRows.compactMap { row in
            guard row.enabled != false else { return nil }
            return HeadroomTelemetry.normalizedSourceID(row.id)
        }).sorted()
        let healthy: [String] = Set<String>(sourceRows.compactMap { row in
            guard row.enabled != false, row.ok == true else { return nil }
            return HeadroomTelemetry.normalizedSourceID(row.id)
        }).sorted()
        let used: [String] = Set<String>(
            (snapshot?.activityHistory?.availableSources ?? [])
                .compactMap(HeadroomTelemetry.normalizedSourceID)
        ).sorted()

        let appVersion = UpdateCheck.installedVersion
        let appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        return HeadroomTelemetryBatch(
            schema: HeadroomTelemetry.schemaVersion,
            batchID: UUID().uuidString.lowercased(),
            dedupeKey: HeadroomTelemetry.weekDedupeKey(period: period),
            period: period,
            app: .init(
                version: appVersion,
                build: appBuild,
                hostVersion: health?.version,
                macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                architecture: architecture
            ),
            providers: .init(
                enabled: enabled,
                used: used,
                healthy: healthy
            ),
            models: HeadroomTelemetry.modelShares(snapshot?.history),
            features: [
                "phone_paired": HostController.mobileToken != nil,
                "agent_gateway_enabled": agent?.enabled == true,
                "multi_mac_enabled": multiMac?.enabled == true,
            ]
        )
    }

    private func send(_ batch: HeadroomTelemetryBatch) async -> Bool {
        guard HeadroomTelemetry.enabled,
              let endpoint = HeadroomTelemetry.endpoint
        else { return false }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            String(HeadroomTelemetry.schemaVersion),
            forHTTPHeaderField: "X-Headroom-Telemetry-Schema"
        )
        guard let body = try? JSONEncoder().encode(batch) else { return false }
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
