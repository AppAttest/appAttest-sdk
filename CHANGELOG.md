# Changelog

All notable changes to the AppAttest Swift SDK. Format: keep-a-changelog.
Versioning: SemVer (pre-1.0 minor bumps may break source compatibility).

## [Unreleased]

## [0.4.0] - 2026-07-15

Correctness release. The declared server bucket no longer depends on how the
SDK itself was compiled — it is now an explicit, required argument.

### Fixed
- **The declared bucket could silently disagree with the developer's explicit
  choice.** The SDK derived its bucket from `#if DEBUG` (`Debug → always
  staging`), overriding `AppAttest.release`. Inside an SDK, `#if DEBUG` reflects
  how the *SDK's own compilation unit* was built — which a host app consuming
  the SDK via SwiftPM / CocoaPods does not control, and which can diverge from
  the host app's own `#if DEBUG`. An Xcode configuration that omits `DEBUG` from
  the app target while still building dependencies debug-flavored produced
  **distribution archives that silently declared `staging`** and were served
  **staging secrets while the developer believed they were on production**. The
  `#if DEBUG` override is removed entirely: the SDK declares the developer's
  explicit choice, always, regardless of compilation flavor.

### Changed (breaking)
- **`AppAttest.start()` → `AppAttest.start(release:)`.** The bucket is now a
  **required** argument with **no default** — a forgotten bucket is a compile
  error, never a wrong bucket in a shipped app. `AppAttest.release` (the
  settable property) is removed; `start(release:)` is the only way to declare a
  bucket, so it cannot be overridden after the fact.
- **The "Debug → always staging" rule is retired.** A Debug build declares
  whatever it passes. To attest against staging, say so:
  `AppAttest.start(release: .staging)`.
- **ObjC:** `start()` + `setRelease(_:completion:)` → a single
  `start(release:completion:)`. An unrecognized bucket string returns an
  `invalid_argument` NSError and the SDK **does not start**, rather than
  guessing a bucket.
- `reset()` now also clears the bucket — the next `start(release:)` supplies it
  explicitly again rather than inheriting a stale choice.

### Migration from 0.3.0

Pass the bucket you were previously relying on the default for:

```swift
// Before (0.3.0) — .production was the default, and Debug silently forced staging.
AppAttest.start()

// After (0.4.0) — say what you mean; it is honored in every build.
AppAttest.start(release: .production)
```

If you set `AppAttest.release = .staging`, move it into the call:

```swift
// Before
AppAttest.release = .staging
AppAttest.start()

// After
AppAttest.start(release: .staging)
```

**Check your Debug/development builds.** They used to be forced to `staging`
regardless. If a development build should keep reading staging, it must now say
`AppAttest.start(release: .staging)` — otherwise it declares `.production`, and
a development-signed build gets a loud `403 bucket_not_permitted` (add the
`com.apple.developer.devicecheck.appattest-environment=production` entitlement,
or declare `.staging`). Rejection is deliberate: a mismatched build is never
silently re-routed.

### Unchanged
- `AppAttest.debug = .local(stubs:)` remains `#if DEBUG`-only — correctly so.
  It is a free, offline path that must never exist in a shipped binary. (Gate
  the free path on the build flavor; never let the build flavor decide which
  metered bucket you meant.)
- Edge requires no change: it already resolves a declared bucket against Apple's
  AAGUID.

## [0.3.0] - 2026-07-14

Configuration and billing-model release. Two explicit, metered server buckets
selected by build type, an Apple-AAGUID secret-isolation rule, hardened
simulator / SwiftUI-preview handling, and a public API rename for symmetry.

### Added
- **`AppAttest.release` bucket selection.** A Release build attests against one
  of two functionally-identical, separately-keyed, metered buckets —
  `.staging` or `.production` (default `.production`). `.staging` lets a team
  verify end to end against a non-production secret set before shipping;
  `.production` is the live set. No code change is required between them — the
  same `start()` declares the right bucket for the build.
- **AAGUID-based secret isolation.** Apple's App Attest AAGUID (a build-time
  property) constrains which bucket a build may read: a development-signed build
  — including a distribution build that lacks the production App Attest
  entitlement — may reach only `.staging`; a production-entitled build may reach
  `.production`. A build requesting a bucket its AAGUID isn't permitted is
  rejected at attestation with `AppAttestError.attestationRejected`, whose
  reason names the fix (add the entitlement, or set `AppAttest.release` to
  `.staging`).
- **Hardened unsupported-environment handling.** On the simulator (no Secure
  Enclave) without `.local`, the SDK stops with an actionable message that is
  compiled in only for the simulator target and can never exist in a device
  build. In a SwiftUI `#Preview` without `.local`, it never crashes — it logs a
  loud fault and renders a safe empty state. On rare unsupported real hardware
  it fails open rather than crashing.

### Changed
- **Both server buckets are metered.** `.staging` and `.production` each require
  a real Apple attestation on every call and each draws down the project's
  allotment; selecting `.staging` in a shipped build changes only *which*
  secrets are read, never *whether* usage is counted. The one offline path
  remains `.local(stubs:)`, which is `#if DEBUG`-stripped from Release.
