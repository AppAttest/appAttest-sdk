import XCTest
@testable import AppAttest

/// Locks the declared-bucket resolution and its wire encoding.
///
/// The resolver is a pure function so the FULL build×config matrix — including
/// the Release branch — is exercised here even though `swift test` compiles a
/// Debug binary. That is deliberate "test the wiring": the actual instance
/// property (``AppAttestClient/declaredBucketWireValue``) only differs from the
/// pure function by the compile-time `#if DEBUG` it feeds in, which the
/// in-Debug assertion below pins.
final class DeclaredBucketTests: XCTestCase {

    // MARK: - Pure resolution matrix

    func testDebugBuildAlwaysDeclaresStaging_regardlessOfRelease() {
        // Debug build is a development-environment build → staging, and the
        // `release` choice is ignored.
        XCTAssertEqual(
            AppAttestClient.resolveDeclaredBucket(isDebugBuild: true, release: .production),
            .staging,
            "a Debug build must declare staging even when release == .production")
        XCTAssertEqual(
            AppAttestClient.resolveDeclaredBucket(isDebugBuild: true, release: .staging),
            .staging)
    }

    func testReleaseBuildHonorsReleaseChoice() {
        // Release + default → production; Release + opt-in → staging.
        XCTAssertEqual(
            AppAttestClient.resolveDeclaredBucket(isDebugBuild: false, release: .production),
            .production,
            "Release default must declare production")
        XCTAssertEqual(
            AppAttestClient.resolveDeclaredBucket(isDebugBuild: false, release: .staging),
            .staging,
            "Release + .staging must declare staging")
    }

    // MARK: - Wire strings

    func testWireValues() {
        XCTAssertEqual(ReleaseBucket.staging.wireValue, "staging")
        XCTAssertEqual(ReleaseBucket.production.wireValue, "production")
    }

    // MARK: - The instance property under the real (Debug) compile

    @MainActor
    func testInstanceDeclaredBucketIsStagingInThisDebugTestBinary() {
        // This test target is compiled with DEBUG defined, so the SDK's
        // build-keyed property must resolve to staging here — the same value a
        // real debug app declares — no matter what `release` is set to.
        let client = AppAttestClient.shared
        client.release = .production
        XCTAssertEqual(client.declaredBucketWireValue, "staging")
        client.release = .staging
        XCTAssertEqual(client.declaredBucketWireValue, "staging")
        client.release = .production   // restore default for other tests
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
