import Foundation
import Observation
import CommonCrypto
import os
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Security)
import Security
#endif

/// Main-actor, observable storage for the AppAttest SDK. Holds the
/// secret dictionary and the lifecycle ``state``. SwiftUI re-renders any
/// view that reads `secrets` or `state` when either changes.
///
/// Use ``AppAttestClient/shared`` directly, or inject via SwiftUI's
/// `.environment(AppAttestClient.shared)` for testability. The static
/// ``AppAttest`` namespace forwards to ``AppAttestClient/shared``.
///
/// # Lifecycle
///
/// ```swift
/// @main
/// struct MyApp: App {
///     init() { AppAttest.start() }
///
///     var body: some Scene {
///         WindowGroup { ContentView() }
///     }
/// }
/// ```
///
/// `start()` is synchronous and idempotent. It hydrates `secrets` from
/// the Keychain (cold-start fast path), registers a foreground observer,
/// and spawns the background sync `Task`. Subsequent calls are no-ops.
///
/// # Reading secrets
///
/// ```swift
/// if let key = AppAttest.secrets["OPENAI_API_KEY"] {
///     // use key
/// }
/// ```
///
/// `secrets[key]` is a synchronous `String?` lookup. Pre-sync it returns
/// `nil`. After ``waitForReady()`` succeeds (or the cold-start fast path
/// fires from the Keychain), every key from the synced set is present.
///
/// `secrets` is the *reactive* read: `@MainActor` and observable, so a
/// SwiftUI view that reads it re-renders when the sync resolves. For
/// *imperative* or off-main code (a signing / networking closure), read
/// ``currentSecret(_:)`` / ``currentSecrets`` instead — they are
/// `nonisolated` (no `await` hop) but not observation-tracked. When you
/// need to tell "not synced yet" apart from "typo / never registered",
/// use ``secret(_:)``, which returns a ``SecretLookup`` rather than
/// collapsing both to `nil`.
///
/// # State
///
/// ```swift
/// switch AppAttestClient.shared.state {
/// case .ready:                       MainView()
/// case .subscriptionRequired(let e): SubscribeNoticeView(error: e)
/// case .creditsRequired(let e):      TopUpNoticeView(error: e)
/// case .unavailable(let e):          RetryView(error: e) { AppAttest.retry() }
/// case .initializing, .attesting, .syncing: SplashView()
/// }
/// ```
@Observable
@MainActor
public final class AppAttestClient {

    /// Shared singleton. The static ``AppAttest`` namespace forwards here.
    /// `nonisolated` so the `nonisolated` static read forwarders
    /// (``AppAttest/secret(_:)``, ``AppAttest/currentSecret(_:)``, …) can reach
    /// it off the main actor with no `await`. Safe: the type is `Sendable` (a
    /// `@MainActor` class) and its `init` is `nonisolated`.
    public nonisolated static let shared = AppAttestClient()

    // MARK: - Public observable state

    /// Lifecycle state. Observed via SwiftUI's `@Observable` tracking.
    public private(set) var state: State = .initializing

    /// Synced secrets, keyed by name. Lookup is synchronous.
    public private(set) var secrets: [String: String] = [:]

    /// True when the SDK could not read or write its Keychain cache on the most
    /// recent attempt. **Non-fatal** — the current session is fully functional
    /// (secrets are in memory), but the cache is degraded, so the SDK will
    /// re-attest / re-sync on next launch (a re-sync consumes one credit).
    /// Clears automatically after the next successful cache write. Observable —
    /// SwiftUI views that read it re-render on change. Surface it in
    /// developer / staff builds; investigate the Keychain entitlement or device
    /// state (e.g. a locked device before first unlock).
    public private(set) var persistenceDegraded: Bool = false

    /// The most recent persistence failure, or `nil` if the last cache write
    /// succeeded. Inspect `.isCreditImpacting` for severity. Observable.
    public private(set) var lastPersistenceError: PersistenceError?

    /// Optional sink, fired on the main actor for every persistence failure as
    /// it happens. Use it to forward to your own logging / telemetry (OSLog,
    /// Sentry, …). The two properties above give the *current* state; this
    /// callback gives the *stream* (it catches transient failures a later
    /// success would clear from the properties). Set before `start()`.
    /// `@ObservationIgnored` — assigning a sink is not a view-updating change.
    @ObservationIgnored
    public var onPersistenceIssue: (@MainActor @Sendable (PersistenceError) -> Void)?

    #if DEBUG
    /// Runtime mode. `nil` means production (default). Set to
    /// ``DebugMode/local(stubs:)`` to bypass the network entirely — useful
    /// for SwiftUI previews + simulator development where App Attest is
    /// unavailable. Debug-only; the case, the property, the backing store,
    /// and the type itself are `#if DEBUG`-stripped in Release builds so
    /// none of this can leak into production.
    public var debugMode: DebugMode? {
        get { _debugMode }
        set { _debugMode = newValue }
    }
    #endif

