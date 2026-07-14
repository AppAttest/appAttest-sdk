import Foundation
import CommonCrypto
#if canImport(DeviceCheck)
import DeviceCheck
#endif

/// Internal errors thrown by `AttestationEngine`. Distinguishes
/// recoverable "the keyId we hold no longer maps to a usable enclave
/// key" from genuinely terminal DeviceCheck failures, so
/// `AppAttestClient.runSync` can self-heal stale-credential cases
/// (app reinstalled, device restored from backup, TestFlight install
/// inheriting a dev-build's Keychain, iOS key eviction) by wiping
/// stored credentials + re-attesting transparently.
enum AttestationEngineError: Error {
    /// `generateAssertion` failed with a DeviceCheck error. Treated as
    /// recoverable: any DeviceCheck failure on `generateAssertion`
    /// means the stored keyId can't produce a valid assertion in the
    /// current context (Apple wiped the key, or the keyId was attested
    /// under a different AAGUID context than the current build is
    /// running under, etc.). One self-heal pass — wipe credentials,
    /// re-attest — recovers cleanly. If the SECOND attempt also fails,
    /// the engine surfaces `.operationFailed` and the public error is
    /// terminal `.attestationRejected`.
    case invalidEnclaveKey(op: String)

    /// `generateKey` / `attestKey` failed, OR `generateAssertion` failed
    /// on the post-self-heal retry. Terminal for this install per
    /// Apple's docs — the underlying cause is not a stored-credential
    /// staleness we can fix client-side.
    case operationFailed(op: String, underlying: Error)
}

extension AttestationEngineError {
    /// Translates to the public `AppAttestError` surface. Used by
    /// `AppAttestClient` when bubbling out after a self-heal attempt
    /// fails or when the error isn't recoverable.
    var publicError: AppAttestError {
        switch self {
        case .invalidEnclaveKey(let op):
            return .attestationRejected(reason: "\(op): stored enclave reference no longer valid")
        case .operationFailed(let op, _):
            return .attestationRejected(reason: "\(op): could not be completed")
        }
    }
}


/// Wraps `DCAppAttestService`. Handles key generation, attestation, and
/// per-call assertions.
///
/// **Wire convention.** Attestation `clientDataHash` is `SHA-256` over
/// the UTF-8 bytes of the challenge JWT returned by `POST /v1/attest/challenge`
/// — the SDK passes the entire JWT as `clientData`, matching the server's
/// verifier.
///
/// Assertion `clientDataHash` is `SHA-256` over the request body bytes the
/// SDK is about to send. Callers compute the hash themselves and pass it
/// in (the body may include the assertion field; see APIClient for the
/// exact canonicalization rule).
///
/// The simulator cannot produce attestations — on simulator, `isSupported`
/// returns false and callers must use `DebugMode.local(stubs:)`. There is
/// no `.sandbox` mode; real-device builds produce real App Attest
/// attestations and edge resolves the bucket from Apple's AAGUID (a
/// development-signed build resolves to the staging bucket).
struct AttestationEngine: Sendable {

    /// `true` when `DCAppAttestService.shared.isSupported` is true.
    static var isSupported: Bool {
#if canImport(DeviceCheck)
        return DCAppAttestService.shared.isSupported
#else
        return false
#endif
    }

    func generateKey() async throws -> String {
#if canImport(DeviceCheck)
        do {
            return try await DCAppAttestService.shared.generateKey()
        } catch {
            // `generateKey` creates a new enclave key — there is no
            // "stale stored reference" to recover from. Any failure
            // here is genuinely terminal for this attempt.
            throw AttestationEngineError.operationFailed(op: "generateKey", underlying: error)
        }
#else
        throw AttestationEngineError.operationFailed(
            op: "generateKey",
            underlying: NSError(domain: "dev.appattest.sdk", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "DeviceCheck unavailable on this platform"
            ])
        )
#endif
    }

    /// Returns base64-encoded attestation. The `clientDataHash` is the SHA-256
    /// of the challenge string's UTF-8 bytes — matching the server's verifier,
    /// which hashes the same UTF-8 bytes. The
    /// challenge is an opaque server-issued token, not a base64-encoded payload.
    func attestKey(keyId: String, challenge: String) async throws -> String {
#if canImport(DeviceCheck)
        let hash = sha256(Data(challenge.utf8))
        do {
            let attestation = try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: hash)
            return attestation.base64EncodedString()
        } catch {
            // `attestKey` references a key we just generated — same
            // logic as `generateKey`, no stale-state to self-heal.
            throw AttestationEngineError.operationFailed(op: "attestKey", underlying: error)
        }
#else
        throw AttestationEngineError.operationFailed(
            op: "attestKey",
            underlying: NSError(domain: "dev.appattest.sdk", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "DeviceCheck unavailable on this platform"
            ])
        )
#endif
    }

    /// Returns base64-encoded assertion (CBOR `{signature, authenticatorData}`).
    /// `clientDataHash` must be `SHA-256(request_body_bytes)` — see APIClient
    /// for the canonicalization rule that decides which bytes count.
    func generateAssertion(keyId: String, clientDataHash: Data) async throws -> String {
#if canImport(DeviceCheck)
        do {
            let assertion = try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
            return assertion.base64EncodedString()
        } catch {
            // `generateAssertion` references a stored keyId. ANY
            // DeviceCheck failure here — DCError.invalidKey (Apple
            // wiped the key), DCError.invalidInput (the stored id
            // doesn't match Apple's expected format anymore),
            // DCError.unknownSystemFailure, etc. — is symptomatic of
            // "this stored credential can't produce assertions in the
            // current context." That's exactly what self-heal recovers
            // from. AppAttestClient.runSync catches `invalidEnclaveKey`
            // and retries once with a fresh attestation; if the retry
            // also fails, the engine throws `operationFailed` on the
            // second attempt and the public error goes terminal.
            //
            // Non-DeviceCheck errors (e.g. URLSession timeouts during
            // Apple's internal calls) also bubble as `invalidEnclaveKey`
            // here because the safest action is the same: re-attest.
            // Worst case: one unnecessary fresh attestation. Best case:
            // we recover from a transient or stale-state failure the
            // user would otherwise have to reinstall to fix.
            throw AttestationEngineError.invalidEnclaveKey(op: "generateAssertion")
        }
#else
        throw AttestationEngineError.operationFailed(
            op: "generateAssertion",
            underlying: NSError(domain: "dev.appattest.sdk", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "DeviceCheck unavailable on this platform"
            ])
        )
#endif
    }

    // MARK: - SHA-256 helper (internal — APIClient also uses it)

    static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &digest)
        }
        return Data(digest)
    }

    private func sha256(_ data: Data) -> Data { Self.sha256(data) }
}
