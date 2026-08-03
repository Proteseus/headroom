import Foundation

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
    let period: String
    let app: App
    let providers: Providers
    /// Percent shares by normalized family, never raw model identifiers.
    let models: [String: [String: Int]]
    let features: [String: Bool]

    enum CodingKeys: String, CodingKey {
        case schema
        case batchID = "batch_id"
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
        let services: Services
        let modelShares: [ModelShare]
        let features: [Feature]

        enum CodingKeys: String, CodingKey {
            case period
            case reportingMacs = "reporting_macs"
            case versions, services
            case modelShares = "model_shares"
            case features
        }
    }

    let schema: Int
    let generatedOn: String
    let privacy: Privacy
    let weeklyActiveMacs: [WeeklyActive]
    let latest: Latest?

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedOn = "generated_on"
        case privacy
        case weeklyActiveMacs = "weekly_active_macs"
        case latest
    }
}

enum HeadroomTelemetry {
    static let enabledKey = "telemetryEnabled"
    static let lastSubmittedPeriodKey = "telemetryLastSubmittedPeriod"
    static let endpointKey = "telemetryEndpoint"
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

    /// New installs and existing installs that predate this setting both start
    /// with the same visible choice: on. A user can turn it off at any time.
    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? true
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if !enabled {
            deletePendingBatch()
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

    static var pendingURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".headroom/telemetry/pending.json")
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
            schema: 1,
            batchID: UUID().uuidString.lowercased(),
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
        request.setValue("1", forHTTPHeaderField: "X-Headroom-Telemetry-Schema")
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