    // MARK: - Configuration (internal-only, hardcoded)

    /// Edge API base URL. Hardcoded in source: no public setter, no
    /// Info.plist override, no env var.
    let apiConfiguration: APIConfiguration = .hardcoded

    // MARK: - Internals

    #if DEBUG
    private var _debugMode: DebugMode?
    #endif
    private var hasStarted = false
    private var syncTask: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Error>] = []

    #if DEBUG
    /// Test-only: number of times `spawnSyncTask` has run. Lets a regression
    /// test assert that a foreground trigger actually spawned a re-sync without
    /// reaching into the network. Behavior-neutral; compiled out of Release.
    private(set) var _syncSpawnCount = 0
    #endif

    private let engine: AttestationEngine
    private let bundle: Bundle
    private let urlSession: URLSession
    private var cachedContext: AppContext?
    // `nonisolated` so the DEBUG unknown-key `.fault` can log from the
    // `nonisolated` `secret(_:)` path. `os.Logger` is `Sendable` + immutable.
    private nonisolated let logger = Logger(subsystem: "dev.appattest.sdk", category: "client")

    // MARK: - Thread-safe snapshot (source of truth for the nonisolated reads)

    /// Immutable value read by the `nonisolated` accessors under a lock.
    /// `values` mirrors the observable `secrets`; `isReady` mirrors
    /// `state == .ready` (only ``secret(_:)`` needs it, to tell `.notReady`
    /// from `.absent`). iOS 17 target → `OSAllocatedUnfairLock` (`os`, iOS 16+);
    /// `Mutex` (Synchronization) would force an iOS 18 + Swift 6 bump.
    private struct SecretsState: Sendable {
        var values: [String: String] = [:]
        var isReady = false
    }

    /// The single lock-protected snapshot behind every `nonisolated` read. Kept
    /// identical to the observable `secrets` / `state` by the `setSecrets` /
    /// `setState` write funnels — there is no second, independently-mutated dict,
    /// so the two read isolations can never drift.
    @ObservationIgnored
    private nonisolated let secretsStateLock = OSAllocatedUnfairLock(initialState: SecretsState())

    #if DEBUG
    /// Dedupe set for the unknown-key `.fault` — each unknown key logs once per
    /// synced key-set. Cleared in `setSecrets` when the key-set changes. Lock-
    /// guarded so it is callable from the `nonisolated` `secret(_:)` path.
    @ObservationIgnored
    private nonisolated let _warnedKeys = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Test-only: count of unknown-key faults ACTUALLY emitted (past the dedupe
    /// guard). Lets a wiring test assert the dedupe suppresses repeats and that
    /// a key-set change re-arms it — without scraping OSLog. Behavior-neutral;
    /// compiled out of Release (like `_syncSpawnCount`).
    @ObservationIgnored
    private nonisolated let _emittedWarnCount = OSAllocatedUnfairLock(initialState: 0)

    /// Test-only accessor for `_emittedWarnCount`.
    var _testEmittedWarnCount: Int { _emittedWarnCount.withLock { $0 } }
    #endif

    // Test seam. Default singleton uses `.main` + `.shared`.
    //
    // `nonisolated` so `public static let shared = AppAttestClient()` is
    // constructible off the main actor — that is what lets the `nonisolated`
    // static forwarders (`AppAttest.secret(_:)`, etc.) reach the singleton with
    // no `await` hop. The init only stores immutable dependencies and lets the
    // stored-property defaults initialize the rest; it does no main-actor work.
    nonisolated init(
        bundle: Bundle = .main,
        urlSession: URLSession = .shared,
        engine: AttestationEngine = AttestationEngine()
    ) {
        self.bundle = bundle
        self.urlSession = urlSession
        self.engine = engine
    }

    // MARK: - Public API

    /// One-time setup. Synchronous and idempotent.
    ///
    /// 1. Hydrates `secrets` from the Keychain — if non-empty, transitions
    ///    `state = .ready` immediately (cold-start fast path).
    /// 2. Registers a `UIApplication.willEnterForegroundNotification`
    ///    observer for fingerprint refresh on foreground re-entry.
    /// 3. Spawns the background sync `Task` and returns.
    ///
    /// Zero-argument. The env bucket (sandbox vs production) is
    /// derived entirely from Apple's AAGUID inside the App Attest
    /// attestation object — edge reads it server-side and stamps it
    /// into the attestToken's `env` claim. The SDK is bucket-blind:
    /// no parameter, no Info.plist override, no public way to influence
    /// which bucket serves you. Dev/TestFlight builds → sandbox column;
    /// App Store builds → production column.
    public func start() {
        if hasStarted { return }
        hasStarted = true

        // Step 2 (hydrate) — read Keychain synchronously.
        if let bundle = persisting(.secrets, .load, { try primaryStoreOrNil()?.loadSecrets() }) ?? nil {
            setSecrets(bundle.secrets)
            // Cold-start fast path: tell the host app secrets are
            // already available before the network sync even starts.
            setState(.ready)
        }

        // Step 3 (foreground observer).
        registerForegroundObserver()

        // Step 4 (background work).
        spawnSyncTask()
    }

    /// Awaits a terminal state. Resolves on `.ready`. Throws when state
    /// is `.subscriptionRequired`, `.creditsRequired`, or `.unavailable`.
    public func waitForReady() async throws {
        switch state {
        case .ready: return
        case .subscriptionRequired(let e),
             .creditsRequired(let e),
             .unavailable(let e):
            throw e
        case .initializing, .attesting, .syncing: break
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            waiters.append(cont)
        }
    }

    /// Re-runs the background sync. For `.unavailable` (transient) states,
    /// retries the sync only. For `.subscriptionRequired`/`.creditsRequired`,
    /// caller must clear the underlying billing condition first; calling
    /// `retry()` after a top-up immediately re-runs the sync.
    public func retry() {
        syncTask?.cancel()
        spawnSyncTask(skipAttestIfPossible: true)
    }

    /// Wipes stored credentials and secrets. Resets state to
    /// `.initializing`. Next ``start()`` re-registers from scratch.
    public func reset() {
        syncTask?.cancel()
        syncTask = nil
        setSecrets([:])
        setState(.initializing)
        hasStarted = false
        // Fresh start: clear the degraded flags at entry. If the deleteAll
        // below then fails, `persisting` re-sets them — a failed wipe during
        // reset is a real degraded condition worth surfacing.
        clearPersistenceDegraded()
        persisting(.credentials, .delete) { try primaryStoreOrNil()?.deleteAll() }
        cachedContext = nil
    }

    /// Invalidate the cached secrets bundle and immediately sync.
    /// Keeps attestation credentials. The next sync sends no
    /// fingerprint, guaranteeing edge returns the full current bundle
    /// (200 with new bytes; this consumes one credit on the production
    /// bucket).
    ///
    /// Use cases:
    /// - Manual "sync now" / "force refresh" UI in a host app that
    ///   wants to guarantee freshness over cache-hit speed.
    /// - Test rigs that need to exercise the credit-decrement path on
    ///   demand without re-running the full attestation cycle.
    public func invalidateBundle() {
        persisting(.secrets, .delete) { try primaryStoreOrNil()?.deleteSecrets() }
        setSecrets([:])
        retry()
    }

    // MARK: - Thread-safe reads (nonisolated)

    /// Thread-safe snapshot of the currently-synced secrets. Readable from ANY
    /// isolation, no `await`. An immutable copy of the last-synced set; empty
    /// before the first successful sync. NOT observation-tracked — a SwiftUI
    /// view that must re-render on sync reads `secrets` (or `state`) instead.
    public nonisolated var currentSecrets: [String: String] {
        secretsStateLock.withLock { $0.values }
    }

    /// Thread-safe single-key value read — the hot path for a signing /
    /// networking closure off the main actor. Reads one key under the lock (no
    /// full-dict copy). `nil` for both not-synced and genuinely-absent; use
    /// ``secret(_:)`` when you need to tell those apart. NOT observation-tracked.
    public nonisolated func currentSecret(_ name: String) -> String? {
        secretsStateLock.withLock { $0.values[name] }
    }

    /// Names of all currently-synced secrets, sorted. Empty before the first
    /// successful sync. `nonisolated` / thread-safe. Use to validate expected
    /// keys at boot or to power a debug overlay.
    public nonisolated var availableKeys: [String] {
        secretsStateLock.withLock { $0.values.keys.sorted() }
    }

    /// Structured, disambiguating secret lookup. Prefer this over `secrets[key]`
    /// when you need to tell "not synced yet" apart from "typo / never
    /// registered". **`nonisolated` and thread-safe** — call it from any
    /// isolation (a signing / networking closure off the main actor) with no
    /// `await`. Reads the lock-protected snapshot, NOT the observable `secrets`,
    /// so it is not observation-tracked — see the reactive-vs-imperative split.
    ///
    /// In DEBUG builds an `.absent` result while `.ready` also emits an OSLog
    /// `.fault` naming the missing key and the available keys (deduped — each
    /// unknown key logs once per synced key-set). An unknown-key lookup after a
    /// successful sync is almost always a typo or a registration mismatch.
    /// Release builds are silent and allocation-free on this path.
    public nonisolated func secret(_ name: String) -> SecretLookup {
        let snap = secretsStateLock.withLock { $0 }          // atomic read of (values, isReady)
        if let v = snap.values[name] { return .value(v) }
        guard snap.isReady else { return .notReady }
        let available = snap.values.keys.sorted()
        #if DEBUG
        warnUnknownKeyIfNeeded(name, available: available)
        #endif
        return .absent(available: available)
    }

    #if DEBUG
    private nonisolated func warnUnknownKeyIfNeeded(_ name: String, available: [String]) {
        let firstTime = _warnedKeys.withLock { $0.insert(name).inserted }
        guard firstTime else { return }
        _emittedWarnCount.withLock { $0 += 1 }
        logger.fault("Unknown secret key '\(name, privacy: .public)'. Synced keys: \(available, privacy: .public). Check for a typo, or register it in the AppAttest dashboard.")
    }
    #endif

    // MARK: - State machine

    /// Lifecycle states.
    public enum State: Sendable, Equatable {
        case initializing
        case attesting
        case syncing
        case ready

        /// 402 `subscription_required`. Project's subscription is not
        /// active (never subscribed, or suspended). Developer must
        /// subscribe at `error.actionUrl`.
        case subscriptionRequired(AppAttestError)

        /// 402 `credits_required`. Subscribed but the cycle allowance is
        /// exhausted AND the prepaid balance is zero. Developer tops up
        /// at `error.actionUrl`, or waits for next cycle.
        case creditsRequired(AppAttestError)

        /// Anything else: attestation rejection, service interruption, or
        /// device-side network failure. The underlying error specifies
        /// which and whether the SDK is auto-retrying.
        case unavailable(AppAttestError)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.initializing, .initializing),
                 (.attesting, .attesting),
                 (.syncing, .syncing),
                 (.ready, .ready):
                return true
            case (.subscriptionRequired(let a), .subscriptionRequired(let b)),
                 (.creditsRequired(let a), .creditsRequired(let b)),
                 (.unavailable(let a), .unavailable(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    /// The result of a keyed secret lookup. Disambiguates the three states a
    /// bare `secrets[key]` collapses into a single `nil`.
    public enum SecretLookup: Sendable, Equatable {
        /// The key is present.
        case value(String)
        /// The SDK has not finished its first sync. The key may still appear;
        /// check again once `state == .ready`.
        case notReady
        /// The SDK is `.ready` and this key is genuinely not in the synced set.
        /// `available` lists the keys that ARE present — scan it for a typo or a
        /// dashboard-registration mismatch.
        case absent(available: [String])
    }

    /// Debug-only modes for SwiftUI previews and simulator development.
    /// `#if DEBUG`-stripped in Release builds, so this cannot leak into
    /// production binaries.
    ///
    /// Previously had a `.sandbox` case that synthesized fake
    /// attestations for development. That case is gone —
    /// real-device dev/TestFlight builds produce real
    /// sandbox attestations via Apple's AAGUID derivation, so there is
    /// no need (and no safe way) to synthesize one. For simulators and
    /// previews where App Attest is unavailable, use `.local(stubs:)`.
    #if DEBUG
    public enum DebugMode: Sendable, Equatable {
        /// No network, no attestation, no Keychain. `secrets` returns
        /// whatever stubs you pass in. The only debug mode.
        case local(stubs: [String: String])

        public static func == (lhs: DebugMode, rhs: DebugMode) -> Bool {
            switch (lhs, rhs) {
            case (.local(let a), .local(let b)): return a == b
            }
        }
    }
    #endif

    // MARK: - Background work

    private func spawnSyncTask(skipAttestIfPossible: Bool = false) {
        #if DEBUG
        _syncSpawnCount += 1
        #endif
        syncTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSync(skipAttestIfPossible: skipAttestIfPossible)
        }
        syncTask = task
    }

    /// Run the full sync flow with a one-shot self-heal for stale enclave
    /// keys. If `generateKey` / `attestKey` / `generateAssertion` reports
    /// `DCError.invalidKey` (the keyId in our keychain references an
    /// enclave key that's been wiped — reinstall, restore-from-backup,
    /// iOS eviction), we drop our cached credentials and recurse once
    /// with a forced fresh attestation. The user never sees the failed
    /// state; the recovery is silent.
    private func runSync(skipAttestIfPossible: Bool, hasRetriedStaleKey: Bool = false) async {
        #if DEBUG
        // Local debug mode: short-circuit, no network. Debug-only; the
        // entire `DebugMode` surface and its short-circuit compile out
        // of Release.
        if case .local(let stubs) = debugMode {
            setSecrets(stubs)
            transition(to: .ready)
            return
        }
        #endif

        do {
            let credentials = try await ensureCredentials(skipAttestIfPossible: skipAttestIfPossible)
            if !Task.isCancelled { setState(.syncing) }
            try await runFingerprintSync(credentials: credentials)
            transition(to: .ready)
        } catch is CancellationError {
            return
        } catch let engineError as AttestationEngineError {
            if Task.isCancelled { return }
            if case .invalidEnclaveKey = engineError, !hasRetriedStaleKey {
                // Stale credentials path. Wipe everything, force fresh
                // attestation, retry once. Caps at one retry per sync —
                // if the second attempt also fails, we surface it.
                logger.notice("Stale enclave key detected — wiping credentials and re-attesting.")
                persisting(.credentials, .delete) { try primaryStoreOrNil()?.deleteAll() }
                cachedContext = nil
                setState(.attesting)
                await runSync(skipAttestIfPossible: false, hasRetriedStaleKey: true)
                return
            }
            handle(error: engineError.publicError)
        } catch let error as AppAttestError {
            if Task.isCancelled { return }
            handle(error: error)
        } catch {
            handle(error: .network(underlying: error))
        }
    }

    /// Returns a non-expired attestToken. Re-attests if needed. Stores in
    /// Keychain. The bucket is encoded inside the attestToken's
    /// signed `env` claim, set by edge based on Apple's AAGUID. The SDK
    /// neither computes nor validates it — if a stored credential's
    /// env doesn't match what edge expects (e.g. user reinstalled with
    /// a different signing identity that flipped the AAGUID), edge
    /// rejects on use and the SDK's self-heal path re-attests.
    private func ensureCredentials(skipAttestIfPossible: Bool) async throws -> AttestCredentials {
        if let existing = try primaryStoreOrNil()?.loadCredentials(),
           !existing.isExpiringSoon() {
            return existing
        }
        if skipAttestIfPossible,
           let existing = try primaryStoreOrNil()?.loadCredentials() {
            return existing
        }
        if !Task.isCancelled { setState(.attesting) }
        return try await performAttestation()
    }

    /// Run the full `POST /v1/attest/challenge` → `attestKey` →
    /// `POST /v1/attest` flow. Returns a new credential persisted to
    /// Keychain. The env bucket is derived by edge from Apple's
    /// AAGUID in the attestation `authData` — SDK doesn't compute or
    /// send it.
    private func performAttestation() async throws -> AttestCredentials {
        let context = try resolveContext()

        if !AttestationEngine.isSupported {
            throw AppAttestError.attestationRejected(reason: "DCAppAttestService.isSupported = false (simulator or unsupported device). Set AppAttestClient.shared.debugMode = .local(stubs:) for previews and simulator development.")
        }

        let client = makeAPIClient()
        let challenge = try await client.requestChallenge()

        let keyId = try await engine.generateKey()
        let attestationB64 = try await engine.attestKey(keyId: keyId, challenge: challenge)

        let body = AttestRequest(
            teamId: context.teamId,
            keyId: keyId,
            bundleId: context.bundleId,
            attestation: attestationB64,
            challenge: challenge
        )
        let response = try await client.attest(body: body)

        let cred = AttestCredentials(
            keyId: keyId,
            token: response.attestToken
        )
        persisting(.credentials, .save) { try primaryStoreOrNil()?.saveCredentials(cred) }
        return cred
    }

    /// Run `POST /v1/secrets/sync`. Handles 200 + 304. Refreshes the
    /// attestToken if the response carries a new one.
    private func runFingerprintSync(credentials: AttestCredentials) async throws {
        // Identity AND bucket live in the signed attestToken claims,
        // not the wire body. The body carries only attest_token (+
        // fingerprint). Storage is keyed off the keychain service
        // identifier (which uses bundleId).
        // Best-effort cache read. A failed load surfaces as a persistence
        // signal AND leaves `lastFingerprint == nil` — which forces edge to
        // return a full 200 bundle (one credit) instead of a 304. That is the
        // headline credit-bleed cause this signal names: the failure is
        // reported, not swallowed.
        let storedBundle = persisting(.secrets, .load) { try primaryStoreOrNil()?.loadSecrets() } ?? nil
        let lastFingerprint = storedBundle?.fingerprint

        #if DEBUG
        // Test seam: bypass the Secure Enclave so a wiring test can drive the
        // real sync transport + persistence path deviceless. Never set in
        // Release (the whole property is `#if DEBUG`-stripped). Captured by
        // value here so the signBody closure never captures `self`.
        let signOverride = _testSignBodyOverride
        #endif

        let client = makeAPIClient()
        let result = try await client.sync(
            attestToken: credentials.token,
            fingerprint: lastFingerprint,
            signBody: { [engine, keyId = credentials.keyId] bodyBytes in
                #if DEBUG
                if let signOverride { return try await signOverride(bodyBytes) }
                #endif
                let hash = AttestationEngine.sha256(bodyBytes)
                return try await engine.generateAssertion(keyId: keyId, clientDataHash: hash)
            }
        )

        // Refresh-on-response. If edge minted a new attestToken,
        // rotate ours.
        if let refreshed = result.refreshedToken, !refreshed.isEmpty {
            var updated = credentials
            updated.updateToken(refreshed)
            persisting(.credentials, .save) { try primaryStoreOrNil()?.saveCredentials(updated) }
        }

        switch result {
        case .synced(let response):
            let new = Dictionary(uniqueKeysWithValues: response.secrets.map { ($0.key, $0.value) })
            setSecrets(new)
            persisting(.secrets, .save) { try primaryStoreOrNil()?.saveSecrets(SecretBundle(
                fingerprint: response.fingerprint,
                secrets: new,
                syncedAt: Date()
            )) }
        case .notModified(let response):
            // Fingerprint matched — keep current secrets. If the stored
            // bundle is missing the fingerprint (shouldn't happen, but
            // be tolerant), backfill it from the response.
            if let storedBundle, !response.fingerprint.isEmpty,
               storedBundle.fingerprint != response.fingerprint {
                persisting(.secrets, .save) { try primaryStoreOrNil()?.saveSecrets(SecretBundle(
                    fingerprint: response.fingerprint,
                    secrets: storedBundle.secrets,
                    syncedAt: Date()
                )) }
            }
        }
    }

    // MARK: - State helpers

    private func transition(to newState: State) {
        let was = state
        setState(newState)
        if newState == .ready, was != .ready {
            for w in waiters { w.resume() }
            waiters.removeAll()
        }
    }

    // MARK: - Single-source-of-truth write funnels

    /// The one write path to the synced secrets. Updates the lock snapshot
    /// (source of truth for the `nonisolated` reads) AND the observable
    /// `secrets` mirror (which drives SwiftUI) on the main actor, so the two
    /// can never drift. Every `secrets = …` assignment routes through here.
    private func setSecrets(_ new: [String: String]) {
        secretsStateLock.withLock { $0.values = new }   // source of truth first
        secrets = new                                    // observable mirror (drives SwiftUI)
        #if DEBUG
        _warnedKeys.withLock { $0.removeAll() }          // key-set changed → allow re-warn
        #endif
    }

    /// The one write path to `state`. Updates the observable `state` AND the
    /// snapshot's `isReady` mirror (which only ``secret(_:)`` reads, to tell
    /// `.notReady` from `.absent`). Every `state = …` assignment — and
    /// `transition(to:)` — routes through here.
    private func setState(_ s: State) {
        state = s
        secretsStateLock.withLock { $0.isReady = (s == .ready) }
    }

    /// Route an `AppAttestError` to its state.
    private func handle(error: AppAttestError) {
        switch error {
        case .subscriptionRequired:
            // We've stopped serving. Clear in-memory secrets after one
            // foreground cycle so the developer can't accidentally keep
            // using credentials we've explicitly stopped delivering.
            setSecrets([:])
            transition(to: .subscriptionRequired(error))
            failWaiters(with: error)

        case .creditsRequired:
            setSecrets([:])
            transition(to: .creditsRequired(error))
            failWaiters(with: error)

        case .attestationRejected:
            // Terminal: no auto-retry. Cached secrets cleared since
            // the device's attestation is rejected (probably stale or
            // corrupted; reinstall reseeds the App Attest key).
            setSecrets([:])
            transition(to: .unavailable(error))
            failWaiters(with: error)

        case .serviceUnavailable, .network:
            // Transient: keep cached secrets serving last-known values.
            // SDK retries on next foreground or explicit `retry()`.
            transition(to: .unavailable(error))
            failWaiters(with: error)
        }
    }

    private func failWaiters(with error: AppAttestError) {
        for w in waiters { w.resume(throwing: error) }
        waiters.removeAll()
    }

    // MARK: - Persistence signal

    /// Run a best-effort persistence op, recording any failure as a non-fatal
    /// signal. Never throws. Returns the op's value, or nil on failure. Every
    /// Keychain `try?` site routes through here so a swallowed persistence
    /// failure becomes an observable `persistenceDegraded` / `lastPersistenceError`
    /// signal (+ the `onPersistenceIssue` sink) instead of vanishing.
    @discardableResult
    private func persisting<T>(
        _ artifact: PersistenceError.Artifact,
        _ operation: PersistenceError.Operation,
        _ body: () throws -> T
    ) -> T? {
        do {
            let value = try body()
            if operation != .load { clearPersistenceDegraded() }  // a successful write proves the Keychain is writable again
            return value
        } catch let e as KeychainError {
            recordPersistenceFailure(.init(artifact: artifact, operation: operation, osStatus: e.osStatus))
            return nil
        } catch {
            recordPersistenceFailure(.init(artifact: artifact, operation: operation, osStatus: errSecInternalError))
            return nil
        }
    }

    private func recordPersistenceFailure(_ err: PersistenceError) {
        lastPersistenceError = err
        persistenceDegraded = true
        logger.error("\(err.description, privacy: .public)")   // OSLog regardless of sink
        onPersistenceIssue?(err)
    }

    private func clearPersistenceDegraded() {
        persistenceDegraded = false
        lastPersistenceError = nil
    }

    // MARK: - Context + storage

    private func resolveContext() throws -> AppContext {
        if let cached = cachedContext { return cached }
        let ctx = try AppContext.resolve(bundle: bundle)
        cachedContext = ctx
        return ctx
    }

    private func primaryStoreOrNil() throws -> (any KeychainStoring)? {
        #if DEBUG
        // Test seam: a wiring test injects a failing double here to drive the
        // persistence-degraded signal without a real Keychain. Nil in Release
        // (the property is `#if DEBUG`-stripped), so production always builds
        // the real `KeychainStore`.
        if let override = _testStoreOverride { return override }
        #endif
        let ctx = try resolveContext()
        return KeychainStore(
            serviceIdentifier: "dev.appattest.sdk.\(ctx.bundleId)",
            environmentTag: environmentTag
        )
    }

    private var environmentTag: String {
        // SDK is bucket-blind. A single keychain scope per bundleId
        // is sufficient. If the same bundleId ever produces both sandbox
        // and production attestations on the same device (debug build +
        // TestFlight build of the same app), edge's env-claim mismatch
        // on use triggers the self-heal re-attest path.
        return "v1"
    }

    private func makeAPIClient() -> APIClient {
        // Best-effort: pass the auto-derived team+bundle so that
        // `bundle_unavailable` / `unknown_app` errors get a
        // developer-actionable reason ("this bundle isn't registered,
        // go register at <signup-url>") instead of the generic
        // "service unavailable". If we can't resolve the context for
        // any reason, the client just falls back to the generic text.
        let devCtx: APIClient.DeveloperContext? = {
            guard let ctx = try? resolveContext() else { return nil }
            return APIClient.DeveloperContext(teamId: ctx.teamId, bundleId: ctx.bundleId)
        }()
        return APIClient(
            configuration: apiConfiguration,
            urlSession: urlSession,
            developerContext: devCtx
        )
    }

    private func synthesizeSimulatorId(for context: AppContext) -> String {
        let account = "simulatorId"
        let service = "dev.appattest.sdk.simulatorId"
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let s = SecItemCopyMatching(query as CFDictionary, &result)
        if s == errSecSuccess, let data = result as? Data, let str = String(data: data, encoding: .utf8) {
            return str
        }
        let fresh = UUID().uuidString
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(fresh.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(attrs as CFDictionary, nil)
        return fresh
        #else
        return UUID().uuidString
        #endif
    }

    // MARK: - Foreground observer

    private func registerForegroundObserver() {
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleForeground()
            }
        }
        #endif
    }

    private func handleForeground() {
        // Debounce on the live state machine, not task existence. A Task that
        // finished normally is never `.isCancelled` (that flag flips only after
        // an explicit `.cancel()`), and `syncTask` is nil'd only in `reset()` —
        // so the old `if let task = syncTask, !task.isCancelled` guard wedged
        // shut after the launch sync completed and no foreground ever re-synced
        // again (APP-78). `.attesting`/`.syncing` are the true in-flight signals.
        //
        // Benign window: between `spawnSyncTask` assigning `syncTask` and
        // `runSync` reaching `state = .syncing`, a foreground could see a stale
        // `.ready` and spawn a second sync. Harmless — `spawnSyncTask` cancels
        // the prior task first, so the newer task wins and nothing double-runs.
        if state == .attesting || state == .syncing { return }
        spawnSyncTask(skipAttestIfPossible: true)
    }

    // MARK: - Test-only seams

    #if DEBUG
    /// Test-only context override. Lets integration tests point at the
    /// fixture `(teamId, bundleId)` without bundling a real iOS test host.
    public func _testOverrideContext(teamId: String, bundleId: String) {
        cachedContext = AppContext(teamId: teamId, bundleId: bundleId)
    }

    /// Test-only forced state setter. Routes through the `setState` funnel so
    /// the snapshot's `isReady` mirror stays consistent with `state`.
    public func _testSetState(_ s: State) { setState(s) }

    /// Test-only forced secrets setter. Routes through the `setSecrets` funnel
    /// so the nonisolated snapshot mirrors the observable `secrets`.
    public func _testSetSecrets(_ d: [String: String]) { setSecrets(d) }

    /// Test-only foreground trigger. `handleForeground()` is private and the
    /// `UIApplication.willEnterForegroundNotification` observer never fires
    /// under `swift test` on macOS, so this drives the exact same code path a
    /// real foreground would (APP-78 regression coverage).
    public func _testHandleForeground() { handleForeground() }

    /// Test-only Keychain override. When set, `primaryStoreOrNil()` returns
    /// this instead of the real `KeychainStore` — lets a wiring test inject a
    /// store that throws on writes/reads and observe the persistence-degraded
    /// signal (APP-82) without touching the real Keychain. Debug-only.
    /// Internal (not public) because `KeychainStoring` is internal; tests reach
    /// it via `@testable import`.
    var _testStoreOverride: (any KeychainStoring)?

    /// Test-only assertion override. When set, `runFingerprintSync` uses this
    /// instead of the enclave-backed `engine.generateAssertion`, so a wiring
    /// test can drive the real sync transport + persistence path deviceless
    /// (the Secure Enclave is unavailable under `swift test`). Debug-only.
    var _testSignBodyOverride: (@Sendable (Data) async throws -> String)?
    #endif
}

