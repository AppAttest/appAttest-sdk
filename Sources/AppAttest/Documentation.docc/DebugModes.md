# Debug Modes

How to develop against AppAttest in environments where Apple's App Attest
isn't available (the simulator, SwiftUI previews, CI runners).

## Overview

Real-device builds produce real App Attest attestations and are **metered**
against a server bucket — no special debug mode needed. The only debug mode
that exists is ``DebugMode/local(stubs:)``, for environments where Apple's App
Attest service literally isn't reachable (the simulator, SwiftUI previews, CI).

| Mode | Network | Attestation | Bucket |
|------|---------|-------------|--------|
| (default — unset), Debug build | yes | real Apple App Attest | staging (metered) |
| (default — unset), Release build | yes | real Apple App Attest | ``AppAttest/release`` (default `.production`, metered) |
| ``DebugMode/local(stubs:)`` (Debug only) | no | none | inline dictionary (free) |

``DebugMode/local(stubs:)`` is `#if DEBUG`-stripped in Release builds, so
neither the case nor the setter can leak into a shipped binary — a Release
binary has no offline path and always attests + meters.

Set the mode before ``AppAttestClient/start()``:

```swift
#if DEBUG
AppAttestClient.shared.debug = .local(stubs: [
    "OPENAI_API_KEY": "sk-test-xxx",
    "STRIPE_PUBLISHABLE_KEY": "pk_test_xxx"
])
#endif
AppAttest.start()
```

## Default (real attestation)

The default. On a real iPhone (or iPad / Vision Pro), the SDK calls
`/v1/attest/{challenge,register,assert}` with a real attestation object
signed by the Apple Secure Enclave. The SDK **declares** its desired bucket
(a Debug build → `staging`; a Release build → ``AppAttest/release``, default
`.production`); edge resolves it against Apple's AAGUID and serves the matching
secret set. Both buckets are metered.

Apple's AAGUID is a **build-time** property, not a distribution-type one:

- A development-signed build (Xcode → device) attests with the **development**
  AAGUID → may reach only the **staging** bucket.
- A distribution build (TestFlight, ad-hoc, Enterprise) that lacks the
  `com.apple.developer.devicecheck.appattest-environment=production` entitlement
  ALSO attests with the development AAGUID → staging bucket.
- Only a build carrying that production entitlement attests with the
  **production** AAGUID and may reach the **production** bucket.

So a Release build defaulting to `.production` that ships **without** the
production entitlement is rejected at attestation with `403 bucket_not_permitted`
(surfaced as ``AppAttestError/attestationRejected(reason:)``): the reason names
the fix — add the entitlement, or set ``AppAttest/release`` to `.staging`.

### Choosing the Release bucket

```swift
// Optional — the default is .production.
AppAttest.release = .staging   // point a pre-ship build at the staging bucket
AppAttest.start()
```

`.staging` and `.production` are two functionally-identical, separately-keyed,
**metered** buckets. `.staging` lets a team verify end to end against a
non-production secret set before flipping to `.production`. Neither is free —
the only free path is ``DebugMode/local(stubs:)`` (Debug only). No code change
is required between development and production: the same `start()` declares the
right bucket based on the build.

## Local (stubs)

No network. `secrets` returns whatever you pass in. Use for SwiftUI
previews, simulator runs, unit tests, and CI runners that can't reach
the service.

```swift
#if DEBUG
AppAttestClient.shared.debug = .local(stubs: [
    "OPENAI_API_KEY": "sk-test-xxx"
])
AppAttest.start()
print(AppAttest.secrets["OPENAI_API_KEY"])  // "sk-test-xxx"
#endif
```

`.local` does not touch the Keychain, does not call ``AppContext``, and
does not require an internet connection — safe to run in any host,
including Linux Swift build environments and CI sandboxes.

## What about a `.sandbox` mode?

Earlier versions had a `.sandbox` case that synthesized a fake attestation
to drive the staging bucket on the simulator. It was removed because:

- Real development-signed builds on real devices already produce real
  attestations resolved to the staging bucket. The synthesized path was
  redundant for the canonical workflow.
- The synthesized path required AppAttest to accept tokens with no real
  cryptographic proof — that was an escape hatch that shouldn't have
  existed in the SDK at all.
- For genuinely device-physics-blocked environments (simulator, previews,
  CI), ``DebugMode/local(stubs:)`` is the right tool — it doesn't even
  touch the network.
