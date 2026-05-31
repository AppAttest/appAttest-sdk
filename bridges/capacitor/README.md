# @appattest/capacitor

Capacitor bridge for [AppAttest](https://www.appattest.dev) — App-Attest-gated
secret delivery for iOS.

> **Status: pre-release.** Ships in lockstep with the Swift SDK at
> `v0.1.0`. Not yet published to npm.

## Platform support

- **iOS 14+** — full support. Uses Apple's `DCAppAttestService`.
- **Web** — not supported. Calls throw `AppAttestError` with code
  `attestation_unsupported`. There's no equivalent platform guarantee
  on web.
- **Android** — not supported (App Attest is iOS-only).

Capacitor 6 and 7 are both supported (peer-dep `^6 || ^7`).

## Install

```bash
npm install @appattest/capacitor
npx cap sync
```

## Quick start

```ts
import { AppAttest } from '@appattest/capacitor';

// On app launch:
await AppAttest.attest();
await AppAttest.sync();

// Later, anywhere:
const openaiKey = await AppAttest.secret('OPENAI_API_KEY');
```

## Rotation

```ts
// On app resume, or whenever you want to pick up a rotated secret:
await AppAttest.refreshIfStale();
```

Live rotation events:

```ts
const handle = await AppAttest.onRotation((changedNames) => {
  console.log('secrets rotated:', changedNames);
});
// cancel later:
await handle.remove();
```

## Error handling

```ts
import { AppAttest, AppAttestError, ErrorCode } from '@appattest/capacitor';

try {
  await AppAttest.attest();
} catch (err) {
  if (err instanceof AppAttestError) {
    switch (err.code) {
      case ErrorCode.AttestationUnsupported:
        // running on web, or older device; degrade gracefully
        break;
      case ErrorCode.SubscriptionRequired:
        // show "subscribe to go live" prompt
        break;
      case ErrorCode.RateLimited:
        // back off
        break;
    }
  }
}
```

## Debug modes

The iOS simulator cannot produce a real App Attest attestation. Use
`sandbox` (network, no Apple attestation) or `local` (no network, inline
stubs) for dev:

```ts
if (import.meta.env.DEV) {
  await AppAttest.setDebugMode('sandbox');
  // or:
  await AppAttest.setDebugMode('local', {
    OPENAI_API_KEY: 'sk-test-xxx',
  });
}
```

Native Release builds reject `sandbox` / `local` with
`AppAttestError(code: 'debug_mode_release_blocked')`.

## Configuration

### Info.plist

| Key | Required | Purpose |
|-----|----------|---------|
| `CFBundleIdentifier` | yes | read by the SDK to identify your app |
| `APPATTEST_TEAM_ID` | fallback | use when the SDK can't auto-detect your Team ID |
| `APPATTEST_ENVIRONMENT` | yes for non-production | `"production"` or `"development"` — must match the app's `appattest-environment` entitlement |

### Entitlement

Add `com.apple.developer.devicecheck.appattest-environment` to your
iOS target's `.entitlements` file. Value `development` for debug builds,
`production` for App Store builds. In Xcode: **+ Capability → App Attest**.

## Reference app

A minimal reference Capacitor app lives at `example/` in the same repo.
It exercises the full attest → sync → secret → refresh → rotation flow
end-to-end.

## Metering

Only `environment=production` attestations count toward billable plan
meters. Dev-environment attestations are tracked separately in sandbox
counters but **never billed**.

## License

MIT. See [LICENSE](../../LICENSE) at the monorepo root.
