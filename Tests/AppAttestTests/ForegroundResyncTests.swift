import XCTest
@testable import AppAttest

/// Regression coverage for APP-78: "foreground re-sync fires once then dies."
///
/// The old `handleForeground()` debounced with
/// `if let task = syncTask, !task.isCancelled { return }`. `syncTask` is nil'd
/// only in `reset()`, and a Task that finished normally is never
/// `.isCancelled` — so after the launch sync completed, the guard stayed true
/// forever and every subsequent foreground returned early. Re-sync never fired
/// again. The fix debounces on the state machine (`.attesting`/`.syncing`)
/// instead.
///
/// These tests drive the real `handleForeground` → `spawnSyncTask` path via the
/// `#if DEBUG` `_testHandleForeground()` seam (the UIKit foreground
/// notification doesn't fire under `swift test` on macOS) and count real spawns
/// via `_syncSpawnCount`. The only stubbed boundary is the network, via the
/// SDK's own documented `.local(stubs:)` debug mode — the state machine and
/// debounce under test run for real.
@MainActor
final class ForegroundResyncTests: XCTestCase {

    /// After a completed launch sync (`state == .ready`), every foreground must
    /// spawn a fresh re-sync. On the buggy code the first foreground returned
    /// early (completed launch Task is non-nil, non-cancelled) and no re-sync
    /// ever fired — this asserts a spawn per foreground. Fails on old code
    /// (0 spawns), passes on the fix.
    func testForegroundReSyncFiresRepeatedlyAfterCompletedSync() async throws {
        let client = AppAttestClient()
        client.debug = .local(stubs: ["K": "V"])
        client.start(release: .production)
        try await client.waitForReady()
        XCTAssertEqual(client.state, .ready, "launch sync should complete to .ready")

        let baseline = client._syncSpawnCount

        // First foreground after the completed launch sync.
        client._testHandleForeground()
        XCTAssertEqual(client._syncSpawnCount, baseline + 1,
                       "first foreground after a completed sync must spawn a re-sync")
        await Task.yield()  // let the spawned local sync run back to .ready
        XCTAssertEqual(client.state, .ready)

        // Second foreground must ALSO spawn — the bug was it fired once then died.
        client._testHandleForeground()
        XCTAssertEqual(client._syncSpawnCount, baseline + 2,
                       "second foreground must also spawn — re-sync must not die after the first")
        await Task.yield()
    }

    /// The debounce still holds: while a sync is genuinely in flight
    /// (`.attesting` or `.syncing`), a foreground must NOT spawn a competing
    /// sync. Locks the new state-machine guard so the APP-78 fix doesn't
    /// over-fire.
    func testForegroundDoesNotSpawnWhileSyncInFlight() async throws {
        let client = AppAttestClient()
        client.debug = .local(stubs: ["K": "V"])

        client._testSetState(.syncing)
        let syncingBaseline = client._syncSpawnCount
        client._testHandleForeground()
        XCTAssertEqual(client._syncSpawnCount, syncingBaseline,
                       "foreground must NOT spawn while a sync is in flight (.syncing)")

        client._testSetState(.attesting)
        let attestingBaseline = client._syncSpawnCount
        client._testHandleForeground()
        XCTAssertEqual(client._syncSpawnCount, attestingBaseline,
                       "foreground must NOT spawn while attesting")
    }
}
