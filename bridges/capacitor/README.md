# @appattest/capacitor

Capacitor bridge for [AppAttest](https://www.appattest.dev) — App-Attest-gated
secret delivery for iOS.

> **Status: pre-release.** Ships in lockstep with the Swift SDK at
> `v0.1.0`. Not yet published to npm.

## Platform support

- **iOS 17+** — full support. Uses Apple's `DCAppAttestService` via the
  native AppAttest Swift SDK.
- **Web** — not supported. Calls throw `AppAttestError` with code
  `attestation_rejected` (there's no equivalent platform guarantee on web).
- **Android** — not supported (App Attest is iOS-only).

Capacitor 6 and 7 are both supported (peer-dep `^6 || ^7`).

## Install

> Not yet on npm — publication is upcoming. Until then the bridge ships as
> source in `bridges/capacitor` of the SDK repository. Once published:

```bash
npm install @appattest/capacitor
npx cap sync
```

The iOS pod depends on `AppAttestObjC` (a companion pod from the same
monorepo), wired automatically through the pod's `s.dependency`.

## Quick start

```ts
import { AppAttest } from '@appattest/capacitor';

// Once, at app launch:
AppAttest.start();

// Anywhere:
await AppAttest.waitForReady();
const key = await AppAttest.getSecret('OPENAI_API_KEY'); // string | null
const all = await AppAttest.getAllSecrets();             // Record<string, string>
```

`start()` is fire-and-forget: the first launch attests the device once
(persists across launches), then syncs secrets; later launches hydrate
from the Keychain and re-sync in the background. Foreground re-entry
re-syncs automatically — your app does no lifecycle wiring.

## State

```ts
const s = await AppAttest.getState(); // { name, error? }

const handle = await AppAttest.addStateListener((s) => console.log(s.name));
// later: handle.remove();  — or drop everything:
await AppAttest.removeAllListeners();
```

`state.name` is one of `'initializing' | 'attesting' | 'syncing' | 'ready' |
'subscription_required' | 'credits_required' | 'unavailable'`. The
non-`ready` terminal states carry `state.error`.

**End-user-facing apps:** show a generic "temporarily unavailable" notice
for the non-`ready` terminal states. **Developer / staff builds:** log the
full error (including `actionUrl`) so the developer knows whether to
subscribe, top up, or investigate.

## Refresh & recovery

```ts
await AppAttest.retry();            // re-run the sync (no re-attestation)
await AppAttest.invalidateBundle(); // drop the cached bundle, force a fresh sync
await AppAttest.reset();            // full wipe; next start() re-attests
```

`retry()` recovers from transient failures. `invalidateBundle()` forces
fresh secret bytes when you don't want to wait for the next rotation
pickup. `reset()` is the nuclear option, for sign-out / data-clearing flows.

## Debug mode (simulator, tests, CI)

The simulator can't produce a real App Attest attestation. Use local stubs:

```ts
if (process.env.NODE_ENV !== 'production') {
  await AppAttest.setDebugMode('local', {
    OPENAI_API_KEY: 'sk-test-stub',
  });
}
AppAttest.start();
```

Pass `null` to return to real attestation. The native debug surface is
`#if DEBUG`-gated — physically absent from Release builds, which always
run real attestation; calling it there rejects with
`debug_mode_release_blocked`.

Dev builds on **real devices** don't need debug mode — they attest for
real and read the sandbox bucket (below).

## Buckets (sandbox vs production)

There is no environment configuration. Apple's AAGUID in each attestation
determines the bucket server-side: dev / TestFlight builds read the
**sandbox** secrets column; App Store builds read **production**. Same
code in both, no flags.

## Error handling

All methods reject with `AppAttestError` (`code`, plus `subscribeUrl` /
`topupUrl` / `actionUrl` on the billing cases):

```ts
import { AppAttest, AppAttestError, ErrorCode } from '@appattest/capacitor';

try {
  await AppAttest.waitForReady();
} catch (e) {
  if (e instanceof AppAttestError && e.code === ErrorCode.SubscriptionRequired) {
    console.log('project needs a subscription:', e.actionUrl);
  }
}
```

| Code | Meaning |
|------|---------|
| `subscription_required` | Project subscription not active (`subscribeUrl`). |
| `credits_required` | Allowance exhausted and balance empty (`topupUrl`). |
| `attestation_rejected` | Apple or AppAttest rejected this install (also thrown on web) — terminal until reinstall. |
| `service_unavailable` | Temporary service condition; retryable (the SDK backs off automatically). |
| `network` | Device-side transport failure; retryable. |
| `debug_mode_release_blocked` | `setDebugMode` called in a Release build. |
| `invalid_argument` | Malformed call input. |

## License

MIT © 2026 Bault LLC. See [LICENSE](LICENSE).
