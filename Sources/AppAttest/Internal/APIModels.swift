import Foundation

// Wire DTOs for `edge.appattest.dev`. Field names match the server's
// wire types exactly (snake_case). Wire format is JSON.
//
// **Canonical wire shape for the AppAttest API.**
//
// `project_id` is not present in any wire shape. The
// canonical iOS app identifier is Apple's App ID `{teamId}.{bundleId}` —
// both auto-derived on-device. After `/v1/attest` mints the attestToken,
// every subsequent call carries identity exclusively in the signed token
// claims (`team_id`, `bundle_id`, `env`); the request body itself is
// identity-free.
//
// The `/v1/attest` request carries an optional `bucket` field — the SDK's
// *declared desired bucket* (`"staging"` | `"production"`). Edge resolves the
// served bucket from (Apple's AAGUID allowed-set ∩ this declaration): a
// development-signed build (development AAGUID) may reach only `staging`; a
// production-signed build may reach `staging` or `production`. Edge stamps the
// resolved value into the attestToken's `env` claim and trusts the claim on
// subsequent calls. `/v1/secrets/sync` + `/v1/events` bodies carry NO bucket —
// it lives only in the signed claim. (Pre-0.3.0 SDKs omit `bucket`; edge then
// derives the safe default from the AAGUID alone.)

/// `POST /v1/attest/challenge` — no body. Server returns the challenge JWT.
struct ChallengeResponse: Decodable {
    let challenge: String
}

/// `POST /v1/attest` request. Edge resolves the env bucket from
/// (the AAGUID inside `authData` ∩ the declared `bucket` below), then
/// verifies the App Attest object (nonce + rpIdHash + AAGUID + counter +
/// credentialId) and mints a 24h `attestToken` whose claims include
/// `team_id`, `bundle_id`, `env` (the resolved bucket).
struct AttestRequest: Encodable {
    let teamId: String
    let keyId: String
    let bundleId: String
    /// Base64 of the CBOR App Attest attestation object.
    let attestation: String
    /// The challenge JWT returned by `POST /v1/attest/challenge`. Edge
    /// verifies the JWT signature; the entire JWT bytes are App Attest
    /// `clientData`.
    let challenge: String
    /// The SDK's declared desired bucket — `"staging"` or `"production"`.
    /// **Optional on the wire:** a `nil` value is omitted from the JSON, which
    /// reproduces pre-0.3.0 behavior (edge derives the safe default from the
    /// AAGUID alone). The 0.3.0+ SDK always populates it (see
    /// ``AppAttestClient/declaredBucketWireValue``). Edge rejects
    /// `(development AAGUID, "production")` with `403 bucket_not_permitted`.
    let bucket: String?

    init(
        teamId: String,
        keyId: String,
        bundleId: String,
        attestation: String,
        challenge: String,
        bucket: String? = nil
    ) {
        self.teamId = teamId
        self.keyId = keyId
        self.bundleId = bundleId
        self.attestation = attestation
        self.challenge = challenge
        self.bucket = bucket
    }

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case keyId = "key_id"
        case bundleId = "bundle_id"
        case attestation
        case challenge
        case bucket
    }
}

struct AttestResponse: Decodable {
    let attestToken: String

    enum CodingKeys: String, CodingKey {
        case attestToken = "attest_token"
    }
}

/// `POST /v1/secrets/sync` request body.
///
/// Identity (`team_id`, `bundle_id`, `env`) lives in the signed
/// attestToken claims, not on the wire. The per-call assertion
/// (base64-CBOR of `{signature, authenticatorData}`) is carried in
/// the `X-AppAttest-Assertion` HTTP header — **not** in this body —
/// so the signature can commit to the exact wire bytes.
struct SyncRequest: Encodable {
    let attestToken: String
    let fingerprint: String?

    enum CodingKeys: String, CodingKey {
        case attestToken = "attest_token"
        case fingerprint
    }
}

/// `200 OK` body. `attest_token` MAY be refreshed (edge refreshes when the
/// incoming token has elapsed at least 50% of its TTL). Always
/// optional client-side: missing means keep the current token.
struct SyncResponse: Decodable {
    let secrets: [SecretEntry]
    let fingerprint: String
    let attestToken: String?

    struct SecretEntry: Decodable, Sendable {
        let key: String
        let value: String
    }

    enum CodingKeys: String, CodingKey {
        case secrets
        case fingerprint
        case attestToken = "attest_token"
    }
}

/// `304 Not Modified` body — fingerprint matched. The optional refreshed
/// attestToken follows the same rule as the 200 path.
struct SyncNotModifiedResponse: Decodable {
    let fingerprint: String
    let attestToken: String?

    enum CodingKeys: String, CodingKey {
        case fingerprint
        case attestToken = "attest_token"
    }
}

/// `POST /v1/events` request body. Same auth shape as sync —
/// assertion in the `X-AppAttest-Assertion` header, identity in the
/// attestToken claims.
struct EventsRequest: Encodable {
    let attestToken: String
    let events: [JSONValue]

    enum CodingKeys: String, CodingKey {
        case attestToken = "attest_token"
        case events
    }
}

/// `POST /v1/events` 200 response.
struct EventsResponse: Decodable {
    let accepted: Int
}

/// Standard edge error envelope:
///   `{ "error": { "code", "message",
///                 "subscribe_url"? | "topup_url"? } }`
///
/// The 402 deep-link URLs carry any project routing in their path
/// (`https://app.appattest.dev/projects/{projectId}/subscribe`); no
/// separate `project_id` field on the wire.
/// Edge ships errors as a FLAT envelope. The SDK previously
/// expected a nested `{error: {...}}` shape; that schema mismatch
/// silently failed on every 4xx and fell through to `.network`,
/// rendering raw JSON to the user. Verification against real traffic
/// confirms the flat shape is canonical.
struct APIErrorEnvelope: Decodable {
    let code: String
    let message: String
    let subscribeUrl: String?
    let topupUrl: String?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case subscribeUrl = "subscribe_url"
        case topupUrl = "topup_url"
    }

}

/// Type-erased JSON value for `events` payloads. Lets consumers shovel
/// arbitrary JSON objects through without forcing them into a Swift type.
public enum JSONValue: Encodable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
