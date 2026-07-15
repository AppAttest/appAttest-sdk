import XCTest
@testable import AppAttest

/// Coverage for APP-83: "thread-safe `nonisolated` secret reads + lookup
/// disambiguation."
///
/// The invariants under test:
///   - the `nonisolated` reads (`currentSecret`, `currentSecrets`, `secret(_:)`,
///     `availableKeys`) are callable from OFF the main actor with **no `await`
///     hop** — proven at compile time by calling them inside a `Task.detached`
///     without `await`;
///   - the observable `secrets` mirror and the lock-protected snapshot behind
///     the `nonisolated` reads never drift — every write funnels through
///     `setSecrets`/`setState`, so `secrets == currentSecrets` after any sync;
///   - `secret(_:)` disambiguates the three states a bare `secrets[key]`
///     collapses into `nil`: `.notReady` (pre-sync), `.value` (present),
///     `.absent(available:)` (`.ready` but genuinely missing);
///   - the DEBUG unknown-key `.fault` fires once per key per synced key-set
///     (deduped), and a key-set change re-arms it.
///
/// **Wiring, not theater** (PRINCIPAL.md "test the WIRING, not just the
/// function"): the mirror-consistency + off-main tests drive the real
/// `start()` → `runSync` → `setSecrets` transition (network stubbed only via
/// the SDK's own `.local` mode or the reused synthetic-200 `StubURLProtocol`);
/// the SUT — the funnels, the snapshot, the lookup logic, the dedupe — runs for
/// real. The dedupe test asserts the ACTUAL emit count past the dedupe guard,
/// not that a helper was merely called.
@MainActor
final class ThreadSafeReadsTests: XCTestCase {

    // MARK: - Off-main read: no main-actor hop

    /// The Samaritan signing-closure case: an off-main reader gets the value
    /// with no `await`. The reads are invoked SYNCHRONOUSLY inside a
    /// `Task.detached` (a `nonisolated` context) — if any of them were
    /// `@MainActor`, this test would fail to COMPILE (you'd need `await`). So
    /// the fact it builds and returns the value is the proof there is no hop.
    func testNonisolatedReadsFromOffMainNeedNoAwait() async throws {
        let client = AppAttestClient()
        client._testSetSecrets(["BACKEND_KEY": "secret-123"])
        client._testSetState(.ready)

        let value = await Task.detached { client.currentSecret("BACKEND_KEY") }.value
        XCTAssertEqual(value, "secret-123", "off-main single-key read returns the value with no hop")

        let lookup = await Task.detached { client.secret("BACKEND_KEY") }.value
        XCTAssertEqual(lookup, .value("secret-123"), "off-main secret(_:) returns .value with no hop")

        let keys = await Task.detached { client.availableKeys }.value
        XCTAssertEqual(keys, ["BACKEND_KEY"], "off-main availableKeys with no hop")

        let snapshot = await Task.detached { client.currentSecrets }.value
        XCTAssertEqual(snapshot, ["BACKEND_KEY": "secret-123"], "off-main full snapshot with no hop")
    }

    /// The `nonisolated` static forwarders on `AppAttest` are likewise callable
    /// off the main actor with no `await` (they reach `AppAttestClient.shared`,
    /// which is a `nonisolated static let`). Compile-time proof again: the calls
    /// sit in a `Task.detached` with no `await` on the read.
    func testStaticForwardersAreNonisolated() async throws {
        AppAttestClient.shared._testSetSecrets(["FWD": "v"])
        AppAttestClient.shared._testSetState(.ready)
        defer {
            AppAttestClient.shared._testSetSecrets([:])
            AppAttestClient.shared._testSetState(.initializing)
        }
        let value = await Task.detached { AppAttest.currentSecret("FWD") }.value
        XCTAssertEqual(value, "v")
        let lookup = await Task.detached { AppAttest.secret("FWD") }.value
        XCTAssertEqual(lookup, .value("v"))
    }

    // MARK: - Mirror consistency (no drift between observable + snapshot)

    /// After a real sync, the observable `secrets` (main-actor mirror) and the
    /// `nonisolated` `currentSecrets` (lock snapshot) are identical, and
    /// `availableKeys` agrees. Drives the real `start()` → `runSync` →
    /// `setSecrets` transition via `.local` mode (which routes through the same
    /// funnel the network 200-path uses).
    func testMirrorConsistencyAfterLocalSync() async throws {
        let client = AppAttestClient()
        client.debug = .local(stubs: ["A": "1", "B": "2"])
        client.start(release: .production)
        try await client.waitForReady()

        XCTAssertEqual(client.state, .ready)
        XCTAssertEqual(client.secrets, client.currentSecrets,
                       "observable mirror and nonisolated snapshot must be identical after a sync")
        XCTAssertEqual(client.availableKeys, ["A", "B"])
        XCTAssertEqual(client.secret("A"), .value("1"))
        XCTAssertEqual(client.secret("B"), .value("2"))
    }

