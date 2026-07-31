import Foundation
import Security

enum MobileConnection {
    static let endpointKey = "mobileUsageEndpoint"
    static let configuredKey = "mobileConnectionConfigured"
    static let defaultEndpoint = "http://headroom.local:8737/usage"

    static var endpoint: String {
        UserDefaults.standard.string(forKey: endpointKey) ?? defaultEndpoint
    }

    static var isConfigured: Bool {
        UserDefaults.standard.bool(forKey: configuredKey)
    }

    /// Host from the saved endpoint — `.local` name, MagicDNS, or IP.
    static var hostLabel: String {
        URL(string: endpoint)?.host() ?? endpoint
    }

    /// One-line Mac identity for the Overview status tile.
    ///
    /// Prefer the Computer Name from `/usage` when it adds something the host
    /// does not already say; otherwise just the address you paired with.
    static func identityLabel(machineName: String?) -> String {
        let host = hostLabel
        guard let name = machineName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return host }
        let hostBase = host.split(separator: ".").first.map(String.init) ?? host
        if name.caseInsensitiveCompare(host) == .orderedSame
            || name.caseInsensitiveCompare(hostBase) == .orderedSame {
            return host
        }
        return "\(name) · \(host)"
    }

    static func normalize(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            value = "http://\(value)"
        }
        guard var components = URLComponents(string: value),
              components.host != nil else { return nil }
        if components.port == nil {
            components.port = 8737
        }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/usage"
        }
        return components.url?.absoluteString
    }
}

