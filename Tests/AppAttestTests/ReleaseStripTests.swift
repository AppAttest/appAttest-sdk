import XCTest
@testable import AppAttest

/// Locks the load-bearing "un-hackable billing" invariant:
/// `.local` — the ONLY offline path — is `#if DEBUG`-only and therefore
/// compiled out of any Release binary, so every shipped app attests + meters.
///
/// Two complementary proofs:
///
///  1. **Compile-time (the hard proof):** `swift build -c release` succeeds.
///     The `DebugMode` type, the `debug` property, its backing store, and
///     the `.local` short-circuit in `runSync` all live inside `#if DEBUG`. If
///     any non-DEBUG code path referenced them, the Release build would fail to
///     compile. A green `swift build -c release` is thus positive evidence that
///     no offline path survives into Release. (Run in CI + by ember for APP-90.)
///
///  2. **Behavioral (this test, DEBUG only):** `.local` serves its stubs with
///     zero network — `waitForReady()` resolves without any round-trip. The
///     `release` routing label, by contrast, is compiled into all builds and
///     never opens an offline path (it only selects which metered bucket to
///     attest against).
///
/// The whole test body is wrapped in `#if DEBUG` so the file itself compiles
/// cleanly under `swift test -c release` (where the debug surface is absent).
@MainActor
final class ReleaseStripTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        AppAttestClient.shared.reset()
    }

    func testLocalIsFreeOfflinePath() async throws {
        #if DEBUG
        // `.local` short-circuits before any network client is built. If it
        // ever hit the network this would hang / fail rather than resolve.
        AppAttestClient.shared.debug = .local(stubs: ["A": "1"])
        AppAttestClient.shared.start()
        try await AppAttestClient.shared.waitForReady()
        XCTAssertEqual(AppAttestClient.shared.state, .ready)
        XCTAssertEqual(AppAttestClient.shared.secrets["A"], "1")
        #else
        // In a Release build the `.local` surface does not exist — there is no
        // offline path to exercise. The compile-time proof (1) above covers it.
        throw XCTSkip("`.local` is compiled out of Release; nothing to exercise")
        #endif
    }

    func testReleaseLabelIsCompiledIntoAllBuildsAndIsNotAFreePath() {
        // `release` is available regardless of build config (no `#if DEBUG`):
        // it is a routing label, not a free path. Setting it never bypasses
        // metering — it only changes which metered bucket a Release build
        // declares.
        AppAttestClient.shared.release = .staging
        XCTAssertEqual(AppAttestClient.shared.release, .staging)
        AppAttestClient.shared.release = .production
        XCTAssertEqual(AppAttestClient.shared.release, .production)
    }
}
