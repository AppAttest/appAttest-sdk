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
