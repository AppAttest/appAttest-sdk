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
    public static let shared = AppAttestClient()

    // MARK: - Public observable state

    /// Lifecycle state. Observed via SwiftUI's `@Observable` tracking.
    public private(set) var state: State = .initializing

    /// Synced secrets, keyed by name. Lookup is synchronous.
    public private(set) var secrets: [String: String] = [:]

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

    private let engine: AttestationEngine
    private let bundle: Bundle
    private let urlSession: URLSession
    private var cachedContext: AppContext?
    private let logger = Logger(subsystem: "dev.appattest.sdk", category: "client")

    // Test seam. Default singleton uses `.main` + `.shared`.
    init(
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
        if let bundle = try? primaryStoreOrNil()?.loadSecrets() {
            secrets = bundle.secrets
            // Cold-start fast path: tell the host app secrets are
            // already available before the network sync even starts.
            state = .ready
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
        secrets = [:]
        state = .initializing
        hasStarted = false
        try? primaryStoreOrNil()?.deleteAll()
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
        try? primaryStoreOrNil()?.deleteSecrets()
        secrets = [:]
        retry()
    }

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
            secrets = stubs
            transition(to: .ready)
            return
        }
        #endif

        do {
            let credentials = try await ensureCredentials(skipAttestIfPossible: skipAttestIfPossible)
            if !Task.isCancelled { state = .syncing }
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
                try? primaryStoreOrNil()?.deleteAll()
                cachedContext = nil
                state = .attesting
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
        if !Task.isCancelled { state = .attesting }
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
        try? primaryStoreOrNil()?.saveCredentials(cred)
        return cred
    }

    /// Run `POST /v1/secrets/sync`. Handles 200 + 304. Refreshes the
    /// attestToken if the response carries a new one.
    private func runFingerprintSync(credentials: AttestCredentials) async throws {
        // Identity AND bucket live in the signed attestToken claims,
        // not the wire body. The body carries only attest_token (+
        // fingerprint). Storage is keyed off the keychain service
        // identifier (which uses bundleId).
        let storedBundle = try? primaryStoreOrNil()?.loadSecrets()
        let lastFingerprint = storedBundle?.fingerprint

        let client = makeAPIClient()
        let result = try await client.sync(
            attestToken: credentials.token,
            fingerprint: lastFingerprint,
            signBody: { [engine, keyId = credentials.keyId] bodyBytes in
                let hash = AttestationEngine.sha256(bodyBytes)
                return try await engine.generateAssertion(keyId: keyId, clientDataHash: hash)
            }
        )

        // Refresh-on-response. If edge minted a new attestToken,
        // rotate ours.
        if let refreshed = result.refreshedToken, !refreshed.isEmpty {
            var updated = credentials
            updated.updateToken(refreshed)
            try? primaryStoreOrNil()?.saveCredentials(updated)
        }

        switch result {
        case .synced(let response):
            let new = Dictionary(uniqueKeysWithValues: response.secrets.map { ($0.key, $0.value) })
            secrets = new
            try? primaryStoreOrNil()?.saveSecrets(SecretBundle(
                fingerprint: response.fingerprint,
                secrets: new,
                syncedAt: Date()
            ))
        case .notModified(let response):
            // Fingerprint matched — keep current secrets. If the stored
            // bundle is missing the fingerprint (shouldn't happen, but
            // be tolerant), backfill it from the response.
            if let storedBundle, !response.fingerprint.isEmpty,
               storedBundle.fingerprint != response.fingerprint {
                try? primaryStoreOrNil()?.saveSecrets(SecretBundle(
                    fingerprint: response.fingerprint,
                    secrets: storedBundle.secrets,
                    syncedAt: Date()
                ))
            }
        }
    }

    // MARK: - State helpers

    private func transition(to newState: State) {
        let was = state
        state = newState
        if newState == .ready, was != .ready {
            for w in waiters { w.resume() }
            waiters.removeAll()
        }
    }

    /// Route an `AppAttestError` to its state.
    private func handle(error: AppAttestError) {
        switch error {
        case .subscriptionRequired:
            // We've stopped serving. Clear in-memory secrets after one
            // foreground cycle so the developer can't accidentally keep
            // using credentials we've explicitly stopped delivering.
            secrets = [:]
            transition(to: .subscriptionRequired(error))
            failWaiters(with: error)

        case .creditsRequired:
            secrets = [:]
            transition(to: .creditsRequired(error))
            failWaiters(with: error)

        case .attestationRejected:
            // Terminal: no auto-retry. Cached secrets cleared since
            // the device's attestation is rejected (probably stale or
            // corrupted; reinstall reseeds the App Attest key).
            secrets = [:]
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

    // MARK: - Context + storage

    private func resolveContext() throws -> AppContext {
        if let cached = cachedContext { return cached }
        let ctx = try AppContext.resolve(bundle: bundle)
        cachedContext = ctx
        return ctx
    }

    private func primaryStoreOrNil() throws -> KeychainStore? {
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
        // Debounce: if a sync is already in flight, the new trigger no-ops.
        if let task = syncTask, !task.isCancelled {
            return
        }
        spawnSyncTask(skipAttestIfPossible: true)
    }

    // MARK: - Test-only seams

    #if DEBUG
    /// Test-only context override. Lets integration tests point at the
    /// fixture `(teamId, bundleId)` without bundling a real iOS test host.
    public func _testOverrideContext(teamId: String, bundleId: String) {
        cachedContext = AppContext(teamId: teamId, bundleId: bundleId)
    }

    /// Test-only forced state setter.
    public func _testSetState(_ s: State) { state = s }

    /// Test-only forced secrets setter.
    public func _testSetSecrets(_ d: [String: String]) { secrets = d }
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

    /// Lifecycle state.
    @MainActor
    public static var state: AppAttestClient.State { AppAttestClient.shared.state }

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
