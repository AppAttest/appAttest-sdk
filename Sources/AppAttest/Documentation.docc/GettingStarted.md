# Getting Started

Install the SDK, register your app, and read your first secret.

## Install

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/AppAttest/appAttest-sdk.git", from: "0.1.0")
]
```

Or in Xcode: **File → Add Package Dependencies** and paste the repo URL.

## Register your app

1. Create an account at https://www.appattest.dev.
2. Add a team using your Apple Developer Team ID.
3. Add an app using your bundle ID. AppAttest auto-provisions an encryption key.
4. Add a secret under the `production` environment. Copy its name (not the
   value).

## Call the SDK

One call at app start. Fire and forget.

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
```

``AppAttest/start()`` is synchronous and idempotent. It hydrates
``AppAttestClient/secrets`` from the Keychain (cold-start fast path),
hooks a foreground observer, and spawns the background sync `Task`.
Subsequent calls are no-ops.

Read a secret anywhere in the app, synchronously, off the in-memory dict:

```swift
struct ContentView: View {
    var body: some View {
        if let key = AppAttest.secrets["OPENAI_API_KEY"] {
            ConfiguredView(key: key)
        } else {
            ProgressView("Loading…")
        }
    }
}
```

``AppAttestClient`` is `@Observable @MainActor`. SwiftUI re-renders any
view that reads `secrets` or ``AppAttestClient/state`` when either
changes. Pre-sync, `secrets[key]` returns `nil`; once the sync resolves,
every registered key is present.

## Awaiting readiness in a bootstrap

If you need a secret synchronously for an early-boot configuration
(e.g. wiring your API client with a key), `await` the sync:

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

## Gating UI on lifecycle state

For richer UX (subscription / credits / service-incident handling), drive
your scene off ``AppAttestClient/state``:

```swift
struct RootView: View {
    @Environment(AppAttestClient.self) private var attest

    var body: some View {
        switch attest.state {
        case .ready:                            MainView()
        case .subscriptionRequired(let err):    SubscribeNoticeView(error: err)
        case .creditsRequired(let err):         TopUpNoticeView(error: err)
        case .unavailable(let err):             RetryView(error: err) { AppAttest.retry() }
        case .initializing, .attesting, .syncing: SplashView()
        }
    }
}
```

See <doc:ErrorHandling> for the full state-and-error model.
