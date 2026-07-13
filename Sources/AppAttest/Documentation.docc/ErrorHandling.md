# Error Handling

Recover from the failures the SDK actually surfaces.

## Overview

``AppAttestError`` is a flat enum with five cases.
Errors don't usually reach you directly — the SDK funnels them into
``AppAttestClient/state`` so SwiftUI views can switch on the lifecycle
state and pick the right UI without try/catch plumbing.

```swift
switch AppAttestClient.shared.state {
case .ready:                            MainView()
case .subscriptionRequired(let e):      SubscribeNoticeView(error: e)
case .creditsRequired(let e):           TopUpNoticeView(error: e)
case .unavailable(let e):               RetryView(error: e) { AppAttest.retry() }
case .initializing, .attesting, .syncing: SplashView()
}
```

If you'd rather use exceptions, ``AppAttest/waitForReady()`` throws the
same ``AppAttestError``.

Two more conditions surface *outside* `state`, because neither should fail
a sync: a non-fatal **persistence-degraded** signal and a **secret-key
lookup** helper for catching typos (both covered below). Both are separate
from the ``AppAttestError`` family.

## The 402 family

These two states fire when AppAttest returns a 402 with the matching code.
Each carries a ``URL`` you should open in the developer's browser; opening
it leads to the right next step in the AppAttest dashboard.

`subscriptionRequired(subscribeUrl:)` — the project's
subscription is not active (never subscribed, or suspended). Lands as
`state = .subscriptionRequired(_)`. Open `subscribeUrl` to restart
billing. Subscribing is also "go-live" — once active, the project starts
receiving production traffic on its next sync.

`creditsRequired(topupUrl:)` — subscribed, but the cycle
allowance is exhausted AND the prepaid balance is zero. Lands as
`state = .creditsRequired(_)`. Open `topupUrl` to add funds, or wait for
next cycle.

## Attestation rejection

`attestationRejected(reason:)` — Apple's `DCAppAttestService` failed,
*or* AppAttest rejected the attestation object (cert chain, nonce, rpId,
signature, counter). Lands as `state = .unavailable(_)`. **Terminal for
this install** — the device's App Attest key is rejected; reinstalling
the app reseeds the key. ``AppAttest/retry()`` will not recover this.

> Note: One specific failure mode — Apple's `DCError.invalidKey` on a
> stored `keyId` that the Secure Enclave no longer recognizes (common
> after app reinstall or device restore-from-backup, since iOS Keychain
> entries survive both but enclave keys do not) — is handled
> transparently by the SDK. The SDK wipes the stale credential and
> re-attests once, in-process. Host apps do not need to handle this
> case explicitly; it does not surface as `.unavailable`. See the
> `523f279` commit on `AppAttest/sdk` for the self-heal path.

## Service unavailable

`serviceUnavailable(reason:)` — AppAttest is temporarily unable to
serve (transient service incident or maintenance). **Retryable.** SDK
auto-retries with backoff; cached secrets keep serving last-known
values from the Keychain.

The `reason` string is drawn from a documented abstract set:
`temporarily_unavailable` (default — transient incident),
`retry_after_delay` (paired with a `Retry-After` hint),
`service_paused` (planned maintenance). Anything outside that set
collapses to `temporarily_unavailable` at the SDK boundary so internal
infrastructure terms never leak into your error logs.

## Network

`network(underlying:)` — every other transport, decoding, or keychain
failure. Lands as `state = .unavailable(_)`. **Retryable.**
``AppAttest/retry()`` re-runs the sync; cached secrets keep serving.

The `underlying` value preserves the original error — `URLSession`'s
`NSError`, a decoding failure, or an internal `ServerError` for
non-modelled HTTP statuses. Cast and inspect for diagnostics.

## Persistence degraded (non-fatal)

The SDK caches its synced secrets and attestation credentials in the
Keychain. When a cache read or write fails, the *current* session is still
fully functional — the secrets are already in memory — so the SDK does
**not** fail the sync or touch ``AppAttestClient/state``. Instead it raises
a separate, non-fatal signal you can observe.

- ``AppAttest/persistenceDegraded`` — `Bool`, observable. `true` when the
  most recent Keychain read/write failed. Clears automatically after the
  next successful cache write.
- ``AppAttest/lastPersistenceError`` — the most recent
  ``PersistenceError``, or `nil` if the last write succeeded.
- ``AppAttest/onPersistenceIssue`` — an optional sink fired on the main
  actor for *every* failure as it happens (the two properties above give
  the current state; the sink gives the full stream). Set it before
  ``AppAttest/start()``.

``PersistenceError`` carries no secret material — only the
``PersistenceError/artifact`` (`.secrets` / `.credentials`), the
``PersistenceError/operation`` (`.save` / `.delete` / `.load`), and the
underlying ``PersistenceError/osStatus`` (a Security-framework `OSStatus`).

Inspect ``PersistenceError/isCreditImpacting`` for severity: `true` when
the failure forces avoidable re-work on next launch. A dropped secrets
cache means the next launch can't send a fingerprint, so AppAttest returns
a full bundle (a 200) instead of a 304 — **and a re-sync consumes one
credit.** `delete` failures are never credit-impacting.

