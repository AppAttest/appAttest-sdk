// AppAttestObjC — flat, @objc-friendly facade over the AppAttest SDK.
//
// Bridge writers (React Native, Flutter, Capacitor) and Objective-C
// consumers should target this module. It translates the @Observable
// MainActor surface into:
//   - completion-handler async ops
//   - NSError envelope (with stable string `code`, plus a CTA URL key
//     for the 402 family — see asNSError)
//   - synchronous secret lookup (`secret(forKey:)`)
//   - state-observer registration that returns a cancellation token
//
// Native Swift consumers should target `AppAttest` directly. This module
// is intentionally lossy.
//
// **Surface notes:**
//   - The `app_not_live` state collapses into `subscription_required`
//     (Subscribe = Go-Live).
//   - The `.failed` state was renamed `.unavailable` ("can't serve right
//     now" rather than "broken").
//   - Sandbox-mode forcing-function modal is gone — developers handle
//     their own UX. No `setSandboxModalEnabled`.

import Foundation
import AppAttest

/// `NSError` domain used by `AppAttestObjC` errors.
public let AppAttestErrorDomain = "dev.appattest.sdk"

/// Snapshot of the lifecycle state surface.
@objc(AppAttestState)
public final class AppAttestState: NSObject {
    /// Stable string code for the state — one of:
    /// `"initializing"`, `"attesting"`, `"syncing"`, `"ready"`,
    /// `"subscription_required"`, `"credits_required"`, `"unavailable"`.
    @objc public let name: String
    /// For `"subscription_required"` / `"credits_required"` /
    /// `"unavailable"`: the underlying error. `nil` for `"initializing"` /
    /// `"attesting"` / `"syncing"` / `"ready"`.
    @objc public let error: NSError?

    init(name: String, error: NSError?) {
        self.name = name
        self.error = error
        super.init()
    }
}

/// Token returned by `addStateObserver`. Holding a reference keeps the
/// observation alive; `invalidate()` (or simply releasing the token) stops
/// further callbacks. Bridges convert this into idiomatic listener handles.
@objc(AppAttestObservationToken)
public final class AppAttestObservationToken: NSObject {
    let id: UUID
    private let onInvalidate: (UUID) -> Void

    init(id: UUID, onInvalidate: @escaping (UUID) -> Void) {
        self.id = id
        self.onInvalidate = onInvalidate
        super.init()
    }

    @objc public func invalidate() { onInvalidate(id) }

    deinit { onInvalidate(id) }
}

/// Object-C-friendly facade over `AppAttestClient.shared`.
///
/// All async operations expose completion handlers. All errors arrive as
/// `NSError` in `AppAttestErrorDomain` with `userInfo["code"]` carrying
/// the stable string code. For the 402 family, `userInfo` carries exactly
/// one of `userInfo["subscribeUrl"]` (`subscription_required`) or
/// `userInfo["topupUrl"]` (`credits_required`).
@objc(AppAttestObjCClient)
public final class AppAttestObjCClient: NSObject {

    /// Singleton wrapper. The underlying state lives in
    /// `AppAttestClient.shared`; this facade is stateless.
    @objc public static let shared = AppAttestObjCClient()

    private var observers: [UUID: (AppAttestState) -> Void] = [:]
    private var stateWatcher: Task<Void, Never>?
    private var lastState: AppAttestClient.State = .initializing
    private let lock = NSLock()

    @objc public override init() {
        super.init()
    }

    // MARK: - Lifecycle

