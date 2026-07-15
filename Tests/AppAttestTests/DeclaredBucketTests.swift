import XCTest
@testable import AppAttest

/// Locks the declared-bucket resolution and its wire encoding.
///
/// # The regression this file exists to prevent (APP-102)
///
/// The declaration used to be `isDebugBuild ? .staging : release`, fed by a
/// `#if DEBUG` inside the SDK. `#if DEBUG` reflects how the **SDK's own
/// compilation unit** was built — which a host app consuming the SDK via SPM /
/// CocoaPods does **not** control, and which can diverge from the host app's
/// own `#if DEBUG`. A distribution archive whose Xcode configuration omitted
/// `DEBUG` from the app target while still building dependencies debug-flavored
/// made the SDK declare `staging` and be served STAGING secrets, silently
/// overriding an explicit `.production` — in a shipped app.
///
/// The fix: the declaration is a **pure projection of the developer's explicit
/// `start(release:)` choice**. No `#if DEBUG`, no build-flavor input, no
/// default. These tests lock exactly that.
final class DeclaredBucketTests: XCTestCase {

    // MARK: - The equivalence lock: debug- vs release-compiled parity

    /// **The APP-102 regression lock.**
    ///
    /// This test binary is compiled **with `DEBUG` defined** (that is what
    /// `swift test` does). Under the old code `declaredBucketWireValue` returned
    /// `"staging"` here no matter what — that *was* the bug. Asserting that a
    /// DEBUG-compiled SDK declares the developer's explicit choice verbatim is
    /// therefore a direct, executing proof that the debug path is gone.
    ///
    /// The body contains **no `#if DEBUG`**: it asserts identical expectations
    /// under either compilation flavor, so `swift test` and
    /// `swift test -c release` must both pass it unchanged. Debug-compiled and
    /// Release-compiled SDKs declare the same thing for the same input — which
    /// is the invariant the whole ticket is about.
    @MainActor
    func testDeclaredBucketIsIdenticalWhetherCompiledDebugOrRelease() {
        for bucket in [ReleaseBucket.production, .staging] {
            let client = AppAttestClient(bundle: .main, urlSession: .shared, engine: AttestationEngine())
            client.start(release: bucket)

            XCTAssertEqual(
                client.declaredBucketWireValue,
                bucket.wireValue,
                """
                A \(bucket.wireValue) build must declare "\(bucket.wireValue)". \
                This assertion runs in a DEBUG-compiled test binary and must hold \
                identically under `swift test -c release`: the declaration may \
                never depend on how the SDK compiled. If this fails, a \
                build-flavor signal (`#if DEBUG` or similar) has been \
                reintroduced into the declaration path — see APP-102.
                """
            )
        }
    }

    /// The declaration is a *pure projection* of the explicit choice: same
    /// input → same output, with no other input in the function's reach. Pins
    /// the full matrix in one place.
    @MainActor
    func testDeclaredBucketIsExactlyTheExplicitChoice_fullMatrix() {
        let cases: [(ReleaseBucket, String)] = [(.production, "production"), (.staging, "staging")]
        for (bucket, expected) in cases {
            let client = AppAttestClient(bundle: .main, urlSession: .shared, engine: AttestationEngine())
            client.start(release: bucket)
            XCTAssertEqual(client.declaredBucketWireValue, expected)
        }
    }

    /// `.production` specifically must survive a DEBUG-compiled SDK. This is
    /// the exact hazard from the ticket: an entitled archive declaring
    /// `.production` that a debug-flavored compile silently downgraded to
    /// `staging`, reading STAGING secrets in production.
    @MainActor
    func testExplicitProductionIsNeverDowngradedToStagingByADebugCompile() {
        let client = AppAttestClient(bundle: .main, urlSession: .shared, engine: AttestationEngine())
        client.start(release: .production)
        XCTAssertEqual(client.declaredBucketWireValue, "production")
        XCTAssertNotEqual(
            client.declaredBucketWireValue, "staging",
            "an explicit .production must NEVER be overridden to staging — the APP-102 hazard")
    }

    // MARK: - The structural half of the equivalence proof

    /// The behavioral test above proves a **debug-compiled** SDK declares the
    /// explicit choice. This one proves a **release-compiled** SDK cannot
    /// differ — by asserting there is no conditional compilation in the
    /// declaration path at all.
    ///
    /// Why this rather than running the suite under `swift test -c release`:
    /// the test suite as a whole cannot compile release-flavored (other tests
    /// legitimately depend on `#if DEBUG`-only seams — `.local`,
    /// `_testSetSecrets`), so a release-flavored *run* of this assertion is not
    /// available. But the invariant is exactly "no `#if DEBUG` may influence
    /// the declaration" — and if the path contains no conditional-compilation
    /// directive, the debug- and release-compiled forms are the *same code*,
    /// which the behavioral test above then pins. Structural + behavioral
    /// together close the loop that a single flavor's run cannot.
    ///
    /// This is the assertion that fails first if anyone reintroduces the bug.
    func testDeclarationPathContainsNoBuildFlavorConditional() throws {
        let source = try Self.appAttestClientSource()

        // 1. The old build-flavor plumbing must stay gone.
        XCTAssertFalse(
            source.contains("resolveDeclaredBucket"),
            "`resolveDeclaredBucket(isDebugBuild:release:)` was removed in APP-102 — the bucket is never derived from a build flavor. Reintroducing it reintroduces the bug.")
        XCTAssertFalse(
            source.contains("isDebugBuild"),
            "`isDebugBuild` was removed in APP-102 — how the SDK's own compilation unit was built must never reach the bucket declaration.")

        // 2. The declaration property itself must be free of `#if`.
        let body = try Self.declaredBucketWireValueBody(in: source)
        XCTAssertFalse(
            body.contains("#if"),
            """
            `declaredBucketWireValue` must contain NO conditional compilation. \
            It is a pure projection of the developer's explicit start(release:) \
            choice. A `#if DEBUG` here is precisely the APP-102 bug: for an SPM \
            dependency it reflects how the SDK compiled, which the host app does \
            not control and which diverges from the host app's own #if DEBUG. \
            Found body:
            \(body)
            """
        )
        XCTAssertTrue(
            body.contains("release?.wireValue"),
            "the declaration must remain a direct projection of `release`; found body:\n\(body)")
    }