// MARK: - Static namespace

/// Static namespace that forwards to ``AppAttestClient/shared``. Use this
/// from anywhere in the host app — observable tracking in SwiftUI views
/// still works because the underlying property lives on the singleton.
public enum AppAttest {
    /// Synchronous, idempotent setup. Zero-argument
    /// (bucket selection is AAGUID-derived server-side).
    @MainActor
    public static func start() {
        AppAttestClient.shared.start()
    }

    /// Synchronous secret lookup. `nil` if not yet synced or absent.
    @MainActor
    public static var secrets: [String: String] { AppAttestClient.shared.secrets }

    /// Structured, disambiguating secret lookup. **`nonisolated`** — callable
    /// from any isolation (a signing / networking closure off the main actor)
    /// with no `await`. Tells "not synced yet" (`.notReady`) apart from "typo /
    /// never registered" (`.absent`). See ``AppAttestClient/secret(_:)``.
    public nonisolated static func secret(_ name: String) -> AppAttestClient.SecretLookup {
        AppAttestClient.shared.secret(name)
    }

    /// Thread-safe snapshot of the currently-synced secrets. **`nonisolated`** —
    /// no `await` hop for off-main / imperative code. NOT observation-tracked;
    /// SwiftUI bodies read ``secrets`` instead. See ``AppAttestClient/currentSecrets``.
    public nonisolated static var currentSecrets: [String: String] {
        AppAttestClient.shared.currentSecrets
    }

