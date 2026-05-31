import Foundation
import os

/// Edge API client for the AppAttest wire protocol.
///
/// **Wire shape (identity in the signed token, bucket from AAGUID):**
/// `/v1/attest` carries `team_id` + `bundle_id` + the App Attest object;
/// edge derives the env bucket from the AAGUID in `authData`, then mints
/// an attestToken whose claims include `team_id`, `bundle_id`, `env`.
/// `/v1/secrets/sync` and `/v1/events` bodies carry ONLY `attest_token`
/// (+ `fingerprint` or `events`). No `env_bucket`, no identity fields.
///
/// **Assertion lives in a header.** Each `/v1/secrets/sync` and
/// `/v1/events` request is signed by Apple's `DCAppAttestService` over
/// `SHA-256(request_body_bytes)`. The signature (base64-CBOR
/// `{ signature, authenticatorData }`) goes in the
/// `X-AppAttest-Assertion` header. The wire body is exactly the bytes
/// the SDK hashed — one encode pass, no re-encode risk, no
/// canonicalization edge cases.
///
/// (Edge previously expected the assertion inside the body, which made
/// the signature commit to bytes containing itself — mathematically
/// impossible. Resolved in edge commit `beee043`.)
struct APIClient: Sendable {
    let configuration: APIConfiguration
    let urlSession: URLSession
    /// Optional developer-actionable context, used to enrich error
    /// messages with the running app's `{teamId}.{bundleId}` and a
    /// dashboard signup URL when edge returns a `bundle_unavailable`
    /// or `unknown_app` response — i.e., "this bundle isn't
    /// registered yet, go register it" rather than the generic
    /// "service unavailable" / "attestation rejected".
    let developerContext: DeveloperContext?

    struct DeveloperContext: Sendable {
        let teamId: String
        let bundleId: String
        /// URL the developer can open to register this bundle in the
        /// AppAttest dashboard. Hardcoded to the production dashboard;
        /// no Info.plist override (developers register their app
        /// against the same dashboard regardless of where the SDK
        /// happens to be pointing).
        let signupURL: URL = URL(string: "https://app.appattest.dev/signup")!
    }

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let jsonDecoder = JSONDecoder()

    /// HTTP header name carrying the App Attest assertion (base64-CBOR
    /// of `{ signature, authenticatorData }`).
    static let assertionHeader = "X-AppAttest-Assertion"

    /// Allow-list of `code` values that may be passed through verbatim
    /// into `AppAttestError.serviceUnavailable(reason:)`. Internal backend
    /// implementation detail (service names, region identifiers, and the
    /// like) must never appear in customer-facing error logs. Any code
    /// outside this set collapses to `temporarily_unavailable` in `mapError`.
    private static let allowedServiceUnavailableCodes: Set<String> = [
        "temporarily_unavailable",
        "retry_after_delay",
        "service_paused",
        "rate_limited"
    ]

    #if DEBUG
    /// Diagnostic logger for byte-level wire tracing. Only present
    /// in DEBUG builds; stripped from Release. Use to cross-check the
    /// SDK's signed bytes against edge's verifier when assertion
    /// verification fails.
    private static let wireLogger = Logger(subsystem: "dev.appattest.sdk", category: "wire-diag")

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
    #endif

    init(
        configuration: APIConfiguration,
        urlSession: URLSession = .shared,
        developerContext: DeveloperContext? = nil
    ) {
        self.configuration = configuration
        self.urlSession = urlSession
        self.developerContext = developerContext
    }

    // MARK: - Endpoints

