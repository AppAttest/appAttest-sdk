import Foundation

/// All errors surfaced by the AppAttest SDK. Locked to five cases.
///
/// Errors usually reach you indirectly via ``AppAttestClient/state`` — pattern
/// match on the state and you get the typed error inside `.subscriptionRequired`,
/// `.creditsRequired`, or `.unavailable`. If you'd rather use exceptions,
/// ``AppAttest/waitForReady()`` throws.
///
/// - `subscriptionRequired(subscribeUrl:)` — server returned 402
///   `subscription_required`. The project's subscription is not active
///   (never subscribed, or suspended). Developer must subscribe at
///   `subscribeUrl`. Not retryable from the SDK.
///
/// - `creditsRequired(topupUrl:)` — server returned 402 `credits_required`.
///   Subscribed, but the current cycle's allowance is used up and the
///   prepaid balance is zero. Developer tops up at `topupUrl`, or waits
///   for next cycle. Not retryable from the SDK.
///
/// - `attestationRejected(reason:)` — the device's attestation could not be
///   verified. **This install can't continue.** Reinstalling the app
///   refreshes the device credentials and resolves it.
///
/// - `serviceUnavailable(reason:)` — AppAttest is temporarily unable to
///   serve this request. **Retryable.** The SDK keeps trying in the
///   background and cached secrets remain available.
///
/// - `network(underlying:)` — local network or device-side failure.
///   **Retryable.** Retried on next foreground or `retry()`; cached secrets
///   keep serving.
///
/// The 402 cases do not carry a separate `projectId` field —
/// the dashboard deep-link URL (`subscribeUrl` / `topupUrl`) already
/// encodes the project routing in its path.
public enum AppAttestError: Error, Sendable {

    /// 402 `subscription_required` — project not paid up.
    case subscriptionRequired(subscribeUrl: URL)

    /// 402 `credits_required` — project ran out of allowance + balance.
    case creditsRequired(topupUrl: URL)

    /// Apple or AppAttest rejected the attestation. Terminal for this install.
    case attestationRejected(reason: String)

    /// AppAttest is temporarily unable to serve. Retryable.
    /// The `reason` is drawn from an abstract documented vocabulary —
    /// `temporarily_unavailable`, `retry_after_delay`, `service_paused`,
    /// `rate_limited`. Anything else collapses to `temporarily_unavailable`
    /// at the SDK boundary so backend implementation details never leak.
    case serviceUnavailable(reason: String)

    /// Device-side network or decoding failure. Retryable.
    case network(underlying: Error)
}

extension AppAttestError {
    /// Stable string code. Bridges expose this as `error.code` so JS / Dart
    /// consumers can branch on the specific failure mode.
    public var code: String {
        switch self {
        case .subscriptionRequired: return "subscription_required"
        case .creditsRequired: return "credits_required"
        case .attestationRejected: return "attestation_rejected"
        case .serviceUnavailable: return "service_unavailable"
        case .network: return "network"
        }
    }

    /// Dashboard URL the developer should open. The edge server emits
    /// `subscribe_url` for `subscription_required` and `topup_url` for
    /// `credits_required`; this accessor returns whichever matches.
    public var actionUrl: URL? {
        switch self {
        case .subscriptionRequired(let u),
             .creditsRequired(let u):
            return u
        case .attestationRejected, .serviceUnavailable, .network:
            return nil
        }
    }
}

extension AppAttestError: CustomStringConvertible {
    /// Customer-facing description. Natural language, no infrastructure
    /// names, no server-side jargon, no retry-policy specifics. The
    /// detailed `reason` payload on `.attestationRejected` and
    /// `.serviceUnavailable` is included for developer triage but is
    /// itself scrubbed at the point of construction — see
    /// `APIClient.mapError`.
    public var description: String {
        switch self {
        case .subscriptionRequired:
            return "AppAttest: this project's subscription is not active. Subscribe in the AppAttest dashboard to continue."
        case .creditsRequired:
            return "AppAttest: this project has run out of available requests. Top up in the AppAttest dashboard to continue."
        case .attestationRejected(let r):
            return "AppAttest: attestation could not be verified. Reinstalling the app refreshes device credentials. \(r)"
        case .serviceUnavailable(let r):
            return "AppAttest: temporarily unavailable. The SDK will keep trying. \(r)"
        case .network(let e):
            return "AppAttest: a local network error occurred. \(e.localizedDescription)"
        }
    }
}

extension AppAttestError: Equatable {
    public static func == (lhs: AppAttestError, rhs: AppAttestError) -> Bool {
        switch (lhs, rhs) {
        case (.subscriptionRequired(let au), .subscriptionRequired(let bu)):
            return au == bu
        case (.creditsRequired(let au), .creditsRequired(let bu)):
            return au == bu
        case (.attestationRejected(let a), .attestationRejected(let b)):
            return a == b
        case (.serviceUnavailable(let a), .serviceUnavailable(let b)):
            return a == b
        case (.network(let a), .network(let b)):
            let na = a as NSError
            let nb = b as NSError
            return na.domain == nb.domain && na.code == nb.code
        default:
            return false
        }
    }
}
