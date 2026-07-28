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
    private static let service = "com.mz.headroom.mobile"
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
                userInfo: [NSLocalizedDescriptionKey: "Could not save the host token."]
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
                "The Mac rejected the token."
            case let .response(code):
                "The Headroom server returned HTTP \(code)."
            }
        }
    }

    let endpoint: String
    let token: String

    func fetchUsage() async throws -> MobileUsageSnapshot {
        let data = try await send(url: try usageURL)
        return try JSONDecoder().decode(MobileUsageSnapshot.self, from: data)
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
