import Foundation
import Security

/// Generic-password storage. Every token the app holds goes through here —
/// nothing lands in UserDefaults, which is a plist any process can read.
enum KeychainPassword {
    static func exists(service: String, account: String) -> Bool {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
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

/// One token store per service. The shape is identical, so it is described
/// once and instantiated three times rather than copied.
struct TokenStore: Sendable {
    let service: String
    let failureMessage: String
    var account = "access-token"

    func exists() -> Bool {
        KeychainPassword.exists(service: service, account: account)
    }

    func read() -> String? {
        KeychainPassword.read(service: service, account: account)
    }

    func save(_ token: String) throws {
        try KeychainPassword.save(
            token, service: service, account: account, failure: failureMessage)
    }

    func delete() {
        KeychainPassword.delete(service: service, account: account)
    }

    static let supabase = TokenStore(
        service: "com.centaur-labs.headroom.supabase",
        failureMessage: "Could not save Supabase token."
    )
    static let plausible = TokenStore(
        service: "com.centaur-labs.headroom.plausible",
        failureMessage: "Could not save Plausible token."
    )
    static let github = TokenStore(
        service: "com.centaur-labs.headroom.github",
        failureMessage: "Could not save GitHub token."
    )
    /// Only needed when the endpoint is not loopback — the host lets local
    /// callers through without one.
    static let host = TokenStore(
        service: "com.centaur-labs.headroom.host",
        failureMessage: "Could not save host token."
    )
}
