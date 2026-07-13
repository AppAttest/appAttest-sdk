import XCTest
@testable import AppAttest

/// Wiring coverage for APP-82: "Keychain persistence failures are surfaced as a
/// non-fatal, observable signal instead of being swallowed by `try?`."
///
/// **Why these are wiring tests, not helper unit tests** (PRINCIPAL.md "test
/// the WIRING, not just the function"): the invariant is *"when a Keychain op
/// fails, the SDK reaches `.ready` anyway AND sets `persistenceDegraded` AND a
/// nil `loadSecrets` sends a nil fingerprint (which forces edge to bill a full
/// 200)."* That can only be locked by driving the real `start()` → `runSync`
/// → `runFingerprintSync` transition with a failing store and observing the
/// signal — never by calling `persisting(...)` directly.
///
/// **What is stubbed vs. real.** The SUT — the `persisting(...)` funnel, the
/// state machine, the fingerprint-from-loadSecrets logic, `recordPersistence-
/// Failure`, and the `onPersistenceIssue` sink — all run for real. Only three
/// *dependencies* are stubbed, none of which is the code under test:
///   - the Keychain (a `KeychainStoring` double that throws — the exact seam
///     the spec prescribes, since a real Keychain can't be made to fail on
///     demand under `swift test`),
///   - the Secure Enclave assertion (`_testSignBodyOverride` — the enclave is
///     unavailable on macOS/simulator), and
///   - the network (a `URLProtocol` returning a synthetic 200 — a real 200
///     requires a real device attestation, which is exactly what can't run
///     deviceless).
/// This mirrors the precedent in `ForegroundResyncTests` (network stubbed via
/// the SDK's own `.local` mode; state machine run for real).
@MainActor
final class PersistenceDegradedTests: XCTestCase {

    // MARK: - Test 1: credit-bleed path (failed loadSecrets → nil fingerprint → 200, degraded set)

    /// The headline invariant. A failing Keychain must NOT fail the sync: the
    /// SDK reaches `.ready` (secrets served from the wire), the persistence
    /// signal fires (`persistenceDegraded == true`, `.isCreditImpacting`), the
    /// sink streams it, AND — because `loadSecrets` failed — the sync sends a
    /// `nil` fingerprint, which is what forces edge to return a full 200 (one
    /// credit) rather than a 304. This is the exact credit-bleed the signal
    /// names.
    func testFailingKeychainSurfacesSignalAndNilFingerprintForces200() async throws {
        let session = Self.stubSession()
        let client = AppAttestClient(urlSession: session)
        client._testOverrideContext(teamId: "TEAMID1234", bundleId: "co.bault.appattest.test")

        // Failing store: reads of credentials succeed (so attestation is
        // bypassed and we reach the sync), every secrets op throws.
        client._testStoreOverride = TestKeychainStore(
            credential: AttestCredentials(keyId: "kid-1", token: "attest.token.jwt"),
            failLoadSecrets: true,
            failSaveSecrets: true
        )

        // Capture the exact wire body the SDK signs — this is the outgoing
        // SyncRequest, so we can assert `fingerprint == nil`.
        let capturedBody = Box<Data?>(nil)
        client._testSignBodyOverride = { body in
            capturedBody.set(body)
            return "AA=="   // canned assertion; the enclave can't sign on macOS
        }

        // Sink must catch the failure as it streams.
        let sink = Box<[PersistenceError]>([])
        client.onPersistenceIssue = { err in sink.mutate { $0.append(err) } }

        client.start()
        try await client.waitForReady()

        // The sync succeeded end-to-end despite the broken Keychain.
        XCTAssertEqual(client.state, .ready,
                       "a Keychain failure must NOT fail the sync — secrets are in memory")
        XCTAssertEqual(client.secrets["K"], "V",
                       "the synthetic 200 bundle should be served from memory")

        // The signal fired and is credit-impacting.
        XCTAssertTrue(client.persistenceDegraded,
                      "a failed loadSecrets/saveSecrets must set persistenceDegraded")
        XCTAssertEqual(client.lastPersistenceError?.isCreditImpacting, true,
                       "a secrets save/load failure is credit-impacting")
        XCTAssertFalse(sink.value.isEmpty,
                       "onPersistenceIssue must stream every failure as it happens")

        // The credit-bleed proof: a failed loadSecrets sent a nil fingerprint,
        // which forces edge to serve a full 200. Decode the captured wire body
        // and assert the fingerprint field is absent or null.
        let body = try XCTUnwrap(capturedBody.value, "the sync must have sent a body")
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let fingerprint = json?["fingerprint"]
        XCTAssertTrue(fingerprint == nil || fingerprint is NSNull,
                      "a failed loadSecrets must send NO fingerprint (nil), forcing edge to 200 — the credit-bleed the signal names")
    }

    // MARK: - Test 2: degraded clears on the next successful write; sink still saw the transient

