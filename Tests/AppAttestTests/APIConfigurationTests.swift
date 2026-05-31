import XCTest
@testable import AppAttest

final class APIConfigurationTests: XCTestCase {

    /// The SDK's hardcoded base URL is well-formed and HTTPS.
    ///
    /// The SDK has exactly one URL constant. This test doesn't assert
    /// a specific value — it just confirms the constant is well-formed
    /// and the path builder concatenates correctly.
    func testHardcodedBaseURLIsWellFormed() {
        let cfg = APIConfiguration.hardcoded
        XCTAssertEqual(cfg.baseURL.scheme, "https",
                       "base URL must be HTTPS — non-HTTPS in source is always a bug.")
        XCTAssertNotNil(cfg.baseURL.host)
        XCTAssertEqual(cfg.url(path: "/attest/challenge").path,
                       "/v1/attest/challenge")
        XCTAssertEqual(cfg.url(path: "/secrets/sync").path,
                       "/v1/secrets/sync")
        XCTAssertEqual(cfg.url(path: "/events").path,
                       "/v1/events")
    }
}
