# Changelog

All notable changes to the AppAttest Swift SDK. Format: keep-a-changelog.
Versioning: SemVer (pre-1.0 minor bumps may break source compatibility).

## [Unreleased]

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