- **Renamed `AppAttest.debugMode` → `AppAttest.debug`** (breaking, source-level).
  Symmetric with `AppAttest.release`. The `.local(stubs:)` value and its
  `#if DEBUG`-only stripping are unchanged — update
  `AppAttest.debugMode = .local(...)` to `AppAttest.debug = .local(...)`. The
  Objective-C facade method `setDebugMode(_:stubs:completion:)` is likewise
  renamed to `setDebug(_:stubs:completion:)`.

## [0.2.0] - 2026-07-12

Reliability and observability release: a foreground re-sync bug fix, a new
non-fatal signal when device storage is degraded, thread-safe secret reads for
off-main callers, and expanded failure-handling documentation.

### Added
- **Non-fatal persistence-degraded signal.** When the Keychain can't be written
  or read, the SDK no longer fails silently — it surfaces the problem without
  breaking a sync. New public `PersistenceError` (which artifact, which
  operation, the underlying OS status, and whether it affects billing) plus
  `persistenceDegraded`, `lastPersistenceError`, and an `onPersistenceIssue`
  sink on `AppAttestClient` (and the `AppAttest.*` forwarders). A degraded
  device keeps serving secrets from memory; the signal lets the host app react
  (log, warn, prompt) instead of guessing.
- **Thread-safe, off-main secret reads.** Secrets can now be read from any
  thread with no `@MainActor` hop, so signing/networking closures that run off
  the main actor no longer have to `await`. New `nonisolated` reads
  `currentSecrets`, `currentSecret(_:)`, and `availableKeys`, plus
  `secret(_:) -> SecretLookup` — a keyed lookup that disambiguates the three
  states a bare `secrets[key] == nil` collapses together: `.value`,
  `.notReady`, and `.absent(available:)`. The existing `@Observable` `secrets`
  dictionary is unchanged as the reactive, main-actor mirror.

### Fixed
- **Foreground re-sync no longer stops working after the first sync.** Bringing
  the app to the foreground reliably re-syncs every time; previously the
  re-sync could stop firing after the initial one.

### Changed
- **Expanded failure-handling documentation.** New guidance on the full failure
  surface — the persistence-degraded signal, disambiguating unknown secret
  keys, and reading secrets reactively (SwiftUI) versus imperatively (off-main
  signing closures). Replaced an unsafe force-unwrap example in Getting Started
  with a safe keyed read.

## [0.1.0] - 2026-05-29

First public release. A zero-configuration Swift SDK that delivers your app's
secrets — API keys, tokens — to your iOS app, gated on Apple's App Attest so
only a genuine build of your genuine app can read them.

### Added
- **Zero-config attestation.** One call at launch — `AppAttest.start()`. The
  SDK identifies your app by Apple's `{teamId}.{bundleId}`, both auto-derived
  on-device. No keys to paste, no base URL to configure.
- **Synchronous secret reads.** `AppAttest.secrets["KEY"]` returns from an
  in-memory dictionary hydrated from the Keychain; SwiftUI re-renders any view
  that reads it when secrets land. `AppAttestClient` is `@Observable @MainActor`.
- **Observable lifecycle state** for gating UI — `.initializing`, `.attesting`,
  `.syncing`, `.ready`, `.subscriptionRequired`, `.creditsRequired`,
  `.unavailable` — plus `AppAttest.waitForReady()` for async bootstrap.
- **Self-healing.** Foreground re-entry re-syncs automatically; a stale device
  key silently re-attests; `retry()`, `reset()`, and `invalidateBundle()` cover
  transient recovery and force-refresh.
- **Typed errors.** `AppAttestError` with a stable string `code` per case and a
  single `actionUrl` accessor for the billing-state cases.
- **`AppAttestObjC`** companion library — an Objective-C-friendly facade
  (completion handlers, `NSError`) for bridge writers and Objective-C consumers.
- **Cross-platform bridges** — React Native (`@appattest/react-native`), Flutter
  (`appattest_flutter`), and Capacitor (`@appattest/capacitor`), each exposing
  the same `start / waitForReady / getSecret / state-observer` shape, idiomatic
  to its runtime. Published as `@appattest/react-native` and
  `@appattest/capacitor` (npm) and `appattest_flutter` (pub.dev); sources
  live under `bridges/`.
- **Debug mode** — `AppAttest.debugMode = .local(stubs:)` for SwiftUI previews,
  simulator runs, unit tests, and CI where Apple's App Attest is unavailable.
- **Apple privacy manifest** (`PrivacyInfo.xcprivacy`): no tracking, no
  required-reason API usage, no user-identity data collection.
- DocC catalog.

### Security
- **Release builds always run real attestation.** The debug-mode surface is
  entirely `#if DEBUG`-gated — the `DebugMode` type, its setter, and the
  short-circuit are physically absent from any Release / TestFlight / App Store
  binary (verified by symbol inspection).
- **Single hardcoded production base URL.** No runtime override, no Info.plist
  switch, no environment variable — the SDK cannot be pointed at another host.
- **The customer-facing surface reveals no backend internals.** Error
  descriptions, reasons, and doc comments describe your app's state and the
  action to take, never the service's infrastructure; server-supplied error
  codes are validated against a closed allow-list at the boundary.
- **Keychain storage** under `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  — device-local, never iCloud-synced.

### Platforms
- iOS 17, macOS 14, tvOS 17, watchOS 10. Swift 5.9+, Xcode 15+.

### Distribution
- Swift Package Manager and CocoaPods (`pod 'AppAttest'`). Source
  distribution — the consumer's build compiles the SDK (the `#if DEBUG`
  Release-strip depends on it).