enum MobileTokenStore {
    private static let service = "com.centaur-labs.headroom.mobile"
    private static let account = "host-token"

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let status: OSStatus
        if read() == nil {
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        } else {
            status = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not save the mobile token."]
            )
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

struct MobileHeadroomClient: Sendable {
    enum ClientError: LocalizedError {
        case invalidEndpoint
        case unauthorized
        case response(Int)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                "The Mac address is invalid."
            case .unauthorized:
                "The Mac rejected the mobile token."
            case let .response(code):
                "The Headroom server returned HTTP \(code)."
            }
        }
    }

    let endpoint: String
    let token: String

    func fetchUsage() async throws -> UsageSnapshot {
        try await fetchUsagePayload().snapshot
    }

    /// The decoded snapshot plus the bytes it came from, so callers can archive
    /// the payload verbatim instead of re-encoding a decode-only model.
    func fetchUsagePayload() async throws -> (snapshot: UsageSnapshot, payload: Data) {
        let data = try await send(url: try usageURL)
        return (try JSONDecoder().decode(UsageSnapshot.self, from: data), data)
    }

    func requestRefresh() async throws {
        let base = try usageURL.deletingLastPathComponent()
        let url = base.appending(path: "sync/refresh")
        _ = try await send(
            url: url,
            method: "POST",
            body: Data(#"{}"#.utf8)
        )
    }

    /// Host answers /sync/refresh with 202 and works in the background — poll
    /// /health until sources look fresh instead of sleeping a guessed interval.
    func waitForRefresh(
        timeout: TimeInterval = 6,
        freshWithin: Int = 3
    ) async {
        let base = try? usageURL.deletingLastPathComponent()
        guard let healthURL = base?.appending(path: "health") else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            guard let data = try? await send(url: healthURL),
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let sources = object["sources"] as? [String: [String: Any]]
            else { continue }
            let settled = sources.values.allSatisfy { row in
                if row["enabled"] as? Bool == false { return true }
                guard let age = row["age_s"] as? Int else { return false }
                return age <= freshWithin
            }
            if settled { return }
        }
    }

    func acknowledgeAttention(_ fingerprint: String) async throws {
        let url = try usageURL.deletingLastPathComponent()
            .appending(path: "attention")
            .appending(path: "ack")
        let body = try JSONEncoder().encode(
            AttentionAcknowledgementRequest(fingerprint: fingerprint)
        )
        _ = try await send(url: url, method: "POST", body: body)
    }

    func fetchMobilePermissions() async throws -> MobilePermissions {
        let url = try usageURL.deletingLastPathComponent()
            .appending(path: "mobile")
            .appending(path: "permissions")
        let data = try await send(url: url)
        return try JSONDecoder()
            .decode(MobilePermissionsResponse.self, from: data)
            .permissions
    }

    func fetchAgentAttentionEvents() async throws -> [AgentAttentionEvent] {
        let url = try usageURL.deletingLastPathComponent()
            .appending(path: "attention")
            .appending(path: "events")
        let data = try await send(url: url)
        return try JSONDecoder()
            .decode(AgentAttentionEventsResponse.self, from: data)
            .events
    }

    func respond(
        to event: AgentAttentionEvent,
        action: AgentAttentionAction,
        idempotencyKey: String,
        text: String? = nil
    ) async throws -> AgentAttentionEvent {
        let url = try usageURL.deletingLastPathComponent()
            .appending(path: "attention")
            .appending(path: "events")
            .appending(path: event.id)
            .appending(path: "respond")
        let body = try JSONEncoder().encode(AgentAttentionResponseRequest(
            revision: event.revision,
            action: action.id,
            idempotencyKey: idempotencyKey,
            text: text
        ))
        let data = try await send(url: url, method: "POST", body: body)
        return try JSONDecoder()
            .decode(AgentAttentionResponse.self, from: data)
            .event
    }

    func taskSurface() async throws -> AgentTaskSurface {
        let url = try usageURL.deletingLastPathComponent()
            .appending(path: "agents")
            .appending(path: "tasks")
        return try JSONDecoder().decode(
            AgentTaskSurface.self, from: try await send(url: url, method: "GET"))
    }

    @discardableResult
    func startTask(
        provider: String, cwd: String, prompt: String
    ) async throws -> AgentStartTaskResponse {
        let url = try usageURL.deletingLastPathComponent()
            .appending(path: "agents")
            .appending(path: "tasks")
        let body = try JSONEncoder().encode(AgentStartTaskRequest(
            provider: provider, cwd: cwd, prompt: prompt))
        return try JSONDecoder().decode(
            AgentStartTaskResponse.self,
            from: try await send(url: url, method: "POST", body: body))
    }

    func setSources(_ enabled: [String: Bool]) async throws -> [String: Bool] {
        let url = try usageURL.deletingLastPathComponent()
            .appending(path: "sources")
        let body = try JSONEncoder().encode(SourceControlRequest(enabled: enabled))
        let data = try await send(url: url, method: "POST", body: body)
        return try JSONDecoder().decode(SourceControlResponse.self, from: data).enabled
    }

    func stopServer(pid: Int, port: Int) async throws {
        let url = try usageURL.deletingLastPathComponent()
            .appending(path: "local")
            .appending(path: "stop")
        let body = try JSONEncoder().encode(
            StopServerControlRequest(pid: pid, port: port)
        )
        _ = try await send(url: url, method: "POST", body: body)
    }

    private var usageURL: URL {
        get throws {
            guard let url = URL(string: endpoint) else {
                throw ClientError.invalidEndpoint
            }
            return url
        }
    }

    private func send(
        url: URL,
        method: String = "GET",
        body: Data? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(token, forHTTPHeaderField: "X-Headroom-Token")
        request.setValue("ios", forHTTPHeaderField: "X-Headroom-Client")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.response(0)
        }
        if http.statusCode == 401 { throw ClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.response(http.statusCode)
        }
        return data
    }
}

private struct SourceControlRequest: Encodable {
    let enabled: [String: Bool]
}

private struct SourceControlResponse: Decodable {
    let enabled: [String: Bool]
}

private struct StopServerControlRequest: Encodable {
    let pid: Int
    let port: Int
}

private struct AttentionAcknowledgementRequest: Encodable {
    let fingerprint: String
}
