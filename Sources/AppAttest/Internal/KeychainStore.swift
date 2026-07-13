import Foundation
#if canImport(Security)
import Security
#endif

/// Internal error thrown by `KeychainStore`. Converted to
/// `AppAttestError.network(underlying:)` at the public API boundary
/// (the public type collapses keychain failures into the catch-all
/// "couldn't talk to local storage / server reliably" bucket).
struct KeychainError: Error, CustomStringConvertible {
    let osStatus: Int32
    var description: String { "Keychain error \(osStatus)" }
}

/// The persistence contract `AppAttestClient` depends on. `KeychainStore`
/// is the sole production conformer; the protocol exists purely so a
/// `#if DEBUG` test can inject a failing double (e.g. a store that throws
/// `KeychainError` on every write) to drive the persistence-degraded signal
/// without a real Keychain. Not public — the seam is internal-only, per the
/// SDK public-API-vs-test-rig boundary rule.
protocol KeychainStoring: Sendable {
    func saveCredentials(_ credentials: AttestCredentials) throws
    func loadCredentials() throws -> AttestCredentials?
    func deleteCredentials() throws
    func saveSecrets(_ bundle: SecretBundle) throws
    func loadSecrets() throws -> SecretBundle?
    func deleteSecrets() throws
    func deleteAll() throws
}

/// Keychain-backed persistence for `AttestCredentials` and `SecretBundle`.
///
/// Access class is always `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` —
/// nothing AppAttest stores is synced across devices. Keys are scoped by
/// `(serviceIdentifier, environment-tag, accountName)` so dev and prod credentials
/// cannot collide in the same app.
///
/// Not an actor — each call opens and closes its own Security-framework query;
/// there's no shared mutable state to protect. All methods are `throws` and
/// `Sendable`-safe.
struct KeychainStore: KeychainStoring, Sendable {
    let serviceIdentifier: String
    let environmentTag: String // "prod" | "sandbox" | "local"

    private let credentialsAccount = "credentials"
    private let secretsAccount = "secrets"

    func saveCredentials(_ credentials: AttestCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        try upsert(account: credentialsAccount, data: data)
    }

    func loadCredentials() throws -> AttestCredentials? {
        guard let data = try load(account: credentialsAccount) else { return nil }
        return try JSONDecoder().decode(AttestCredentials.self, from: data)
    }

    func deleteCredentials() throws { try delete(account: credentialsAccount) }

    func saveSecrets(_ bundle: SecretBundle) throws {
        let data = try JSONEncoder().encode(bundle)
        try upsert(account: secretsAccount, data: data)
    }

    func loadSecrets() throws -> SecretBundle? {
        guard let data = try load(account: secretsAccount) else { return nil }
        return try JSONDecoder().decode(SecretBundle.self, from: data)
    }

    func deleteSecrets() throws { try delete(account: secretsAccount) }

    func deleteAll() throws {
        try deleteCredentials()
        try deleteSecrets()
    }

    // MARK: - Raw ops

    private var service: String { "\(serviceIdentifier).\(environmentTag)" }

    private func upsert(account: String, data: Data) throws {
#if canImport(Security)
        // Try update first; if not present, add.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = query
            for (k, v) in attrs { add[k] = v }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(osStatus: addStatus) }
            return
        }
        throw KeychainError(osStatus: updateStatus)
#else
        throw KeychainError(osStatus: -1)
#endif
    }

    private func load(account: String) throws -> Data? {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(osStatus: status)
        }
        return data
#else
        return nil
#endif
    }

    private func delete(account: String) throws {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(osStatus: status)
        }
#endif
    }
}
