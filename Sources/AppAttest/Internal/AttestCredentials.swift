import Foundation

/// Stored device credentials. Persisted in Keychain; never logged.
///
/// The `token` is the edge-issued **attestToken** (HS256 JWT, 24h TTL,
/// `env` claim load-bearing). Edge refreshes opportunistically on every
/// `/v1/secrets/sync` response when the incoming token is past 50% of its
/// TTL — see `APIClient.refreshTokenIfPresent`.
///
/// The env bucket lives entirely in the token's signed `env` claim
/// (set by edge from Apple's AAGUID at `/v1/attest`). The SDK does NOT
/// track or cache the bucket client-side — if a stored credential's
/// signed env doesn't match the device's current AAGUID, edge rejects
/// on use and the self-heal path re-attests transparently.
struct AttestCredentials: Codable, Equatable, Sendable {
    /// The App Attest `keyId` (base64).
    let keyId: String
    /// Edge-issued attestToken JWT.
    var token: String
    /// Best-effort local expiry of `token`. Edge issues 24h TTLs; we don't
    /// parse the JWT exp claim, just record issued-at + 24h.
    var tokenExpiresAt: Date

    init(keyId: String, token: String, expiresIn: Int = 86_400, now: Date = Date()) {
        self.keyId = keyId
        self.token = token
        self.tokenExpiresAt = now.addingTimeInterval(TimeInterval(expiresIn))
    }

    /// True when the token is past its locally-tracked expiry.
    func isExpired(now: Date = Date()) -> Bool { now >= tokenExpiresAt }

    /// True when the token has less than `leeway` seconds of life left.
    /// Defaults to 5 minutes — generous enough that we re-attest before
    /// edge would have refused the token.
    func isExpiringSoon(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        now.addingTimeInterval(leeway) >= tokenExpiresAt
    }

    /// Rotate the attestToken. Called after a `/v1/secrets/sync` response
    /// that included a fresh `attest_token` field (refresh-on-response).
    /// Resets the 24h local expiry clock.
    mutating func updateToken(_ token: String, expiresIn: Int = 86_400, now: Date = Date()) {
        self.token = token
        self.tokenExpiresAt = now.addingTimeInterval(TimeInterval(expiresIn))
    }
}

/// Stored secret bundle. Persisted in Keychain; never logged.
struct SecretBundle: Codable, Equatable, Sendable {
    let fingerprint: String
    let secrets: [String: String]
    let syncedAt: Date
}
