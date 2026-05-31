import XCTest
@testable import AppAttest

/// `.local(stubs:)` runs fully offline — `start()` should populate `secrets`
/// from the inline dict without any network round-trip.
@MainActor
final class LocalModeTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        AppAttestClient.shared.reset()
    }

    func testLocalModeServesStubsAfterStart() async throws {
        let stubs = ["STRIPE_PUBLISHABLE_KEY": "pk_test_123", "RESEND_API_KEY": "re_test_abc"]
        AppAttestClient.shared.debugMode = .local(stubs: stubs)
        AppAttestClient.shared.start()

        try await AppAttestClient.shared.waitForReady()

        XCTAssertEqual(AppAttestClient.shared.secrets["STRIPE_PUBLISHABLE_KEY"], "pk_test_123")
        XCTAssertEqual(AppAttestClient.shared.secrets["RESEND_API_KEY"], "re_test_abc")
        XCTAssertEqual(AppAttestClient.shared.state, .ready)
    }

    func testMissingSecretReturnsNil() async throws {
        AppAttestClient.shared.debugMode = .local(stubs: ["A": "1"])
        AppAttestClient.shared.start()
        try await AppAttestClient.shared.waitForReady()
        XCTAssertNil(AppAttestClient.shared.secrets["DOES_NOT_EXIST"])
    }

    func testNamespaceAccessForwardsToShared() async throws {
        AppAttestClient.shared.debugMode = .local(stubs: ["A": "1"])
        AppAttest.start()
        try await AppAttest.waitForReady()
        XCTAssertEqual(AppAttest.secrets["A"], "1")
        XCTAssertEqual(AppAttest.state, .ready)
    }
}
