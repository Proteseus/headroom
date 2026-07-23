import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot.empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var stoppingServerID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefresh: Date?

    var onSnapshotChange: ((UsageSnapshot, Bool) -> Void)?

    private let client: UsageClient
    private var refreshLoop: Task<Void, Never>?

    init(client: UsageClient = UsageClient()) {
        self.client = client
    }

    deinit {
        refreshLoop?.cancel()
    }

    func start() {
        guard refreshLoop == nil else { return }
        refreshLoop = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            while !Task.isCancelled {
                let configured = UserDefaults.standard.integer(
                    forKey: "refreshInterval")
                let interval = configured > 0 ? configured : 60
                try? await Task.sleep(for: .seconds(max(15, interval)))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let value = try await client.fetch()
            snapshot = value
            lastRefresh = Date()
            errorMessage = nil
            onSnapshotChange?(value, true)
        } catch {
            errorMessage = error.localizedDescription
            onSnapshotChange?(snapshot, false)
        }
    }

    func stopServer(_ server: LocalServer) async {
        guard let pid = server.pid, let port = server.port,
              stoppingServerID == nil else { return }
        stoppingServerID = server.id
        defer { stoppingServerID = nil }

        do {
            try await client.stopServer(pid: pid, port: port)
            try? await Task.sleep(for: .milliseconds(300))
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct UsageClient: Sendable {
    enum ClientError: LocalizedError {
        case invalidEndpoint
        case badResponse(Int)
        case backend(String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                "The headroom endpoint is invalid."
            case let .badResponse(code):
                "The backend returned HTTP \(code)."
            case let .backend(message):
                message
            }
        }
    }

    private var endpoint: URL? {
        let configured = UserDefaults.standard.string(forKey: "usageEndpoint")
        return URL(string: configured ?? "http://127.0.0.1:8737/usage")
    }

    func fetch() async throws -> UsageSnapshot {
        guard let endpoint else { throw ClientError.invalidEndpoint }
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badResponse(http.statusCode)
        }
        return try JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    func stopServer(pid: Int, port: Int) async throws {
        guard let endpoint else { throw ClientError.invalidEndpoint }
        let base = endpoint.lastPathComponent == "usage"
            ? endpoint.deletingLastPathComponent()
            : endpoint
        let action = base
            .appendingPathComponent("local")
            .appendingPathComponent("stop")
        var request = URLRequest(url: action)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            StopServerRequest(pid: pid, port: port))
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse(0)
        }
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

private struct StopServerRequest: Encodable {
    let pid: Int
    let port: Int
}

private struct StopServerResponse: Decodable {
    let ok: Bool
    let error: String?
}
