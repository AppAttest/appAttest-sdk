# Debug Modes

How to develop against AppAttest in environments where Apple's App Attest
isn't available (the simulator, SwiftUI previews, CI runners).

## Overview

Dev and TestFlight builds on real devices produce real App Attest
attestations and read the Sandbox secrets column — no special debug
mode needed. The only debug mode that exists is ``DebugMode/local(stubs:)``,
for environments where Apple's App Attest service literally isn't reachable.

| Mode | Network | Attestation | Reads from |
|------|---------|-------------|------------|
| (default — unset) | yes | real Apple App Attest | sandbox or production column, per AAGUID |
| ``DebugMode/local(stubs:)`` | no | none | inline dictionary |

`#if DEBUG`-stripped in Release builds, so neither the case nor the
setter can leak into a shipped binary.

Set the mode before ``AppAttestClient/start()``:

```swift
#if DEBUG
AppAttestClient.shared.debugMode = .local(stubs: [
    "OPENAI_API_KEY": "sk-test-xxx",
    "STRIPE_PUBLISHABLE_KEY": "pk_test_xxx"
])
#endif
AppAttest.start()
```

## Default (real attestation)

The default. On a real iPhone (or iPad / Vision Pro), the SDK calls
`/v1/attest/{challenge,register,assert}` with a real attestation object
signed by the Apple Secure Enclave. Apple's AAGUID inside the attestation
determines which column the SDK reads from: dev/TestFlight builds →
sandbox, App Store builds → production.

No code change between development and production. The same `start()`
reads the right secrets based on the build context.

## Local (stubs)

No network. `secrets` returns whatever you pass in. Use for SwiftUI
previews, simulator runs, unit tests, and CI runners that can't reach
the service.

```swift
#if DEBUG
AppAttestClient.shared.debugMode = .local(stubs: [
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
to drive the sandbox column on the simulator. It was removed because:

- Real dev/TestFlight builds on real devices already produce real
  attestations against the sandbox column. The synthesized path was
  redundant for the canonical workflow.
- The synthesized path required AppAttest to accept tokens with no real
  cryptographic proof — that was an escape hatch that shouldn't have
  existed in the SDK at all.
- For genuinely device-physics-blocked environments (simulator, previews,
  CI), ``DebugMode/local(stubs:)`` is the right tool — it doesn't even
  touch the network.
