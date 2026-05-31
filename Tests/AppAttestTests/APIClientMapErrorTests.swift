import XCTest
@testable import AppAttest

/// Tests the boundary enforcement on `APIClient.mapError(status:data:)`:
/// any `code` arriving in a 5xx or 429 response that is not in the documented
/// abstract vocabulary collapses to `temporarily_unavailable`. Defense-in-depth
/// so internal backend implementation detail (service names, region
/// identifiers, and the like) never reaches the customer's crash logs.
final class APIClientMapErrorTests: XCTestCase {

    private func client() -> APIClient {
        APIClient(configuration: .hardcoded)
    }

    private func envelope(_ code: String, _ message: String = "x") -> Data {
        let json = #"{"code":"\#(code)","message":"\#(message)"}"#
        return Data(json.utf8)
    }

    // MARK: - 5xx allow-list

    func test5xxPassesThroughAllowedCode_temporarilyUnavailable() {
        let err = client().mapError(status: 503, data: envelope("temporarily_unavailable"))
        XCTAssertEqual(err, .serviceUnavailable(reason: "(temporarily_unavailable)"))
    }

    func test5xxPassesThroughAllowedCode_retryAfterDelay() {
        let err = client().mapError(status: 503, data: envelope("retry_after_delay"))
        XCTAssertEqual(err, .serviceUnavailable(reason: "(retry_after_delay)"))
    }

    func test5xxPassesThroughAllowedCode_servicePaused() {
        let err = client().mapError(status: 503, data: envelope("service_paused"))
        XCTAssertEqual(err, .serviceUnavailable(reason: "(service_paused)"))
    }

    func test5xxCollapsesUnrecognizedCode() {
        // The whole point: if upstream regresses and leaks an internal stack
        // name, the SDK boundary scrubs it before it reaches the customer.
        for leak in ["worker_throttled", "store_failover", "task_timeout",
                     "region_outage", "store_conditional_check_failed",
                     "outbox_backlog", "internal_server_error"] {
            let err = client().mapError(status: 500, data: envelope(leak))
            XCTAssertEqual(err, .serviceUnavailable(reason: "(temporarily_unavailable)"),
                           "leak code '\(leak)' should collapse")
        }
    }

    func test5xxWithoutCodeUsesHttpFallback_thenCollapses() {
        // No envelope → code becomes "http_500" → not in allow-list → collapses.
        let err = client().mapError(status: 500, data: Data())
        XCTAssertEqual(err, .serviceUnavailable(reason: "(temporarily_unavailable)"))
    }

    // MARK: - 429 (rate-limited path)

    func test429PassesThroughRateLimited() {
        let err = client().mapError(status: 429, data: envelope("rate_limited"))
        XCTAssertEqual(err, .serviceUnavailable(reason: "(rate_limited)"))
    }

    func test429CollapsesUnrecognized() {
        let err = client().mapError(status: 429, data: envelope("throttled_internal"))
        XCTAssertEqual(err, .serviceUnavailable(reason: "(temporarily_unavailable)"))
    }

    // MARK: - Non-5xx paths unaffected

    func test402SubscriptionRequiredUnaffected() {
        let json = #"{"code":"subscription_required","subscribeUrl":"https://app.appattest.dev/billing","message":"x"}"#
        let err = client().mapError(status: 402, data: Data(json.utf8))
        if case .subscriptionRequired = err { /* ok */ } else {
            XCTFail("expected .subscriptionRequired, got \(err)")
        }
    }

    func test401AttestationRejectedUnaffected() {
        let err = client().mapError(status: 401, data: envelope("attestation_failed"))
        XCTAssertEqual(err, .attestationRejected(reason: "(attestation_failed)"))
    }

    // bundle_unavailable + unknown_app are special-cased into a developer
    // hint BEFORE the 5xx allow-list — verify that path still wins.
    func test5xxBundleUnavailableTakesDeveloperHintPath() {
        let err = client().mapError(status: 503, data: envelope("bundle_unavailable"))
        guard case .serviceUnavailable(let reason) = err else {
            XCTFail("expected .serviceUnavailable")
            return
        }
        XCTAssertTrue(reason.contains("not registered"),
                      "expected developer hint, got: \(reason)")
    }
}