    /// Mirror consistency through the load-bearing 200-path (`setSecrets(new)`),
    /// driven with the reused synthetic-200 stub + preset-credential Keychain
    /// double from `PersistenceDegradedTests`. Locks that the wire 200 write
    /// updates BOTH the observable mirror and the nonisolated snapshot.
    func testMirrorConsistencyAfterWire200Sync() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let client = AppAttestClient(urlSession: URLSession(configuration: config))
        client._testOverrideContext(teamId: "TEAMID1234", bundleId: "co.bault.appattest.test")
        client._testStoreOverride = TestKeychainStore(
            credential: AttestCredentials(keyId: "kid-1", token: "attest.token.jwt")
        )
        client._testSignBodyOverride = { _ in "AA==" }

        client.start(release: .production)
        try await client.waitForReady()

        XCTAssertEqual(client.state, .ready)
        XCTAssertEqual(client.secrets["K"], "V")
        XCTAssertEqual(client.secrets, client.currentSecrets,
                       "the 200-path setSecrets must update both the mirror and the snapshot")
        XCTAssertEqual(client.currentSecret("K"), "V", "off-main read sees the synced value")
        XCTAssertEqual(client.availableKeys, ["K"])
    }

    // MARK: - secret(_:) across states

    /// `.notReady` before the first sync (both `.initializing` and `.syncing`),
    /// `.value` for a present key (which wins over readiness), `.absent` once
    /// `.ready` and the key is genuinely missing.
    func testSecretLookupAcrossStates() {
        let client = AppAttestClient()

        // .initializing (default) → a missing key is .notReady, not .absent.
        XCTAssertEqual(client.secret("X"), .notReady)

        // .syncing → still not ready.
        client._testSetState(.syncing)
        XCTAssertEqual(client.secret("X"), .notReady)

        // Present key returns .value even while NOT ready — value wins.
        client._testSetSecrets(["A": "1"])
        XCTAssertEqual(client.secret("A"), .value("1"),
                       "a present key is .value regardless of readiness")
        XCTAssertEqual(client.secret("X"), .notReady,
                       "a missing key while not-ready is still .notReady")

        // .ready → a genuinely missing key is .absent, listing what IS present.
        client._testSetState(.ready)
        XCTAssertEqual(client.secret("A"), .value("1"))
        XCTAssertEqual(client.secret("B"), .absent(available: ["A"]))
    }

    /// Empty synced set while `.ready`: every lookup is `.absent(available: [])`,
    /// and the value reads are empty/nil.
    func testEmptySetAbsentWhileReady() {
        let client = AppAttestClient()
        client._testSetSecrets([:])
        client._testSetState(.ready)

        XCTAssertEqual(client.secret("ANYTHING"), .absent(available: []))
        XCTAssertEqual(client.availableKeys, [])
        XCTAssertTrue(client.currentSecrets.isEmpty)
        XCTAssertNil(client.currentSecret("ANYTHING"))
    }

    /// `availableKeys` is sorted regardless of insertion order.
    func testAvailableKeysSorted() {
        let client = AppAttestClient()
        client._testSetSecrets(["zeta": "1", "alpha": "2", "mike": "3"])
        client._testSetState(.ready)
        XCTAssertEqual(client.availableKeys, ["alpha", "mike", "zeta"])
        XCTAssertEqual(client.secret("nope"), .absent(available: ["alpha", "mike", "zeta"]))
    }

    // MARK: - DEBUG unknown-key fault dedupe

    /// The unknown-key `.fault` fires exactly once per unknown key per synced
    /// key-set, and a key-set change (`setSecrets`) re-arms it. `.value` and
    /// `.notReady` never warn. Asserts the ACTUAL emit count (past the dedupe
    /// guard), so this locks real suppression, not a helper call.
    func testUnknownKeyFaultDedupe() {
        let client = AppAttestClient()
        client._testSetSecrets(["A": "1"])
        client._testSetState(.ready)
        XCTAssertEqual(client._testEmittedWarnCount, 0)

        _ = client.secret("TYPO")
        XCTAssertEqual(client._testEmittedWarnCount, 1, "first unknown-key lookup warns")

        _ = client.secret("TYPO")
        XCTAssertEqual(client._testEmittedWarnCount, 1,
                       "the same unknown key must be deduped within a key-set")

        _ = client.secret("OTHER")
        XCTAssertEqual(client._testEmittedWarnCount, 2, "a different unknown key warns")

        _ = client.secret("A")
        XCTAssertEqual(client._testEmittedWarnCount, 2, "a present key (.value) never warns")

        // .notReady never warns.
        client._testSetState(.syncing)
        _ = client.secret("STILL_MISSING")
        XCTAssertEqual(client._testEmittedWarnCount, 2, ".notReady never warns")

        // A key-set change resets the dedupe → TYPO can warn again.
        client._testSetState(.ready)
        client._testSetSecrets(["A": "1", "C": "3"])
        XCTAssertEqual(client._testEmittedWarnCount, 2, "setSecrets itself does not warn")
        _ = client.secret("TYPO")
        XCTAssertEqual(client._testEmittedWarnCount, 3,
                       "after a key-set change the dedupe re-arms and the key warns again")
    }
}