    /// `POST /v1/attest/challenge` — no body. Returns the challenge JWT
    /// the SDK will pass to `DCAppAttestService.attestKey` as `clientData`.
    func requestChallenge() async throws -> String {
        var request = URLRequest(url: configuration.url(path: "/attest/challenge"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response: ChallengeResponse = try await send(request)
        #if DEBUG
        Self.wireLogger.error("fixture-challenge challenge=\(response.challenge, privacy: .public)")
        #endif
        return response.challenge
    }

    /// `POST /v1/attest` — register the device. Returns the attestToken JWT.
    /// No assertion required (this is the *first* call against this key).
    func attest(body: AttestRequest) async throws -> AttestResponse {
        var request = URLRequest(url: configuration.url(path: "/attest"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let wireBytes = try Self.jsonEncoder.encode(body)
        request.httpBody = wireBytes
        #if DEBUG
        Self.logAttestDiagnostic(wireBytes: wireBytes)
        #endif
        return try await send(request)
    }

    /// `POST /v1/secrets/sync`. The hot path.
    ///
    /// - Returns `.synced(SyncResponse)` on 200.
    /// - Returns `.notModified(SyncNotModifiedResponse)` on 304.
    /// - Throws `AppAttestError` on 4xx/5xx.
    ///
    /// `signBody` produces the base64-CBOR assertion over the exact wire
    /// body bytes. `AppAttestClient` is responsible for invoking
    /// `DCAppAttestService.generateAssertion`. Identity is read from the
    /// attestToken's signed claims — not carried in the body.
    func sync(
        attestToken: String,
        fingerprint: String?,
        signBody: (Data) async throws -> String
    ) async throws -> SyncResult {
        let body = SyncRequest(
            attestToken: attestToken,
            fingerprint: fingerprint
        )
        let wireBytes = try Self.jsonEncoder.encode(body)
        let assertion = try await signBody(wireBytes)

        var request = URLRequest(url: configuration.url(path: "/secrets/sync"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(assertion, forHTTPHeaderField: Self.assertionHeader)
        request.httpBody = wireBytes

        #if DEBUG
        Self.logWireDiagnostic(path: "/secrets/sync", wireBytes: wireBytes, assertionB64: assertion)
        #endif

        return try await sendSync(request)
    }

    /// `POST /v1/events`. Telemetry pass-through. Same auth flow as sync.
    func sendEvents(
        attestToken: String,
        events: [JSONValue],
        signBody: (Data) async throws -> String
    ) async throws -> EventsResponse {
        let body = EventsRequest(
            attestToken: attestToken,
            events: events
        )
        let wireBytes = try Self.jsonEncoder.encode(body)
        let assertion = try await signBody(wireBytes)

        var request = URLRequest(url: configuration.url(path: "/events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(assertion, forHTTPHeaderField: Self.assertionHeader)
        request.httpBody = wireBytes

        #if DEBUG
        Self.logWireDiagnostic(path: "/events", wireBytes: wireBytes, assertionB64: assertion)
        #endif

        return try await send(request)
    }

    #if DEBUG
    /// Logs the full `/v1/attest` request body in hex chunks. Used to
    /// capture the real-device attestation fixture for edge's CI corpus
    /// (gate item 6/9). The attestation body contains the Apple-issued
    /// CBOR attestation object which is non-reproducible without
    /// hardware — capturing once lets edge replay it forever.
    private static func logAttestDiagnostic(wireBytes: Data) {
        let hex = Self.hex(wireBytes)
        // OSLog truncates very long messages; chunk in 1024-char windows.
        let bodySha = Self.hex(AttestationEngine.sha256(wireBytes))
        // OSLog truncates messages around ~1024 ASCII chars per emit. Use
        // 512-char hex chunks to give comfortable headroom for the line
        // prefix + format overhead. Reassembly is index-ordered.
        let chunkSize = 512
        let totalChunks = (hex.count + chunkSize - 1) / chunkSize
        wireLogger.error("fixture-attest body.len=\(wireBytes.count, privacy: .public) body.sha256=\(bodySha, privacy: .public) total_chunks=\(totalChunks, privacy: .public)")
        var i = 0
        var chunk = 0
        while i < hex.count {
            let end = min(i + chunkSize, hex.count)
            let s = String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: end)])
            wireLogger.error("fixture-attest-chunk[\(chunk, privacy: .public)/\(totalChunks, privacy: .public)]=\(s, privacy: .public)")
            i = end
            chunk += 1
        }
    }

    /// Logs hex+length diagnostics for the bytes the SDK signed and
    /// shipped on the wire. Mirrors what edge logs in
    /// `verify_assertion` on failure so the two sides can be diffed
    /// row-by-row.
    private static func logWireDiagnostic(path: String, wireBytes: Data, assertionB64: String) {
        let bodySha = AttestationEngine.sha256(wireBytes)
        let firstSlice = wireBytes.prefix(64)
        let lastSlice = wireBytes.suffix(64)

        // Decode the CBOR assertion to surface authData + signature for
        // side-by-side comparison with edge's parsed values. The CBOR
        // schema is `{ "signature": bytes, "authenticatorData": bytes }`.
        var authDataHex = "<cbor decode failed>"
        var signatureHex = "<cbor decode failed>"
        if let cbor = Data(base64Encoded: assertionB64) {
            let parsed = Self.parseAssertionCBOR(cbor)
            if let ad = parsed.authData { authDataHex = hex(ad) }
            if let sig = parsed.signature { signatureHex = hex(sig) }
        }

        wireLogger.error(
            """
            wire-diag path=\(path, privacy: .public) \
            body.len=\(wireBytes.count, privacy: .public) \
            body.sha256=\(hex(bodySha), privacy: .public) \
            body.first_64_hex=\(hex(firstSlice), privacy: .public) \
            body.last_64_hex=\(hex(lastSlice), privacy: .public) \
            authData.hex=\(authDataHex, privacy: .public) \
            signature.hex=\(signatureHex, privacy: .public) \
            assertion.b64.len=\(assertionB64.count, privacy: .public) \
            assertion.b64=\(assertionB64, privacy: .public)
            """
        )
    }

    /// Minimal CBOR decoder for App Attest assertions. Returns the
    /// `signature` and `authenticatorData` fields as raw bytes. Only
    /// handles the exact shape Apple emits — string-keyed map of two
    /// byte-string entries. Used by `logWireDiagnostic`.
    private static func parseAssertionCBOR(_ data: Data) -> (signature: Data?, authData: Data?) {
        // CBOR for { "signature": ..., "authenticatorData": ... }:
        //   a2                       map of 2
        //   69 7369676e6174757265    text(9) "signature"
        //   58 <len> <bytes>         byte string
        //   71 6175...               text(17) "authenticatorData"
        //   58 <len> <bytes>         byte string
        var idx = 0
        let bytes = [UInt8](data)
        func u32(_ n: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<n { v = (v << 8) | UInt32(bytes[idx + i]) }
            idx += n
            return v
        }
        func decodeLen(_ initial: UInt8) -> Int? {
            let info = initial & 0x1f
            switch info {
            case 0...23: return Int(info)
            case 24:     guard idx < bytes.count else { return nil }; let v = bytes[idx]; idx += 1; return Int(v)
            case 25:     guard idx + 2 <= bytes.count else { return nil }; return Int(u32(2))
            case 26:     guard idx + 4 <= bytes.count else { return nil }; return Int(u32(4))
            default:     return nil
            }
        }

        guard bytes.count > 0 else { return (nil, nil) }
        let header = bytes[idx]; idx += 1
        guard header & 0xe0 == 0xa0 else { return (nil, nil) } // map
        guard let pairs = decodeLen(header) else { return (nil, nil) }

        var signature: Data? = nil
        var authData: Data? = nil
        for _ in 0..<pairs {
            // Text key.
            guard idx < bytes.count else { break }
            let keyHeader = bytes[idx]; idx += 1
            guard keyHeader & 0xe0 == 0x60 else { return (signature, authData) }
            guard let keyLen = decodeLen(keyHeader), idx + keyLen <= bytes.count else { return (signature, authData) }
            let keyData = Data(bytes[idx..<(idx + keyLen)])
            let key = String(data: keyData, encoding: .utf8) ?? ""
            idx += keyLen

            // Byte string value.
            guard idx < bytes.count else { break }
            let valHeader = bytes[idx]; idx += 1
            guard valHeader & 0xe0 == 0x40 else { return (signature, authData) }
            guard let valLen = decodeLen(valHeader), idx + valLen <= bytes.count else { return (signature, authData) }
            let valData = Data(bytes[idx..<(idx + valLen)])
            idx += valLen

            switch key {
            case "signature":         signature = valData
            case "authenticatorData": authData = valData
            default:                  break
            }
        }
        return (signature, authData)
    }
    #endif

    // MARK: - Transport

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AppAttestError.network(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppAttestError.network(underlying: NSError(
                domain: "dev.appattest.sdk",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "non-HTTP response"]
            ))
        }
        if (200...299).contains(http.statusCode) {
            do {
                return try Self.jsonDecoder.decode(Response.self, from: data)
            } catch {
                throw AppAttestError.network(underlying: error)
            }
        }
        throw mapError(status: http.statusCode, data: data)
    }

    /// Sync has a 200/304 distinction; 304 carries its own body shape.
    private func sendSync(_ request: URLRequest) async throws -> SyncResult {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AppAttestError.network(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppAttestError.network(underlying: NSError(
                domain: "dev.appattest.sdk",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "non-HTTP response"]
            ))
        }

        switch http.statusCode {
        case 200:
            do {
                return .synced(try Self.jsonDecoder.decode(SyncResponse.self, from: data))
            } catch {
                throw AppAttestError.network(underlying: error)
            }
        case 304:
            do {
                if data.isEmpty {
                    return .notModified(SyncNotModifiedResponse(fingerprint: "", attestToken: nil))
                }
                return .notModified(try Self.jsonDecoder.decode(SyncNotModifiedResponse.self, from: data))
            } catch {
                throw AppAttestError.network(underlying: error)
            }
        default:
            throw mapError(status: http.statusCode, data: data)
        }
    }

    /// Translate the AppAttest error envelope into a typed `AppAttestError`.
    ///
    /// 402 splits two ways:
    ///   - `subscription_required` → `.subscriptionRequired`
    ///   - `credits_required` → `.creditsRequired`
    ///
    /// 401 with attestation-failure codes → `.attestationRejected`.
    /// 5xx → `.serviceUnavailable` (with allow-listed reason).
    /// Everything else → `.network(underlying: ServerError(...))`.
    ///
    /// Internal for testability — exercised by APIClientMapErrorTests for
    /// the boundary-enforcement allow-list. Not part of the public API.
    func mapError(status: Int, data: Data) -> AppAttestError {
        let envelope = try? Self.jsonDecoder.decode(APIErrorEnvelope.self, from: data)
        let code = envelope?.code ?? "http_\(status)"
        let message = envelope?.message ?? (String(data: data, encoding: .utf8) ?? "")

        // 402 family. The deep-link URL is normally provided, but if
        // edge ever ships a malformed envelope without it we still
        // classify on `code` and surface a non-actionable typed state —
        // never raw JSON via `.network`. The dashboard root is a
        // best-effort fallback the host app can route the user to.
        if status == 402 {
            switch code {
            case "subscription_required":
                let url = envelope?.subscribeUrl.flatMap(URL.init(string:))
                    ?? URL(string: "https://app.appattest.dev/billing")!
                return .subscriptionRequired(subscribeUrl: url)
            case "credits_required":
                let url = envelope?.topupUrl.flatMap(URL.init(string:))
                    ?? URL(string: "https://app.appattest.dev/billing")!
                return .creditsRequired(topupUrl: url)
            default:
                return .network(underlying: ServerError(code: code, message: message, status: status))
            }
        }

        // Attestation-failure codes from edge (`/attest/*` + sync 401 paths).
        let attestationCodes: Set<String> = [
            "attestation_failed",
            "attestation_invalid",
            "attestation_verification_failed",
            "invalid_cert_chain",
            "nonce_mismatch",
            "rpid_mismatch",
            "signature_invalid",
            "counter_replay",
            "attest_token_invalid",
            "attest_token_expired",
            "attest_token_verify_failure",
            "device_inactive",
            "invalid_challenge"
        ]
        if attestationCodes.contains(code) {
            // Surface the documented public `code` only; never echo
            // the verbatim server message, which may contain
            // internal-only markers (e.g. fault-injection
            // breadcrumbs). Customer-facing description in
            // AppAttestError.description fills in the user-actionable
            // sentence; the code is for developer pattern-matching.
            return .attestationRejected(reason: "(\(code))")
        }

        // Developer-actionable: this bundle isn't registered with
        // AppAttest. The server emits `bundle_unavailable` (5xx) or
        // `unknown_app` (4xx) for the same root cause. Both indicate
        // "register your app in the dashboard," not a service outage.
        if code == "bundle_unavailable" || code == "unknown_app" {
            return .serviceUnavailable(reason: developerHint(for: code))
        }

        // Generic 5xx / 429. Don't echo the verbatim server message
        // back to the customer — it may contain internal-only
        // strings (debugging breadcrumbs, fault-injection markers,
        // etc.) that we never want shipped in a customer-facing
        // error description. The `code` is part of the SDK's
        // documented public vocabulary; pass that through.
        //
        // Boundary enforcement: collapse any code outside the allow-list
        // to `temporarily_unavailable`. Defense-in-depth so internal
        // backend implementation detail (service names, region
        // identifiers, and the like) never leaks into the customer's
        // crash logs even if the server regresses.
        if status >= 500 || status == 429 {
            let safe = Self.allowedServiceUnavailableCodes.contains(code) ? code : "temporarily_unavailable"
            return .serviceUnavailable(reason: "(\(safe))")
        }

        return .network(underlying: ServerError(code: code, message: message, status: status))
    }

    /// Build a developer-actionable error reason for the
    /// "bundle isn't registered" case. Names the exact
    /// `{teamId}.{bundleId}` and points at the dashboard signup URL
    /// so the developer can act on it without bisecting the SDK.
    ///
    /// **No infrastructure names, no HTTP status numbers, no
    /// verbatim server messages.** Only AppAttest-customer-facing
    /// concepts (team, bundle, dashboard) appear. The `code`
    /// itself is part of the SDK's documented public error
    /// vocabulary and is OK to include.
    private func developerHint(for code: String) -> String {
        guard let ctx = developerContext else {
            return "This bundle is not registered with AppAttest. Register it in the AppAttest dashboard to continue."
        }
        return """
        This bundle is not registered with AppAttest.
          team_id   = \(ctx.teamId)
          bundle_id = \(ctx.bundleId)
        Register the bundle in the AppAttest dashboard:
          \(ctx.signupURL.absoluteString)
        After registering, the SDK will pick it up on the next sync.
        """
    }
}

enum SyncResult {
    case synced(SyncResponse)
    case notModified(SyncNotModifiedResponse)

    /// The (possibly-refreshed) attestToken, or `nil` if no refresh.
    var refreshedToken: String? {
        switch self {
        case .synced(let r): return r.attestToken
        case .notModified(let r): return r.attestToken
        }
    }

    var fingerprint: String {
        switch self {
        case .synced(let r): return r.fingerprint
        case .notModified(let r): return r.fingerprint
        }
    }
}

/// Internal wrapper for non-modelled server errors. Preserved as the
/// underlying value of `.network(underlying:)` so callers can downcast in
/// diagnostics.
struct ServerError: LocalizedError, CustomStringConvertible {
    let code: String
    let message: String
    let status: Int

    var description: String { "\(status) [\(code)] — \(message)" }
    var errorDescription: String? { description }
}