    /// Synchronous, idempotent setup.
    ///
    /// - Parameter release: The server bucket this build attests against.
    ///   **Required** — `"production"` or `"staging"`. There is no default and
    ///   no inference: the bucket is exactly what you pass, whatever
    ///   compilation flavor the SDK itself was built with.
    /// - Parameter completion: `nil` on success. An `invalid_argument` NSError
    ///   if `release` is not a known bucket — in which case **the SDK does not
    ///   start**, rather than guessing a bucket.
    ///
    /// Edge resolves the declaration against Apple's AAGUID; a
    /// development-signed build declaring `"production"` gets a loud
    /// `403 bucket_not_permitted`.
    @objc public func start(
        release name: String,
        completion: @escaping (NSError?) -> Void
    ) {
        Task { @MainActor in
            let bucket: ReleaseBucket
            switch name {
            case "production": bucket = .production
            case "staging":    bucket = .staging
            default:
                // Do NOT start. An unknown string is a misconfiguration; the
                // one thing we must never do is pick a bucket on their behalf.
                completion(nsError(
                    code: "invalid_argument",
                    message: "unknown release bucket: \(name). Use \"production\" or \"staging\".",
                    status: 400
                ))
                return
            }
            AppAttestClient.shared.start(release: bucket)
            completion(nil)
        }
    }

    /// Re-runs the background sync.
    @objc public func retry() {
        Task { @MainActor in AppAttestClient.shared.retry() }
    }

    /// Wipes stored credentials and secrets.
    @objc public func reset(completion: @escaping (NSError?) -> Void) {
        Task { @MainActor in
            AppAttestClient.shared.reset()
            completion(nil)
        }
    }

    /// Invalidate the cached secrets bundle and immediately sync.
    /// Keeps attestation credentials. The next sync sends no fingerprint,
    /// guaranteeing edge returns the full current bundle (200 with new
    /// bytes; consumes one credit on the production bucket).
    ///
    /// Use for host-app "force refresh" UI or test rigs that need to
    /// exercise the credit-decrement path on demand.
    @objc public func invalidateBundle() {
        Task { @MainActor in AppAttestClient.shared.invalidateBundle() }
    }

    /// Awaits a terminal state. Resolves on `.ready`; calls back with an
    /// error on `.subscriptionRequired` / `.creditsRequired` /
    /// `.unavailable`.
    @objc public func waitForReady(completion: @escaping (NSError?) -> Void) {
        Task { @MainActor in
            do {
                try await AppAttestClient.shared.waitForReady()
                completion(nil)
            } catch {
                completion(asNSError(error))
            }
        }
    }

    // MARK: - Configuration

    /// Set the runtime mode. Valid values:
    /// - `nil` / `"production"` — production (default).
    /// - `"local"` — DEBUG only; pass `stubs` for the inline secret dict.
    ///
    /// `"sandbox"` is not a valid value. Real dev/TestFlight
    /// builds produce real sandbox attestations via Apple's AAGUID —
    /// there is no need (and no safe way) to synthesize one client-side.
    @objc public func setDebug(
        _ name: String?,
        stubs: [String: String]?,
        completion: @escaping (NSError?) -> Void
    ) {
        Task { @MainActor in
            switch name {
            case nil, "production":
                #if DEBUG
                AppAttestClient.shared.debug = nil
                #endif
                // In Release, `debug` doesn't exist on the Swift side;
                // production is the only mode anyway, so resetting to it is
                // a no-op.
                completion(nil)
            #if DEBUG
            case "local":
                AppAttestClient.shared.debug = .local(stubs: stubs ?? [:])
                completion(nil)
            #else
            case "local":
                completion(nsError(
                    code: "debug_mode_release_blocked",
                    message: "\"local\" is debug-only and not available in Release builds.",
                    status: 400
                ))
            #endif
            default:
                completion(nsError(
                    code: "invalid_argument",
                    message: "unknown debug mode: \(name ?? "<nil>")",
                    status: 400
                ))
            }
        }
    }

    // MARK: - Reads (synchronous)

    /// Synchronous secret lookup. `nil` if not yet synced or absent.
    @MainActor
    @objc public func secret(forKey key: String) -> NSString? {
        return AppAttestClient.shared.secrets[key].map { $0 as NSString }
    }

