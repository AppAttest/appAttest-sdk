// AppAttest — Swift SDK for AppAttest.
//
// Public surface lives in:
//   - `AppAttestClient` — `@Observable @MainActor` storage with `state`
//     and `secrets`. Use `AppAttestClient.shared` directly or inject via
//     SwiftUI environment.
//   - `AppAttest` (enum, in AppAttestClient.swift) — static namespace
//     forwarding to `AppAttestClient.shared`.
//
// Release builds always run real App Attest and meter. `#if DEBUG` strips
// `.local(stubs:)` — the only offline / free path — from Release binaries of
// consuming apps, so a shipped build has no offline path. `AppAttest.release`
// (.staging | .production) is compiled into all builds: it is only a routing
// label, carries no secrets, and never bypasses metering.

import Foundation

/// Module-level metadata. Distinct from the static `AppAttest` namespace
/// (which lives in `AppAttestClient.swift`) — this carries version
/// constants and is named differently to avoid the collision.
public enum AppAttestSDK {
    /// SDK semantic version. Updated with each release tag.
    public static let version = "0.3.0"

    /// API contract major version this SDK targets. Bump on a new SDK
    /// major when the api ships breaking `/v2/*` endpoints.
    public static let apiVersion = "v1"
}
