# AppAttest

Swift SDK for [AppAttest](https://www.appattest.dev). Delivers API keys and app
secrets to your iOS app, gated on Apple's App Attest so only a real build
of your real app can read them.

- Zero developer-typed configuration. The SDK identifies your app by
  Apple's `{teamId}.{bundleId}` — both auto-derived on-device.
- One call at boot — `AppAttest.start()` — fire and forget.
- Synchronous secret reads from in-memory dict. SwiftUI re-renders when secrets land.
- Release builds always run real attestation. Debug modes compile out.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/AppAttest/appAttest-sdk.git", from: "0.3.0")
```

CocoaPods:

```ruby
pod 'AppAttest'
```

## Configure

Nothing to configure. Register your bundle ID in the AppAttest dashboard
under your team; the SDK reads `{teamId, bundleId}` from your running
binary at zero developer cost.

### Optional: cold-start perf hint

The SDK auto-detects your Apple Team ID at first launch via the keychain
access-group probe. If you want to skip the probe (saves a few
milliseconds on cold start), you may set `APPATTEST_TEAM_ID` in your
Info.plist:

```xml
<key>APPATTEST_TEAM_ID</key>
<string>YOUR_APPLE_TEAM_ID</string>
```

Strictly an opt-in performance hint — the keychain probe always works.
The SDK still requires zero developer-typed configuration; this is the
one knob, and only for shaving startup latency.

## Quick start

```swift
import SwiftUI
import AppAttest

@main
struct MyApp: App {
    init() { AppAttest.start() }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    var body: some View {
        if let key = AppAttest.secrets["OPENAI_API_KEY"] {
            Text("Ready")
        } else {
            ProgressView("Loading…")
        }
    }
}
```

That's it.

## Usage

### Recommended: environment injection (testable)

```swift
@main
struct MyApp: App {
    init() { AppAttest.start() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(AppAttestClient.shared)
        }
    }
}

struct ContentView: View {
    @Environment(AppAttestClient.self) private var attest

    var body: some View {
        Text(attest.secrets["OPENAI_API_KEY"] ?? "Loading…")
    }
}
```

`AppAttestClient` is `@Observable @MainActor`. SwiftUI re-renders any view
that reads `secrets` or `state` when either changes.

### Gating UI on state

```swift
struct RootView: View {
    @Environment(AppAttestClient.self) private var attest

    var body: some View {
        switch attest.state {
        case .ready:                            MainView()
        case .subscriptionRequired(let err):    SubscribeNoticeView(error: err)
        case .creditsRequired(let err):         TopUpNoticeView(error: err)
        case .unavailable(let err):             RetryView(error: err) { attest.retry() }
        case .initializing, .attesting, .syncing: SplashView()
        }
    }
}
```

**For end-user-facing apps:** render a generic "service temporarily
unavailable, try again later" notice for any of the three non-`.ready`
terminal states. **Don't surface `subscribeUrl` / `topupUrl` to the end
user** — those are for the developer's logs / staff builds / admin flow.

**For developer / staff builds:** print the full error payload (including
the deep-link URL) so the developer immediately knows whether to subscribe,
top up, or investigate a service incident.

### Bootstrap waiting on a secret

```swift
struct BootstrapView: View {
    @State private var configured = false

    var body: some View {
        Group { if configured { MainView() } else { SplashView() } }
            .task {
                try? await AppAttest.waitForReady()
                APIClient.configure(token: AppAttest.secrets["BACKEND_KEY"]!)
                configured = true
            }
    }
}
```

### Reading from non-SwiftUI code

```swift
import AppAttest

@MainActor
func buildOpenAIClient() -> OpenAIClient? {
    guard let key = AppAttest.secrets["OPENAI_API_KEY"] else { return nil }
    return OpenAIClient(apiKey: key)
}
```

## Lifecycle

`AppAttest.start()`:

1. Hydrates `secrets` from the Keychain. Non-empty → `state = .ready`
   immediately (cold-start fast path; second-and-subsequent launches see
   secrets before the first frame renders).
2. Hooks `UIApplication.willEnterForegroundNotification`. The host app
   does no lifecycle wiring.
3. Spawns the background sync `Task` and returns.

Background work: first-launch flow is `POST /v1/attest/challenge` →
`DCAppAttestService.attestKey` → `POST /v1/attest` → `POST /v1/secrets/sync`
→ `state = .ready`. Subsequent launches: fingerprint sync only (no
re-attestation). Foreground re-entry runs the sync path with debouncing.

The attestToken refreshes opportunistically — every successful
`/v1/secrets/sync` response that's past 50% of the token's TTL ships a
fresh token in the response body. Cycle is automatic and transparent.

`AppAttest.retry()` re-runs the sync (no re-attestation). Use after an
`.unavailable` state to recover from a transient network or service failure.

## Debug modes

The simulator cannot produce a real App Attest attestation. Use
`.local(stubs:)` — the case, the property, and the backing type are all
wrapped in `#if DEBUG` so the entire surface is physically absent from
any Release binary.

| Mode | Network | Reads from |
|------|---------|------------|
| (production, default — `debug = nil`) | yes | sandbox or production column, per AAGUID |
| `.local(stubs:)` | no | inline dictionary |

