// Pigeon contract for the AppAttest Flutter plugin.
//
// Generate the bindings with:
//
//     dart run pigeon --input pigeons/messages.dart
//
// Output (checked into source control):
//   - lib/src/messages.g.dart       — generated Dart host API client
//   - ios/Classes/Messages.g.swift  — generated Swift host API protocol
//
// Do not hand-edit the generated files. Change this spec, regenerate.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartPackageName: 'appattest_flutter',
    swiftOut: 'ios/Classes/Messages.g.swift',
    swiftOptions: SwiftOptions(errorClassName: 'AppAttestFlutterError'),
  ),
)

/// State snapshot returned to Dart. The Dart-side enum mapping happens
/// in `appattest_flutter.dart`; this class is the wire shape only.
class AppAttestStatePayload {
  AppAttestStatePayload({
    required this.name,
    this.errorCode,
    this.errorMessage,
    this.errorSubscribeUrl,
    this.errorTopupUrl,
  });
  final String name;
  final String? errorCode;
  final String? errorMessage;
  /// `subscription_required` only.
  final String? errorSubscribeUrl;
  /// `credits_required` only.
  final String? errorTopupUrl;
}

/// Host API — methods implemented natively in `AppAttestPlugin.swift` and
/// called from Dart via the generated `AppAttestHostApi`.
@HostApi()
abstract class AppAttestHostApi {
  /// Synchronous, idempotent setup. Zero-argument (bucket is
  /// AAGUID-derived server-side).
  @async
  void start();

  /// Awaits a terminal state. Resolves on `ready`; throws on
  /// subscriptionRequired / creditsRequired / unavailable.
  @async
  void waitForReady();

  /// Re-runs the background sync.
  @async
  void retry();

  /// Wipes stored credentials and secrets.
  @async
  void reset();

  /// Invalidate the cached secrets bundle and immediately sync. Keeps
  /// attestation credentials; forces a 200 (1 credit on production).
  /// Use for "force refresh" / "sync now" UX.
  @async
  void invalidateBundle();

  /// Synchronous-feeling secret lookup. Returns `null` if not yet
  /// synced or absent.
  @async
  String? getSecret(String name);

  /// Snapshot of every synced secret as `{ name: value }`.
  @async
  Map<String, String> getAllSecrets();

  /// Current state snapshot.
  @async
  AppAttestStatePayload getState();

  /// Set runtime mode. `null`/`"production"` for production;
  /// `"local"` for DEBUG-only previews/simulator. `"sandbox"`
  /// is not valid (use a real dev/TestFlight build).
  @async
  void setDebugMode(String? name, Map<String, String>? stubs);

  // setApiBaseUrl is not exposed — base URL hardcoded in Swift SDK.
}