    /// Snapshot of every synced secret as `[name: value]`.
    @MainActor
    @objc public func allSecrets() -> [String: String] {
        return AppAttestClient.shared.secrets
    }

    /// Current state snapshot.
    @MainActor
    @objc public func currentState() -> AppAttestState {
        return Self.snapshot(AppAttestClient.shared.state)
    }

    // MARK: - State observation

    /// Register a state observer. The block fires once with the current
    /// state at registration, then on every transition. Returns a token
    /// — release it (or call `invalidate()`) to stop further callbacks.
    @objc public func addStateObserver(
        _ block: @escaping (AppAttestState) -> Void
    ) -> AppAttestObservationToken {
        let id = UUID()
        lock.lock()
        observers[id] = block
        lock.unlock()
        // Fire current state immediately.
        Task { @MainActor in
            block(Self.snapshot(AppAttestClient.shared.state))
        }
        startWatcherIfNeeded()
        return AppAttestObservationToken(id: id) { [weak self] tokenId in
            self?.removeObserver(id: tokenId)
        }
    }

    private func removeObserver(id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        let stillHasObservers = !observers.isEmpty
        lock.unlock()
        if !stillHasObservers {
            stateWatcher?.cancel()
            stateWatcher = nil
        }
    }

    private func startWatcherIfNeeded() {
        if stateWatcher != nil { return }
        stateWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                guard let self else { return }
                await MainActor.run {
                    let now = AppAttestClient.shared.state
                    if now != self.lastState {
                        self.lastState = now
                        let snap = Self.snapshot(now)
                        self.lock.lock()
                        let blocks = Array(self.observers.values)
                        self.lock.unlock()
                        for b in blocks { b(snap) }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static func snapshot(_ s: AppAttestClient.State) -> AppAttestState {
        switch s {
        case .initializing: return AppAttestState(name: "initializing", error: nil)
        case .attesting: return AppAttestState(name: "attesting", error: nil)
        case .syncing: return AppAttestState(name: "syncing", error: nil)
        case .ready: return AppAttestState(name: "ready", error: nil)
        case .subscriptionRequired(let e): return AppAttestState(name: "subscription_required", error: asNSError(e))
        case .creditsRequired(let e): return AppAttestState(name: "credits_required", error: asNSError(e))
        case .unavailable(let e): return AppAttestState(name: "unavailable", error: asNSError(e))
        }
    }
}

// MARK: - Error mapping (file-scope so AppAttestState can use it)

func asNSError(_ error: Error) -> NSError {
    if let app = error as? AppAttestError {
        var extras: [String: Any] = [:]
        if let url = app.actionUrl {
            // Pick the userInfo key that matches the 402 code. Bridges
            // read whichever they expect; consumers just open the URL.
            switch app {
            case .subscriptionRequired: extras["subscribeUrl"] = url.absoluteString
            case .creditsRequired: extras["topupUrl"] = url.absoluteString
            case .attestationRejected, .serviceUnavailable, .network: break
            }
        }
        let status = appAttestStatus(app)
        return nsError(code: app.code, message: app.description, status: status, extras: extras)
    }
    return nsError(code: "internal_error",
                   message: String(describing: error),
                   status: 500)
}

func nsError(
    code: String,
    message: String,
    status: Int,
    extras: [String: Any] = [:]
) -> NSError {
    var userInfo: [String: Any] = [
        "code": code,
        "message": message,
        NSLocalizedDescriptionKey: message
    ]
    for (k, v) in extras { userInfo[k] = v }
    return NSError(
        domain: AppAttestErrorDomain,
        code: status,
        userInfo: userInfo
    )
}

private func appAttestStatus(_ error: AppAttestError) -> Int {
    switch error {
    case .subscriptionRequired, .creditsRequired: return 402
    case .attestationRejected: return 401
    case .serviceUnavailable: return 503
    case .network: return 500
    }
}
