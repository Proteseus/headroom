import Foundation
import Security

/// Which half of the Keychain a query addresses.
///
/// Synchronizable items are a separate keyspace, not a flag on the same row: a
/// query that does not name `kSecAttrSynchronizable` defaults to `false` and
/// will never see a synced item, however exactly the service and account match.
/// That is the whole trap in this file. Reads and deletes therefore use `.any`,
/// which spans both — a Mac that stored a token before this shipped still has a
/// local-only copy, and it has to keep working.
enum KeychainScope {
    /// This Mac only.
    case local
    /// Travels to the user's other Macs through iCloud Keychain.
    case synced
    /// Both. The only correct scope for a read while local copies still exist.
    case any

    var attribute: Any {
        switch self {
        case .local: return kCFBooleanFalse as Any
        case .synced: return kCFBooleanTrue as Any
        case .any: return kSecAttrSynchronizableAny as Any
        }
    }
}

/// Generic-password storage. Every token the app holds goes through here —
/// nothing lands in UserDefaults, which is a plist any process can read.
enum KeychainPassword {
    static func exists(
        service: String, account: String, scope: KeychainScope = .local
    ) -> Bool {
        var query = baseQuery(service: service, account: account, scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(
        service: String, account: String, scope: KeychainScope = .local
    ) -> String? {
        var query = baseQuery(service: service, account: account, scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces whatever is stored under this service/account, in **both**
    /// halves of the keychain. Deleting `.any` first is what keeps a stale
    /// local copy from shadowing a freshly synced one on the next read.
    static func save(
        _ token: String, service: String, account: String,
        scope: KeychainScope = .local, failure: String
    ) throws {
        delete(service: service, account: account, scope: .any)
        try add(token, service: service, account: account,
                scope: scope, failure: failure)
    }

    static func delete(
        service: String, account: String, scope: KeychainScope = .local
    ) {
        SecItemDelete(
            baseQuery(service: service, account: account, scope: scope) as CFDictionary)
    }

    static func add(
        _ token: String, service: String, account: String,
        scope: KeychainScope, failure: String
    ) throws {
        var attributes = baseQuery(service: service, account: account, scope: scope)
        attributes[kSecValueData as String] = Data(token.utf8)
        // Not a `…ThisDeviceOnly` class: those are refused outright for a
        // synchronizable item, which is the point of the exercise.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(failure) (OSStatus \(status))",
                ]
            )
        }
    }

    private static func baseQuery(
        service: String, account: String, scope: KeychainScope
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: scope.attribute,
        ]
    }
}

/// One token store per service. The shape is identical, so it is described
/// once and instantiated four times rather than copied.
struct TokenStore: Sendable {
    let service: String
    let failureMessage: String
    var account = "access-token"
    /// Whether this token is the same person's answer on every Mac, and so
    /// follows them there through iCloud Keychain. A static PAT is; anything
    /// that names one machine, or that another process rotates, is not.
    var synced = false

    /// Reads span both halves regardless: a synced store may still be holding
    /// a local-only copy written before this shipped, or before `adoptSync()`
    /// got a chance to run.
    private var readScope: KeychainScope { synced ? .any : .local }

    func exists() -> Bool {
        KeychainPassword.exists(service: service, account: account, scope: readScope)
    }

    func read() -> String? {
        KeychainPassword.read(service: service, account: account, scope: readScope)
    }

    func save(_ token: String) throws {
        guard synced else {
            try KeychainPassword.save(
                token, service: service, account: account,
                scope: .local, failure: failureMessage)
            return
        }
        // Prefer iCloud Keychain so the PAT follows the user. An ad-hoc or
        // unsigned build has no Team ID, and iCloud Keychain being off also
        // refuses a synchronizable write — either way Connect must still
        // work on this Mac, so fall back to local. Same tolerance adoptSync
        // already has; save was the path that surfaced it as a hard error.
        do {
            try KeychainPassword.save(
                token, service: service, account: account,
                scope: .synced, failure: failureMessage)
        } catch {
            try KeychainPassword.save(
                token, service: service, account: account,
                scope: .local, failure: failureMessage)
        }
    }

    func delete() {
        KeychainPassword.delete(service: service, account: account, scope: .any)
    }

    /// Move a token stored before this feature into the synced keyspace.
    ///
    /// Ordered add-then-delete, never the reverse: the local copy is the only
    /// copy until the synced one is confirmed written, so a failure anywhere in
    /// here costs nothing. Deleting first and failing to add would lose a token
    /// the user pasted in months ago and cannot re-derive.
    func adoptSync() {
        guard synced else { return }
        if KeychainPassword.exists(service: service, account: account, scope: .synced) {
            // A synced copy is always the authoritative one: it is either this
            // Mac's, or the newer one that just arrived from the other. A local
            // copy left sitting beside it would win an `.any` read half the
            // time, which reads as a token that reverts at random.
            KeychainPassword.delete(service: service, account: account, scope: .local)
            return
        }
        guard let token = KeychainPassword.read(
            service: service, account: account, scope: .local)
        else { return }
        do {
            try KeychainPassword.add(
                token, service: service, account: account,
                scope: .synced, failure: failureMessage)
            KeychainPassword.delete(
                service: service, account: account, scope: .local)
        } catch {
            // Keep the local copy and try again next launch. iCloud Keychain
            // being switched off is one way to land here, and it is the user's
            // setting to make, not ours to report as a failure.
        }
    }

    static let supabase = TokenStore(
        service: "com.centaur-labs.headroom.supabase",
        failureMessage: "Could not save Supabase token.",
        synced: true
    )
    static let plausible = TokenStore(
        service: "com.centaur-labs.headroom.plausible",
        failureMessage: "Could not save Plausible token.",
        synced: true
    )
    static let github = TokenStore(
        service: "com.centaur-labs.headroom.github",
        failureMessage: "Could not save GitHub token.",
        synced: true
    )
    /// Only needed when the endpoint is not loopback — the host lets local
    /// callers through without one.
    ///
    /// Deliberately **not** synced. It authorizes reaching one Mac's host, and
    /// the phone pairs to one Mac; copying it to a second machine would hand
    /// out a credential for a server that is not there.
    static let host = TokenStore(
        service: "com.centaur-labs.headroom.host",
        failureMessage: "Could not save host token."
    )

    /// Every store whose token travels.
    static let syncedStores: [TokenStore] = [.supabase, .plausible, .github]

    /// Migrate pre-existing local tokens into the synced keyspace. Cheap, and
    /// a no-op once each has moved, so it can just run at every launch.
    static func adoptSyncForStoredTokens() {
        for store in syncedStores { store.adoptSync() }
    }
}