    /// State semantics: `persistenceDegraded` means "a persistence op failed and
    /// no successful write has happened since." A transient failure (loadSecrets
    /// throws) sets it, but the very next successful write (the 200-path
    /// saveSecrets) clears it. The *properties* return to clean; the *sink*
    /// still caught the transient — that is the documented reason both surfaces
    /// exist.
    func testDegradedClearsAfterNextSuccessfulWriteButSinkCaughtIt() async throws {
        let session = Self.stubSession()
        let client = AppAttestClient(urlSession: session)
        client._testOverrideContext(teamId: "TEAMID1234", bundleId: "co.bault.appattest.test")

        // loadSecrets fails (transient), but saveSecrets succeeds — so the
        // 200-path write clears the flag the failed load set.
        client._testStoreOverride = TestKeychainStore(
            credential: AttestCredentials(keyId: "kid-1", token: "attest.token.jwt"),
            failLoadSecrets: true,
            failSaveSecrets: false
        )
        client._testSignBodyOverride = { _ in "AA==" }

        let sink = Box<[PersistenceError]>([])
        client.onPersistenceIssue = { err in sink.mutate { $0.append(err) } }

        client.start()
        try await client.waitForReady()

        XCTAssertEqual(client.state, .ready)
        XCTAssertFalse(client.persistenceDegraded,
                       "a successful saveSecrets must clear the flag a prior failed load set")
        XCTAssertNil(client.lastPersistenceError,
                     "clearing degraded also clears lastPersistenceError")
        XCTAssertFalse(sink.value.isEmpty,
                       "the sink must still have caught the transient load failure the properties cleared")
    }

    // MARK: - Test 3: PersistenceError value-type contract

    /// `isCreditImpacting` is true for save/load, false for delete; the
    /// description names only the artifact/operation/OSStatus — never a value.
    func testPersistenceErrorCreditImpactAndNoSecretLeak() {
        XCTAssertTrue(PersistenceError(artifact: .secrets, operation: .save, osStatus: -25299).isCreditImpacting)
        XCTAssertTrue(PersistenceError(artifact: .secrets, operation: .load, osStatus: -25300).isCreditImpacting)
        XCTAssertTrue(PersistenceError(artifact: .credentials, operation: .save, osStatus: -25299).isCreditImpacting)
        XCTAssertFalse(PersistenceError(artifact: .secrets, operation: .delete, osStatus: -25300).isCreditImpacting,
                       "a failed delete never costs a credit")
        XCTAssertFalse(PersistenceError(artifact: .credentials, operation: .delete, osStatus: -25300).isCreditImpacting)

        let desc = PersistenceError(artifact: .secrets, operation: .save, osStatus: -25299).description
        XCTAssertTrue(desc.contains("secrets") && desc.contains("save") && desc.contains("-25299"),
                      "description names artifact, operation, and OSStatus")
    }

    // MARK: - Fixtures

    /// A `URLSession` whose only protocol is a stub returning a synthetic 200
    /// `SyncResponse`. No real network is touched.
    private static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - Sendable capture box

/// Minimal lock-guarded holder so `@Sendable` closures (the sink, the sign
/// override) can capture mutable test state without concurrency warnings.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: T) { lock.lock(); defer { lock.unlock() }; _value = v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; f(&_value) }
}

// MARK: - Failing Keychain double (the seam the spec prescribes)

/// A `KeychainStoring` double that returns a preset credential (so attestation
/// is bypassed and the sync is reached) and throws `KeychainError` on the
/// configured secrets/credential/delete operations. Not the SUT — it stands in
/// for the real Keychain, which can't be made to fail on demand under
/// `swift test`.
final class TestKeychainStore: KeychainStoring, @unchecked Sendable {
    let credential: AttestCredentials?
    let failLoadSecrets: Bool
    let failSaveSecrets: Bool
    let failCredentialWrites: Bool
    let failDeletes: Bool
    let osStatus: Int32

    init(
        credential: AttestCredentials?,
        failLoadSecrets: Bool = false,
        failSaveSecrets: Bool = false,
        failCredentialWrites: Bool = false,
        failDeletes: Bool = false,
        osStatus: Int32 = -25299   // errSecDuplicateItem-ish; any non-success code
    ) {
        self.credential = credential
        self.failLoadSecrets = failLoadSecrets
        self.failSaveSecrets = failSaveSecrets
        self.failCredentialWrites = failCredentialWrites
        self.failDeletes = failDeletes
        self.osStatus = osStatus
    }

    func loadCredentials() throws -> AttestCredentials? { credential }

    func saveCredentials(_ credentials: AttestCredentials) throws {
        if failCredentialWrites { throw KeychainError(osStatus: osStatus) }
    }

    func loadSecrets() throws -> SecretBundle? {
        if failLoadSecrets { throw KeychainError(osStatus: osStatus) }
        return nil
    }

    func saveSecrets(_ bundle: SecretBundle) throws {
        if failSaveSecrets { throw KeychainError(osStatus: osStatus) }
    }

    func deleteCredentials() throws { if failDeletes { throw KeychainError(osStatus: osStatus) } }
    func deleteSecrets() throws { if failDeletes { throw KeychainError(osStatus: osStatus) } }
    func deleteAll() throws { if failDeletes { throw KeychainError(osStatus: osStatus) } }
}

// MARK: - Synthetic-200 network stub

/// Returns a canned 200 `SyncResponse` for any request. The reached path only
/// ever hits `POST /v1/secrets/sync` (attestation is bypassed by the preset
/// credential), so a single sync-shaped 200 covers it. No real host is called.
final class StubURLProtocol: URLProtocol {
    private static let body = Data("""
    {"secrets":[{"key":"K","value":"V"}],"fingerprint":"server-fingerprint","attest_token":null}
    """.utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://edge.appattest.dev/v1/secrets/sync")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