    /// Thread-safe single-key value read — the hot path for a signing /
    /// networking closure off the main actor. **`nonisolated`**, no `await`.
    /// See ``AppAttestClient/currentSecret(_:)``.
    public nonisolated static func currentSecret(_ name: String) -> String? {
        AppAttestClient.shared.currentSecret(name)
    }

    /// Names of all currently-synced secrets, sorted. **`nonisolated`**.
    /// See ``AppAttestClient/availableKeys``.
    public nonisolated static var availableKeys: [String] {
        AppAttestClient.shared.availableKeys
    }

    /// Lifecycle state.
    @MainActor
    public static var state: AppAttestClient.State { AppAttestClient.shared.state }

    /// True when the SDK could not read or write its Keychain cache on the
    /// most recent attempt. Non-fatal; the current session is functional.
    /// See ``AppAttestClient/persistenceDegraded``.
    @MainActor
    public static var persistenceDegraded: Bool { AppAttestClient.shared.persistenceDegraded }

    /// The most recent persistence failure, or `nil` if the last cache write
    /// succeeded. See ``AppAttestClient/lastPersistenceError``.
    @MainActor
    public static var lastPersistenceError: PersistenceError? { AppAttestClient.shared.lastPersistenceError }

    /// Optional sink fired on the main actor for every persistence failure.
    /// Set before ``start()``. See ``AppAttestClient/onPersistenceIssue``.
    @MainActor
    public static var onPersistenceIssue: (@MainActor @Sendable (PersistenceError) -> Void)? {
        get { AppAttestClient.shared.onPersistenceIssue }
        set { AppAttestClient.shared.onPersistenceIssue = newValue }
    }

