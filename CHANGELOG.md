# Changelog

All notable changes to the AppAttest Swift SDK. Format: keep-a-changelog.
Versioning: SemVer (pre-1.0 minor bumps may break source compatibility).

## [Unreleased]

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
