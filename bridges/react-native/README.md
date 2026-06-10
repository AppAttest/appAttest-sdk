# @appattest/react-native

React Native bridge for [AppAttest](https://www.appattest.dev) — App-Attest-gated
secret delivery for iOS.

> **Status: pre-release.** Ships in lockstep with the Swift SDK at
> `v0.1.0`. Not yet published to npm.
> The JS/TS API shape is stable.

## Platform support

- **iOS 14+** — full support. Uses Apple's `DCAppAttestService`.
- **Android / other** — not supported. Apple's App Attest is iOS-only and
  there is no equivalent on other platforms. Calls on other runtimes
  throw `AppAttestError` with code `"attestation_unsupported"`.

## Install

> Not yet on npm — publication is upcoming. Until then the bridge ships as
> source in `bridges/react-native` of the SDK repository. Once published:

```bash
npm install @appattest/react-native
cd ios && pod install
```

The iOS pod depends on `AppAttestObjC` (a companion pod from the same
monorepo). That's wired automatically through the pod's `s.dependency`.

## Quick start

```ts
import { AppAttest } from '@appattest/react-native';

// On app launch:
await AppAttest.attest();
await AppAttest.sync();

// Later, anywhere:
const openaiKey = await AppAttest.secret('OPENAI_API_KEY');
```

`attest()` registers the device once (persists across launches).
`sync()` pulls every secret for this app's environment.
`secret(name)` reads from the local Keychain cache — no network.

## Rotation

On app foreground, or whenever you want to pick up a rotated secret:

```ts
await AppAttest.refreshIfStale();
// hits GET /v1/secrets/fingerprint; re-syncs only if the env changed
```

Returns `true` if a re-sync happened.

## Error handling

All methods reject with `AppAttestError`:

```ts
import { AppAttest, AppAttestError, ErrorCode } from '@appattest/react-native';

try {
  await AppAttest.attest();
} catch (err) {
  if (err instanceof AppAttestError) {
    switch (err.code) {
      case ErrorCode.SubscriptionRequired:
        // show a "subscribe to go live" prompt
        break;
      case ErrorCode.AttestationUnsupported:
        // older device or missing entitlement — degrade gracefully
        break;
      case ErrorCode.RateLimited:
        // back off and retry
        break;
    }
  }
}
```

Full list of codes in the `ErrorCode` export. Recovery patterns match
the Swift SDK's error-handling documentation.

## Debug modes

The iOS simulator cannot produce a real App Attest attestation. Use
`sandbox` (network, no Apple attestation) or `local` (no network, inline
stubs) for dev:

```ts
if (__DEV__) {
  await AppAttest.setDebugMode('sandbox');
  // or:
  await AppAttest.setDebugMode('local', {
    OPENAI_API_KEY: 'sk-test-xxx',
  });
}
```

In a Release build of your app, `sandbox` and `local` reject at runtime
with `AppAttestError(code: 'debug_mode_release_blocked')`. The native
SDK strips those modes at compile time; the JS shim adds a second-layer
runtime guard that looks at whether the native framework was compiled
under `#if DEBUG`.

## Configuration

### Info.plist

| Key | Required | Purpose |
|-----|----------|---------|
| `CFBundleIdentifier` | yes | read by the SDK to identify your app |
| `APPATTEST_TEAM_ID` | fallback | use when the SDK can't auto-detect your Team ID |
| `APPATTEST_ENVIRONMENT` | yes for non-production | `"production"` or `"development"` — must match the app's `appattest-environment` entitlement |

### Entitlement

Add `com.apple.developer.devicecheck.appattest-environment` to your
Xcode target's `.entitlements` file. Value:
- `development` for debug builds — register your bundle under the
  `development` env in the AppAttest dashboard.
- `production` for App Store builds — register under `production`.

## Metering

Only `environment=production` attestations count toward billable plan
meters. Dev-environment attestations are tracked separately in sandbox
counters for visibility but **never billed**.

## Troubleshooting

| Error code | Likely cause |
|---|---|
| `team_id_unavailable` | Xcode didn't bake a Team ID into the build. Re-set the Team in Signing & Capabilities. |
| `unknown_app` | Your bundle isn't registered in the dashboard, or under the wrong env. |
| `attestation_unsupported` | Running on simulator (use `sandbox` mode) or older device. |
| `verification_failed` | Entitlement's `appattest-environment` doesn't match what the API expects. |

## Reference app

A minimal reference RN app lives at `example/` in the same repo. It
exercises `attest → sync → secret` end-to-end.

## License

MIT. See the [LICENSE](../../LICENSE) at the monorepo root.