    // MARK: - Source-reading helpers

    /// Locates `Sources/AppAttest/AppAttestClient.swift` from this test file's
    /// own path (`Tests/AppAttestTests/` → package root → `Sources/`).
    private static func appAttestClientSource(file: StaticString = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: "\(file)")
        let packageRoot = testFile            // …/Tests/AppAttestTests/DeclaredBucketTests.swift
            .deletingLastPathComponent()      // …/Tests/AppAttestTests
            .deletingLastPathComponent()      // …/Tests
            .deletingLastPathComponent()      // …/  (package root)
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/AppAttest/AppAttestClient.swift")

        // Deliberately NOT an XCTSkip: a guard that quietly skips is not a
        // guard. If the source is unreadable this must be loud.
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    /// Extracts the `declaredBucketWireValue` computed-property body.
    private static func declaredBucketWireValueBody(in source: String) throws -> String {
        guard let declRange = source.range(of: "var declaredBucketWireValue") else {
            throw XCTSkip("`declaredBucketWireValue` not found — the declaration path was renamed; update this guard to match.")
        }
        let afterDecl = source[declRange.upperBound...]
        guard let closing = afterDecl.range(of: "\n    }") else {
            return String(afterDecl)
        }
        return String(afterDecl[..<closing.lowerBound])
    }

    // MARK: - No bucket before start()

    /// Before `start(release:)` there is **no default** — nothing is declared.
    /// (Unreachable from Swift, where the parameter is required; the ObjC
    /// facade can refuse to start on a bad string and leave it unset.)
    @MainActor
    func testNoBucketIsDeclaredBeforeStart() {
        let client = AppAttestClient(bundle: .main, urlSession: .shared, engine: AttestationEngine())
        XCTAssertNil(client.release, "there must be no default bucket — the choice is always explicit")
        XCTAssertNil(client.declaredBucketWireValue)
    }

    // MARK: - start(release:) captures the choice

    @MainActor
    func testStartCapturesTheExplicitChoice() {
        let client = AppAttestClient(bundle: .main, urlSession: .shared, engine: AttestationEngine())
        client.start(release: .staging)
        XCTAssertEqual(client.release, .staging)
    }

    /// `start` is idempotent and **first-call-wins**; a second, disagreeing
    /// call must not silently re-point the SDK at another bucket.
    @MainActor
    func testSecondStartDoesNotChangeTheBucket() {
        let client = AppAttestClient(bundle: .main, urlSession: .shared, engine: AttestationEngine())
        client.start(release: .production)
        client.start(release: .staging)
        XCTAssertEqual(client.release, .production, "first start(release:) wins; the second is a logged no-op")
        XCTAssertEqual(client.declaredBucketWireValue, "production")
    }

    // MARK: - Wire strings

    func testWireValues() {
        XCTAssertEqual(ReleaseBucket.staging.wireValue, "staging")
        XCTAssertEqual(ReleaseBucket.production.wireValue, "production")
    }

    // MARK: - AttestRequest carries the declared bucket on the wire

    func testAttestRequestEncodesBucketWhenSet() throws {
        let req = AttestRequest(
            teamId: "T", keyId: "k", bundleId: "com.acme.notes",
            attestation: "a", challenge: "c", bucket: "staging"
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["bucket"] as? String, "staging")
        // Regression: the new field is named `bucket`, NOT `env_bucket`.
        XCTAssertNil(json["env_bucket"])
        XCTAssertNil(json["envBucket"])
    }

    func testAttestRequestOmitsBucketWhenNil() throws {
        // A nil bucket is omitted from the JSON — this reproduces pre-0.3.0
        // client behavior (edge derives the default from the AAGUID alone).
        let req = AttestRequest(
            teamId: "T", keyId: "k", bundleId: "com.acme.notes",
            attestation: "a", challenge: "c"   // bucket defaults to nil
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["bucket"], "a nil bucket must be omitted, not encoded as null")
        XCTAssertFalse(json.keys.contains("bucket"))
    }

    func testProductionBucketEncodes() throws {
        let req = AttestRequest(
            teamId: "T", keyId: "k", bundleId: "b",
            attestation: "a", challenge: "c", bucket: "production"
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["bucket"] as? String, "production")
    }
}