```swift
@main
struct MyApp: App {
    init() {
        // Forward every persistence failure to your telemetry. The sink
        // runs on the main actor.
        AppAttest.onPersistenceIssue = { error in
            logger.warning("AppAttest cache degraded: \(error)")
        }
        AppAttest.start()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

Because it's observable, you can also surface the *current* condition in a
developer / staff build — for example a debug overlay:

```swift
if AppAttest.persistenceDegraded {
    Label("Secret cache degraded", systemImage: "exclamationmark.triangle")
}
```

Surface this in developer / staff builds only; end users can't act on it.
When it fires, investigate the Keychain entitlement or the device state
(e.g. a locked device before its first unlock).

## Unknown secret keys

A bare `secrets[key]` returns `nil` in two very different situations: the
first sync hasn't finished, or the key is genuinely absent (a typo, or
never registered in the dashboard). That ambiguity is a *programmer error*
waiting to bite — distinct from the runtime ``AppAttestError`` family
above, and fixable at the call site.

``AppAttest/secret(_:)`` disambiguates by returning a
``AppAttestClient/SecretLookup`` instead of an optional:

```swift
switch AppAttest.secret("BACKEND_KEY") {
case .value(let token):
    APIClient.configure(token: token)
case .notReady:
    // Sync still in flight — the key may still appear. Check again once
    // state == .ready.
    break
case .absent(let available):
    // state == .ready, but this key is genuinely not in the synced set.
    // `available` lists the keys that ARE present — scan it for a typo or
    // a dashboard-registration mismatch.
    assertionFailure("BACKEND_KEY not registered. Synced keys: \(available)")
}
```

In DEBUG builds an `.absent` result while `.ready` also emits an OSLog
`.fault` naming the missing key and the available set (deduped — each
unknown key logs once per synced key-set), so a typo shows up in the
console the first time you hit it. Release builds are silent and
allocation-free on this path; the disambiguating return value is available
in every build.

Use ``AppAttest/availableKeys`` (sorted, thread-safe) to validate the keys
you expect at boot:

```swift
let expected: Set<String> = ["BACKEND_KEY", "OPENAI_API_KEY"]
let missing = expected.subtracting(AppAttest.availableKeys)
if !missing.isEmpty { assertionFailure("Unregistered keys: \(missing)") }
```

## Reading secrets: reactive vs imperative

There are two ways to read a secret, and picking the wrong one either
misses SwiftUI updates or pays a needless actor hop. They read the same
in-memory bytes from a single source of truth, so they never disagree:

| Read | Isolation | Re-renders SwiftUI? | Use for |
|---|---|---|---|
| ``AppAttest/secrets`` | `@MainActor` | **Yes** (observed) | SwiftUI view bodies — the reactive path. |
| ``AppAttest/currentSecret(_:)`` | `nonisolated` | No | A single key off the main actor — the signing-closure hot path. |
| ``AppAttest/currentSecrets`` | `nonisolated` | No | A full thread-safe snapshot for imperative code. |
| ``AppAttest/secret(_:)`` | `nonisolated` | No | Disambiguating lookup (`.value` / `.notReady` / `.absent`). |

**In a SwiftUI body, read ``AppAttest/secrets``** (or bind
``AppAttestClient`` via `.environment`). It's observed, so the view
re-renders when the sync resolves. The `nonisolated` reads are **not**
observation-tracked by design — a view that reads only `currentSecret(_:)`
won't re-render when secrets arrive.

**Off the main actor — a signing or networking closure — read
``AppAttest/currentSecret(_:)``.** It's `nonisolated`, so there's no
`await` hop and no need to bounce onto the main actor to build a request:

```swift
// A request signer invoked on a background queue, never the main actor.
// `currentSecret(_:)` is `nonisolated` — no `await`, no MainActor hop.
let signRequest: @Sendable (inout URLRequest) -> Void = { request in
    if let token = AppAttest.currentSecret("BACKEND_KEY") {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}
```

Reading `AppAttest.secrets` in that closure would instead force an
`await MainActor.run { … }` on every call, for the same bytes. When you
also need to tell "not synced yet" from "absent" off-main, reach for
``AppAttest/secret(_:)`` — it's `nonisolated` too.

## Recommended UX patterns

**End-user-facing apps** — render a generic "service temporarily
unavailable, try again later" notice for the three non-`.ready`
terminal states (`.subscriptionRequired`, `.creditsRequired`,
`.unavailable`). Do not surface the specific reason (deep-link URL,
project id) to the end user — those are for the developer's logs /
admin flow.

**Developer / staff builds** — print the full `error` payload (including
the deep-link URL) so the developer immediately knows whether to
subscribe, top up, or investigate a service incident.

## A bootstrap-and-go pattern

```swift
@main
struct MyApp: App {
    init() { AppAttest.start() }

    var body: some Scene {
        WindowGroup {
            ContentView().environment(AppAttestClient.shared)
        }
    }
}

struct ContentView: View {
    @Environment(AppAttestClient.self) private var attest

    var body: some View {
        switch attest.state {
        case .ready:
            HomeView(apiKey: attest.secrets["OPENAI_API_KEY"])
        case .subscriptionRequired(let e):
            SubscribeNotice(url: e.actionUrl)
        case .creditsRequired(let e):
            TopUpNotice(url: e.actionUrl)
        case .unavailable(let e):
            switch e {
            case .attestationRejected:
                AttestationFailedView(error: e) // terminal; reinstall
            case .serviceUnavailable, .network:
                RetryView(error: e) { AppAttest.retry() }
            default:
                RetryView(error: e) { AppAttest.retry() }
            }
        case .initializing, .attesting, .syncing:
            ProgressView()
        }
    }
}
```

`AppAttest.secrets["KEY"]` is a synchronous lookup — no `await`, no
`try`. Pre-`.ready` it returns `nil`. The SDK populates the dictionary
once `state` reaches `.ready`, and SwiftUI re-renders automatically.
