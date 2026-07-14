import Foundation
#if canImport(Security)
import Security
#endif

/// Per-app static context the SDK reads from the running process.
///
/// **Fields:**
/// - `teamId` — Apple Team ID. Stamped into the attestToken claim.
/// - `bundleId` — iOS bundle identifier (e.g. `com.acme.notes`).
///   Identifies the project on the server side.
///
/// Apple's `{teamId}.{bundleId}` (the App ID) is the canonical iOS app
/// identifier. The SDK exposes **zero** developer-typed configuration —
/// no `APPATTEST_PROJECT_ID`, no ULIDs, no dashboard-copied identifiers.
/// See `Learnings/the-canonical-identifier-is-apples-not-yours.md`.
///
/// **Bucket** is not part of context — the served bucket (staging vs
/// production) is resolved by edge from (Apple's AAGUID ∩ the bucket the SDK
/// declares on `/v1/attest`). The AAGUID is a **build-time** property, not a
/// distribution-type one: a development-signed build resolves to the
/// development AAGUID → the staging bucket. A distribution build (TestFlight,
/// ad-hoc, Enterprise) that LACKS the
/// `com.apple.developer.devicecheck.appattest-environment=production`
/// entitlement ALSO attests with the development AAGUID → staging bucket. Only
/// a build carrying that production entitlement attests with the production
/// AAGUID and may reach the production bucket.
///
/// **Team ID detection.** No public API queries the Team ID at runtime, so
/// the SDK tries in order:
/// 1. `APPATTEST_TEAM_ID` in the app's Info.plist (explicit override).
/// 2. The keychain access-group probe — write-then-read a generic-password
///    item to recover the `<TEAMID>.<group>` access-group string.
struct AppContext: Sendable, Equatable {
    let teamId: String
    let bundleId: String

    static func resolve(bundle: Bundle = .main) throws -> AppContext {
        guard let bundleId = bundle.bundleIdentifier, !bundleId.isEmpty else {
            throw AppAttestError.attestationRejected(reason: "CFBundleIdentifier missing from Info.plist")
        }

        if let explicit = (bundle.object(forInfoDictionaryKey: "APPATTEST_TEAM_ID") as? String)?
                .trimmingCharacters(in: .whitespaces),
           !explicit.isEmpty {
            return AppContext(teamId: explicit, bundleId: bundleId)
        }

        if let detected = detectTeamIdViaKeychain() {
            return AppContext(teamId: detected, bundleId: bundleId)
        }

        throw AppAttestError.attestationRejected(reason: "Apple Team ID could not be detected. Set APPATTEST_TEAM_ID in Info.plist or add the keychain-sharing entitlement.")
    }

    // MARK: - Team ID detection via keychain access group

    private static func detectTeamIdViaKeychain() -> String? {
#if canImport(Security)
        // Throwaway Keychain probe: add a generic-password item, then read back
        // its access-group attribute (the system prefixes it with the app's Apple
        // Team ID). The account/service labels are arbitrary, live in the SDK's
        // own `dev.appattest.sdk` namespace, and are intentionally not host-shaped
        // so no label can be mistaken for an internal hostname.
        let account = "dev.appattest.sdk.tid-probe"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: "dev.appattest.sdk.probe",
            kSecReturnAttributes as String: true
        ]

        var result: AnyObject?
        var status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = Data([0])
            addQuery[kSecReturnAttributes as String] = true
            status = SecItemAdd(addQuery as CFDictionary, &result)
        }

        defer {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecAttrService as String: "dev.appattest.sdk.probe"
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }

        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let accessGroup = attrs[kSecAttrAccessGroup as String] as? String,
              let prefix = accessGroup.components(separatedBy: ".").first,
              !prefix.isEmpty else {
            return nil
        }
        return prefix
#else
        return nil
#endif
    }
}

#if targetEnvironment(simulator)
let isRunningOnSimulator = true
#else
let isRunningOnSimulator = false
#endif
