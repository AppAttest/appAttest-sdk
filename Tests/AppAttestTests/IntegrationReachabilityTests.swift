import XCTest
@testable import AppAttest

/// Reachability smoke against the SDK's hardcoded edge base URL.
///
/// The SDK has exactly one hardcoded URL — no switching plumbing.
/// This test verifies that whatever URL the source points at is
/// actually reachable.
///
/// Set `APPATTEST_SKIP_INTEGRATION=1` to skip on offline runs.
@MainActor
final class IntegrationReachabilityTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        if ProcessInfo.processInfo.environment["APPATTEST_SKIP_INTEGRATION"] == "1" {
            throw XCTSkip("APPATTEST_SKIP_INTEGRATION=1")
        }
        AppAttestClient.shared.reset()
    }

    /// `/healthz` is the liveness probe. If the SDK can reach this,
    /// the deployment the SDK is currently pointed at is up and
    /// the base URL routing is correct.
    func testHardcodedBaseURLHealthcheckReachable() async throws {
        let cfg = APIConfiguration.hardcoded
        let healthz = cfg.baseURL.appendingPathComponent("/healthz")
        var req = URLRequest(url: healthz)
        req.timeoutInterval = 10
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw XCTSkip("non-HTTP response from \(cfg.baseURL)")
            }
            if http.statusCode != 200 {
                throw XCTSkip("\(healthz.absoluteString) returned \(http.statusCode)")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            // The documented healthz success body is `{"ok":true}`.
            XCTAssertTrue(body.contains("\"ok\""), "unexpected /healthz body: \(body)")
        } catch {
            throw XCTSkip("\(cfg.baseURL) unreachable: \(error.localizedDescription)")
        }
    }
}
