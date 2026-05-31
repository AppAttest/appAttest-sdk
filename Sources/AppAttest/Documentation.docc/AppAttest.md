#  ``AppAttest``

Zero-config Swift SDK for AppAttest.

## Overview

AppAttest delivers API keys and other app secrets to your iOS and macOS
binaries, gated on Apple's App Attest so only a real build of your real app
can read them. No client IDs. No SDK tokens. One call at app start:

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

Bundle ID and Apple Team ID come from the running process. The SDK handles
key generation, attestation, token refresh, Keychain storage, and the
background sync. ``AppAttest/secrets`` is a synchronous in-memory dict
lookup with no network path; ``AppAttestClient`` is `@Observable @MainActor`
so SwiftUI re-renders any view that reads `secrets` or
``AppAttestClient/state`` when either changes.

## Topics

### Essentials

- ``AppAttestClient``
- ``AppAttestError``

### Modes and configuration

- ``DebugMode``
- ``APIConfiguration``

### Guides

- <doc:GettingStarted>
- <doc:DebugModes>
- <doc:ReleaseSafety>
- <doc:ErrorHandling>