    /// Awaits the next terminal state. Resolves on `.ready`; throws on
    /// `.subscriptionRequired` / `.creditsRequired` / `.unavailable`.
    @MainActor
    public static func waitForReady() async throws {
        try await AppAttestClient.shared.waitForReady()
    }

    /// Re-runs the background sync.
    @MainActor
    public static func retry() { AppAttestClient.shared.retry() }

    /// Wipes stored credentials and secrets. Next ``start()`` re-registers
    /// from scratch.
    @MainActor
    public static func reset() { AppAttestClient.shared.reset() }

    /// Invalidate the cached secrets bundle and immediately sync. Keeps
    /// attestation credentials; forces a 200 (consumes 1 credit on the
    /// production bucket). Use for "force refresh" UX.
    @MainActor
    public static func invalidateBundle() { AppAttestClient.shared.invalidateBundle() }

    #if DEBUG
    /// Runtime mode. `nil` is production. Setting forces a re-sync on the
    /// next ``start()`` (you typically set this *before* `start()`).
    /// Debug-only — the entire surface is `#if DEBUG`-stripped in Release
    /// builds.
    @MainActor
    public static var debugMode: AppAttestClient.DebugMode? {
        get { AppAttestClient.shared.debugMode }
        set { AppAttestClient.shared.debugMode = newValue }
    }
    #endif
}
