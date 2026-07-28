import Foundation

/// The one way this app talks to the host. Previously the popover and the
/// Settings pane each had their own client, each deriving base URLs and
/// decoding snapshots slightly differently — so they could disagree about
/// what the host said.
struct HeadroomClient: Sendable {
    enum ClientError: LocalizedError {
        case invalidEndpoint
        case unauthorized
        case badResponse(Int)
        case backend(String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                "The headroom endpoint is invalid."
            case .unauthorized:
                "The host rejected the token. Set it in Settings → Backend."
            case let .badResponse(code):
                "The backend returned HTTP \(code)."
            case let .backend(message):
                message
            }
        }
    }

    static let defaultEndpoint = "http://127.0.0.1:8737/usage"

    var endpoint: String
    var token: String?

    init(endpoint: String? = nil, token: String? = nil) {
        let resolved = endpoint
            ?? UserDefaults.standard.string(forKey: "usageEndpoint")
            ?? Self.defaultEndpoint
        self.endpoint = resolved
        // Host waves loopback through — don't touch Keychain on the hot path.
        // A wedged securityd (or unlock prompt) would otherwise freeze the
        // MainActor and the menu-bar icon never paints.
        if let token {
            self.token = token
        } else if Self.isLoopback(resolved) {
            self.token = nil
        } else {
            self.token = TokenStore.host.read()
        }
    }

    /// Same rule as Settings: token only matters off-machine.
    static func isLoopback(_ endpoint: String) -> Bool {
        guard let host = URL(string: endpoint)?.host()?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    static var displayEndpoint: String {
        let raw = UserDefaults.standard.string(forKey: "usageEndpoint")
            ?? defaultEndpoint
        guard let url = URL(string: raw), let host = url.host() else { return raw }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    private var usageURL: URL? { URL(string: endpoint) }

    /// Everything but /usage hangs off the same parent path.
    private func base() throws -> URL {
        guard let usageURL else { throw ClientError.invalidEndpoint }
        return usageURL.lastPathComponent == "usage"
            ? usageURL.deletingLastPathComponent()
            : usageURL
    }

    private func request(
        _ url: URL, method: String = "GET", body: Data? = nil,
        timeout: TimeInterval = 10
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Headroom-Token")
        }
        return request
    }

    @discardableResult
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse(0)
        }
        if http.statusCode == 401 { throw ClientError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badResponse(http.statusCode)
        }
        return data
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let usageURL else { throw ClientError.invalidEndpoint }
        let data = try await send(request(usageURL, timeout: 8))
        return try JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    func health() async throws -> HealthReport {
        let url = try base().appendingPathComponent("health")
        let data = try await send(request(url, timeout: 5))
        return try JSONDecoder().decode(HealthReport.self, from: data)
    }

    func fetchSetup() async throws -> SetupPayload {
        let url = try base().appendingPathComponent("setup")
        let data = try await send(request(url, timeout: 5))
        return try JSONDecoder().decode(SetupPayload.self, from: data)
    }

    func refresh(sources: [String]?) async throws {
        let url = try base()
            .appendingPathComponent("sync")
            .appendingPathComponent("refresh")
        let body: [String: Any] = (sources?.isEmpty == false)
            ? ["sources": sources as Any]
            : [:]
        try await send(request(
            url, method: "POST",
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 8))
    }

    func acknowledgeAttention(_ fingerprint: String) async throws {
        let url = try base()
            .appendingPathComponent("attention")
            .appendingPathComponent("ack")
        _ = try await send(request(
            url,
            method: "POST",
            body: try JSONSerialization.data(
                withJSONObject: ["fingerprint": fingerprint]),
            timeout: 8
        ))
    }

    /// Persist the Plausible primary window and force a fresh poll.
    @discardableResult
    func setPlausibleRange(_ range: String) async throws -> String {
        let url = try base()
            .appendingPathComponent("plausible")
            .appendingPathComponent("refresh")
        let data = try await send(request(
            url, method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["range": range]),
            timeout: 8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["range"] as? String) ?? range
    }

    /// The host answers a refresh with 202 and does the work in the background,
    /// so poll /health until the requested sources report a fresh age instead
    /// of sleeping a guessed interval and hoping.
    func waitForRefresh(
        sources: [String]?,
        timeout: TimeInterval = 6,
        freshWithin: Int = 3
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            guard let report = try? await health() else { continue }
            let wanted = sources ?? Array(report.sources.keys)
            let settled = wanted.allSatisfy { id in
                guard let row = report.sources[id] else { return true }
                guard row.enabled != false else { return true }
                guard let age = row.ageS else { return false }
                return age <= freshWithin
            }
            if settled { return }
        }
    }

    func setSources(_ enabled: [String: Bool]) async throws -> [String: Bool] {
        let url = try base().appendingPathComponent("sources")
        let data = try await send(request(
            url, method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["enabled": enabled]),
            timeout: 8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["enabled"] as? [String: Bool]) ?? enabled
    }

    func fetchMobilePermissions() async throws -> MobilePermissions {
        let url = try base()
            .appendingPathComponent("mobile")
            .appendingPathComponent("permissions")
        let data = try await send(request(url, timeout: 5))
        return try JSONDecoder()
            .decode(MobilePermissionsResponse.self, from: data)
            .permissions
    }

    func setMobilePermissions(
        _ permissions: MobilePermissions
    ) async throws -> MobilePermissions {
        let url = try base()
            .appendingPathComponent("mobile")
            .appendingPathComponent("permissions")
        let body = try JSONSerialization.data(
            withJSONObject: ["permissions": permissions.dictionary])
        let data = try await send(request(
            url, method: "POST", body: body, timeout: 5))
        return try JSONDecoder()
            .decode(MobilePermissionsResponse.self, from: data)
            .permissions
    }

    func stopServer(pid: Int, port: Int) async throws {
        let url = try base()
            .appendingPathComponent("local")
            .appendingPathComponent("stop")
        let body = try JSONEncoder().encode(StopServerRequest(pid: pid, port: port))
        var request = request(url, method: "POST", body: body)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse(0)
        }
        if http.statusCode == 401 { throw ClientError.unauthorized }
        let result = try? JSONDecoder().decode(StopServerResponse.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.backend(
                result?.error ?? "The backend returned HTTP \(http.statusCode).")
        }
        guard result?.ok == true else {
            throw ClientError.backend(result?.error ?? "Could not stop the server.")
        }
    }
}

struct HealthReport: Decodable, Sendable {
    var ok: Bool?
    var uptimeS: Int?
    var updated: String?
    var sources: [String: SourceHealth]
    /// Absent on hosts older than the version handshake — see HostVersion.
    var version: String?
    var build: String?

    enum CodingKeys: String, CodingKey {
        case ok, updated, sources, version, build
        case uptimeS = "uptime_s"
    }
}

struct SourceHealth: Decodable, Sendable {
    var ok: Bool?
    var stale: Bool?
    var enabled: Bool?
    var ageS: Int?
    var error: String?
    var detail: String?

    enum CodingKeys: String, CodingKey {
        case ok, stale, enabled, error, detail
        case ageS = "age_s"
    }
}

private struct StopServerRequest: Encodable {
    let pid: Int
    let port: Int
}

private struct StopServerResponse: Decodable {
    let ok: Bool
    let error: String?
}