Dev / TestFlight builds on real devices produce real App Attest
attestations against the sandbox column via Apple's AAGUID — no
`debug` needed. `.local(stubs:)` is for SwiftUI previews,
simulator runs, unit tests, and CI runners where Apple's App Attest
service literally isn't reachable.

```swift
@main
struct MyApp: App {
    init() {
        #if DEBUG
        AppAttest.debug = .local(stubs: [
            "OPENAI_API_KEY": "sk-test-stub",
            "BACKEND_KEY": "dev-token-abc"
        ])
        #endif
        AppAttest.start()
    }
    // ...
}
```

## How buckets work (sandbox vs production)

The SDK is **bucket-blind**: there is no `secretsBucket:`
argument on `AppAttest.start()`, no Info.plist override, no public
way to pick which bucket serves your app. Apple's App Attest
AAGUID — a 16-byte mode marker stamped into every attestation —
is the sole signal:

- **Dev / TestFlight builds** → Apple stamps the *development*
  AAGUID → AppAttest serves the **sandbox** secrets column.
- **App Store builds** → Apple stamps the *production* AAGUID →
  AppAttest serves the **production** secrets column.

No code changes between sandbox testing and production shipping.
The same `AppAttest.start()` reads the right bucket for the build
context it's running in.

For last-mile verification of production secrets before submitting
to the App Store, use TestFlight: a TestFlight build carries the real
production AAGUID, so it reads the production column. There is no
SDK-side override and no debug-build path to the production column.

## Errors

The SDK's failure surface is five cases:

| Case | When |
|------|------|
| `subscriptionRequired(subscribeUrl:)` | Project subscription not active. Lands as `state = .subscriptionRequired(_)`. |
| `creditsRequired(topupUrl:)` | Cycle allowance exhausted AND prepaid balance is zero. Lands as `state = .creditsRequired(_)`. |
| `attestationRejected(reason:)` | Apple's `DCAppAttestService` failed, or AppAttest rejected the attestation. Terminal for this install — reinstall reseeds the device key. Lands as `state = .unavailable(_)`. |
| `serviceUnavailable(reason:)` | AppAttest is temporarily unable to serve (service incident or maintenance). Retryable — SDK auto-retries with backoff. Lands as `state = .unavailable(_)`. |
| `network(underlying:)` | Device-side transport / decoding / keychain failure. Retryable. Lands as `state = .unavailable(_)`. |

Each 402-family case carries the dashboard URL the developer should
open. Read `error.actionUrl` for a single accessor regardless of code,
or pick the typed property (`subscribeUrl` / `topupUrl`) that matches.

**Cached-secrets policy.** Transient `.unavailable` states keep serving
cached secret values from the Keychain. `.subscriptionRequired` /
`.creditsRequired` / `.unavailable(.attestationRejected)` clear the
in-memory secrets — we've explicitly stopped delivering, and the SDK
respects that.

## Platforms

- iOS 17.0+
- macOS 14.0+
- tvOS 17.0+
- watchOS 10.0+

Swift 5.9+. Xcode 15.0+.

The `@Observable` macro requires Swift 5.9 / iOS 17.

## Storage

Credentials (App Attest keyId + attestToken JWT) and synced secrets live
in the Keychain under `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
Nothing syncs across devices. Secure Enclave-backed where hardware
supports it.

## Tests

```bash
swift test
```

The integration test pings `edge.appattest.dev/healthz` (production).
Skip on offline runs:

```bash
APPATTEST_SKIP_INTEGRATION=1 swift test
```

Real-device verification of the full attestation flow requires an
iPhone — App Attest doesn't run in simulator.

## For bridge writers and Objective-C consumers

A second library product, `AppAttestObjC`, ships in this same package. It
exposes a `@objc`-friendly facade with completion handlers, `NSError`
envelopes (with `subscribeUrl`/`topupUrl` keys for the 402
family), and a state-observer registration pattern. React Native, Flutter,
and Capacitor bridges depend on it.

```swift
import AppAttestObjC

let client = AppAttestObjCClient.shared
client.start()
let token = client.addStateObserver { state in
    if state.name == "ready" {
        let key = client.secret(forKey: "OPENAI_API_KEY") as String?
        // ...
    }
}
```

Native Swift consumers should use `AppAttest` directly — `AppAttestObjC`
is intentionally lossy.

## Cross-platform bridges

| Runtime | Package |
|---------|---------|
| React Native | `@appattest/react-native` (npm) |
| Flutter | `appattest_flutter` (pub.dev) |
| Capacitor | `@appattest/capacitor` (npm) |

All three expose the same `start() / waitForReady() / getSecret(name) /
state observer` shape, idiomatic to each runtime.

Each bridge's README (under `bridges/`) carries its install and quick start.

## Documentation

| File | For |
|------|-----|
| `README.md` | this file |
| `CHANGELOG.md` | per-release changes |
| `SECURITY.md` | how to report vulnerabilities |
| `Sources/AppAttest/Documentation.docc/` | DocC catalog |

## Status

`0.3.0`. Surface implemented and tested.

## License

MIT. See [LICENSE](LICENSE).
