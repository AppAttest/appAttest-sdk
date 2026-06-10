# appattest_flutter

Flutter bridge for [AppAttest](https://www.appattest.dev) — App-Attest-gated
secret delivery for iOS.

> **Status: pre-release.** Ships in lockstep with the Swift SDK at
> `v0.1.0`. Not yet published to pub.dev.

## Platform support

- **iOS 14+** — full support. Uses Apple's `DCAppAttestService`.
- **Android / other** — not supported. App Attest is iOS-only. Any call
  on another platform throws an `AppAttestError` with code
  `attestation_unsupported`.

## Install

> Not yet on pub.dev — publication is upcoming. Until then the bridge ships
> as source in `bridges/flutter` of the SDK repository. Once published:

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

## Quick start

```dart
import 'package:appattest_flutter/appattest_flutter.dart';

// On app launch:
await AppAttest.attest();
await AppAttest.sync();

// Later, anywhere:
final openaiKey = await AppAttest.secret('OPENAI_API_KEY');
```

`attest()` registers the device once (persists across launches).
`sync()` pulls every secret for this app's environment.
`secret(name)` reads from the local Keychain cache — no network.

## Rotation

On app foreground or whenever you want to pick up a rotated secret:

```dart
await AppAttest.refreshIfStale();
// hits GET /v1/secrets/fingerprint; re-syncs only if the env changed
```

Returns `true` if a re-sync happened.

Live rotation events (for in-app UI updates):

```dart
final subscription = AppAttest.onRotation.listen((changedNames) {
  debugPrint('secrets rotated: $changedNames');
});
// remember to cancel on dispose
```

## Error handling

All methods throw `AppAttestError`:

```dart
try {
  await AppAttest.attest();
} on AppAttestError catch (err) {
  switch (err.code) {
    case ErrorCode.subscriptionRequired:
      // show "subscribe to go live" prompt
      break;
    case ErrorCode.attestationUnsupported:
      // older device or missing entitlement — degrade gracefully
      break;
    case ErrorCode.rateLimited:
      // back off and retry
      break;
  }
}
```

Full list of codes in the `ErrorCode` class.

## Debug modes

The iOS simulator cannot produce a real App Attest attestation. Use
`sandbox` (network, no Apple attestation) or `local` (no network, inline
stubs) for dev:

```dart
if (kDebugMode) {
  await AppAttest.setDebugMode(DebugMode.sandbox);
  // or:
  await AppAttest.setDebugMode(DebugMode.local, {
    'OPENAI_API_KEY': 'sk-test-xxx',
  });
}
```

In a Release build of your app, `sandbox` and `local` throw
`AppAttestError(code: ErrorCode.debugModeReleaseBlocked)`. The native
SDK strips those modes at compile time; the Dart → Swift boundary adds
a second-layer runtime guard.

## Configuration

### Info.plist

| Key | Required | Purpose |
|-----|----------|---------|
| `CFBundleIdentifier` | yes | read by the SDK to identify your app |
| `APPATTEST_TEAM_ID` | fallback | use when the SDK can't auto-detect your Team ID |
| `APPATTEST_ENVIRONMENT` | yes for non-production | `"production"` or `"development"` — must match the app's `appattest-environment` entitlement |

### Entitlement

Add `com.apple.developer.devicecheck.appattest-environment` to your
iOS target's `.entitlements` file. Value:
- `development` for debug builds — register your bundle under the
  `development` env in the AppAttest dashboard.
- `production` for App Store builds — register under `production`.

## Regenerating the Pigeon bindings

The Dart ↔ Swift boundary is generated from
`pigeons/messages.dart` by [Pigeon](https://pub.dev/packages/pigeon).

```bash
dart run pigeon --input pigeons/messages.dart
```

Outputs:
- `lib/src/messages.g.dart`
- `ios/Classes/Messages.g.swift`

Both generated files are checked in. Edit the contract in
`pigeons/messages.dart` and regenerate — don't hand-edit the generated
files.

## Metering

Only `environment=production` attestations count toward billable plan
meters. Dev-environment attestations are tracked separately in sandbox
counters for visibility but **never billed**.

## License

MIT. See [LICENSE](../../LICENSE) at the monorepo root.
