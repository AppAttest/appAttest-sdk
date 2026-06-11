# appattest_flutter

Flutter bridge for [AppAttest](https://www.appattest.dev) — App-Attest-gated
secret delivery for iOS.

> Ships in lockstep with the Swift SDK (current: `v0.1.0`).

## Platform support

- **iOS 17+** — full support. Uses Apple's `DCAppAttestService` via the
  native AppAttest Swift SDK.
- **Android / other** — not supported. App Attest is iOS-only; the plugin
  registers no implementation on other platforms.

## Install

```yaml
# pubspec.yaml
dependencies:
  appattest_flutter: ^0.1.0
```

Then:

```bash
flutter pub get
cd ios && pod install && cd ..
```

The iOS side depends on the `AppAttest` pod (the core Swift SDK), wired
automatically through the plugin's podspec.

## Quick start

```dart
import 'package:appattest_flutter/appattest_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppAttest.start();
  runApp(const MyApp());
}
```

```dart
// Anywhere:
await AppAttest.waitForReady();
final key = await AppAttest.secret('OPENAI_API_KEY'); // String?
final all = await AppAttest.allSecrets();             // Map<String, String>
```

`start()` is fire-and-forget: the first launch attests the device once
(persists across launches), then syncs secrets; later launches hydrate
from the Keychain and re-sync in the background. Foreground re-entry
re-syncs automatically — your app does no lifecycle wiring.

## State

```dart
final s = await AppAttest.getState(); // AppAttestState(name, error?)

final sub = AppAttest.stateStream.listen((s) {
  debugPrint('appattest: ${s.name}');
});
// later: sub.cancel();
```

`AppAttestStateName`: `initializing`, `attesting`, `syncing`, `ready`,
`subscriptionRequired`, `creditsRequired`, `unavailable`. The non-`ready`
terminal states carry `state.error`.

**End-user-facing apps:** show a generic "temporarily unavailable" notice
for the non-`ready` terminal states. **Developer / staff builds:** log the
full error (including `actionUrl`) so the developer knows whether to
subscribe, top up, or investigate.

## Refresh & recovery

```dart
await AppAttest.retry();            // re-run the sync (no re-attestation)
await AppAttest.invalidateBundle(); // drop the cached bundle, force a fresh sync
await AppAttest.reset();            // full wipe; next start() re-attests
```

`retry()` recovers from transient failures. `invalidateBundle()` forces
fresh secret bytes when you don't want to wait for the next rotation
pickup. `reset()` is the nuclear option, for sign-out / data-clearing flows.

## Debug mode (simulator, tests, CI)

The simulator can't produce a real App Attest attestation. Use local stubs:

```dart
import 'package:flutter/foundation.dart';

if (kDebugMode) {
  await AppAttest.setDebugMode(DebugMode.local, {
    'OPENAI_API_KEY': 'sk-test-stub',
  });
}
AppAttest.start();
```

`DebugMode` has a single case, `local`; pass `null` to return to real
attestation. The native debug surface is `#if DEBUG`-gated — physically
absent from Release builds, which always run real attestation; calling it
there throws `debug_mode_release_blocked`.

Dev builds on **real devices** don't need debug mode — they attest for
real and read the sandbox bucket (below).

## Buckets (sandbox vs production)

There is no environment configuration. Apple's AAGUID in each attestation
determines the bucket server-side: dev / TestFlight builds read the
**sandbox** secrets column; App Store builds read **production**. Same
code in both, no flags.

## Error handling

Failures throw `AppAttestError` (`code` and `message`, plus `subscribeUrl` /
`topupUrl` / `actionUrl` on the billing cases):

```dart
try {
  await AppAttest.waitForReady();
} on AppAttestError catch (e) {
  if (e.code == ErrorCode.subscriptionRequired) {
    debugPrint('project needs a subscription: ${e.actionUrl}');
  }
}
```

| Code | Meaning |
|------|---------|
| `subscription_required` | Project subscription not active (`subscribeUrl`). |
| `credits_required` | Allowance exhausted and balance empty (`topupUrl`). |
| `attestation_rejected` | Apple or AppAttest rejected this install — terminal until reinstall. |
| `service_unavailable` | Temporary service condition; retryable (the SDK backs off automatically). |
| `network` | Device-side transport failure; retryable. |
| `debug_mode_release_blocked` | `setDebugMode` called in a Release build. |
| `invalid_argument` | Malformed call input. |

(Compare via the `ErrorCode` constants — `ErrorCode.subscriptionRequired`
etc.; the values are the snake_case strings above.)

## License

MIT © 2026 Bault LLC. See [LICENSE](LICENSE).
