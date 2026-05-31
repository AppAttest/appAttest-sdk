/// AppAttest — Flutter bridge for iOS-only App-Attest-gated secret delivery.
///
/// Public API mirrors the Swift surface translated for Dart:
///
/// ```dart
/// import 'package:appattest_flutter/appattest_flutter.dart';
///
/// AppAttest.start();
/// await AppAttest.waitForReady();
/// final key = await AppAttest.secret('OPENAI_API_KEY');
///
/// // Observe state transitions:
/// AppAttest.stateStream.listen((s) => print('state=${s.name}'));
/// ```
///
/// iOS-only — App Attest is not available on Android or web.
library appattest_flutter;

import 'dart:async';

import 'package:flutter/services.dart' show PlatformException, EventChannel;

import 'src/messages.g.dart';

/// Lifecycle state. Mirrors `AppAttestClient.State` on the native side.
enum AppAttestStateName {
  initializing,
  attesting,
  syncing,
  ready,
  subscriptionRequired,
  creditsRequired,
  unavailable,
}

class AppAttestState {
  AppAttestState({required this.name, this.error});
  final AppAttestStateName name;
  final AppAttestError? error;
}

/// Typed error surfaced by every method. [code] matches the Swift SDK's
/// `AppAttestError.code` one-for-one.
class AppAttestError implements Exception {
  AppAttestError({
    required this.code,
    required this.message,
    this.subscribeUrl,
    this.topupUrl,
  });

  final String code;
  final String message;
  /// `subscription_required` only — URL to (re)start the project subscription.
  final String? subscribeUrl;
  /// `credits_required` only — URL to top up the project balance.
  final String? topupUrl;

  /// Single accessor for the dashboard URL regardless of code.
  String? get actionUrl => subscribeUrl ?? topupUrl;

  @override
  String toString() => 'AppAttestError($code): $message';
}

/// Stable string codes. Match Swift `AppAttestError.code` one-for-one.
abstract class ErrorCode {
  static const subscriptionRequired = 'subscription_required';
  static const creditsRequired = 'credits_required';
  static const attestationRejected = 'attestation_rejected';
  static const serviceUnavailable = 'service_unavailable';
  static const network = 'network';
  static const debugModeReleaseBlocked = 'debug_mode_release_blocked';
  static const invalidArgument = 'invalid_argument';
}

/// Runtime mode. Pass `null` (or omit) for production. There is no
/// `sandbox` case — real dev/TestFlight builds produce real sandbox
/// attestations via Apple's AAGUID derivation. `local` is the only
/// debug mode (intended for SwiftUI previews and simulator testing).
enum DebugMode { local }

extension _DebugModeName on DebugMode {
  String get wireName => switch (this) {
        DebugMode.local => 'local',
      };
}

AppAttestStateName _parseStateName(String wire) => switch (wire) {
      'initializing' => AppAttestStateName.initializing,
      'attesting' => AppAttestStateName.attesting,
      'syncing' => AppAttestStateName.syncing,
      'ready' => AppAttestStateName.ready,
      'subscription_required' => AppAttestStateName.subscriptionRequired,
      'credits_required' => AppAttestStateName.creditsRequired,
      'unavailable' => AppAttestStateName.unavailable,
      _ => AppAttestStateName.unavailable,
    };

AppAttestState _decodeState(AppAttestStatePayload p) {
  AppAttestError? err;
  if (p.errorCode != null) {
    err = AppAttestError(
      code: p.errorCode!,
      message: p.errorMessage ?? '',
      subscribeUrl: p.errorSubscribeUrl,
      topupUrl: p.errorTopupUrl,
    );
  }
  return AppAttestState(name: _parseStateName(p.name), error: err);
}

/// Public client. Static-only namespace; no stateful Dart object.
class AppAttest {
  AppAttest._();

  static final AppAttestHostApi _host = AppAttestHostApi();

  static const EventChannel _stateChannel =
      EventChannel('dev.appattest.sdk/state');

  /// Synchronous, idempotent setup. Returns immediately; the SDK
  /// background-syncs without blocking the caller.
  ///
  /// Zero-argument. Apple's AAGUID determines the bucket
  /// (sandbox vs production) server-side; the SDK is bucket-blind.
  static Future<void> start() => _wrap(() => _host.start());

  /// Awaits a terminal state. Resolves on `ready`; throws
  /// `AppAttestError` on `subscriptionRequired` / `creditsRequired` /
  /// `unavailable`.
  static Future<void> waitForReady() => _wrap(_host.waitForReady);

  /// Re-runs the background sync.
  static Future<void> retry() => _wrap(_host.retry);

  /// Wipes stored credentials and secrets.
  static Future<void> reset() => _wrap(_host.reset);

  /// Invalidate the cached secrets bundle and immediately sync. Keeps
  /// attestation credentials; forces a 200 on the next sync (consumes
  /// 1 credit on the production bucket). Use for "force
  /// refresh" / "sync now" host-app UX.
  static Future<void> invalidateBundle() => _wrap(_host.invalidateBundle);

  /// Returns the secret for [name], or `null`.
  static Future<String?> secret(String name) =>
      _wrap(() => _host.getSecret(name));

  /// Snapshot of every synced secret.
  static Future<Map<String, String>> allSecrets() =>
      _wrap(_host.getAllSecrets);

  /// Current state snapshot.
  static Future<AppAttestState> getState() async {
    final raw = await _wrap(_host.getState);
    return _decodeState(raw);
  }

  /// Stream of state transitions. Cancel your subscription on widget
  /// disposal; the native subscription is only active while at least
  /// one Dart listener is connected.
  static Stream<AppAttestState> get stateStream {
    return _stateChannel.receiveBroadcastStream().map((event) {
      final m = (event as Map).cast<String, Object?>();
      String? errorCode;
      String? errorMessage;
      String? errorSubscribeUrl;
      String? errorTopupUrl;
      final err = m['error'];
      if (err is Map) {
        final emap = err.cast<String, Object?>();
        errorCode = emap['code'] as String?;
        errorMessage = emap['message'] as String?;
        errorSubscribeUrl = emap['subscribeUrl'] as String?;
        errorTopupUrl = emap['topupUrl'] as String?;
      }
      return _decodeState(AppAttestStatePayload(
        name: m['name'] as String? ?? 'unavailable',
        errorCode: errorCode,
        errorMessage: errorMessage,
        errorSubscribeUrl: errorSubscribeUrl,
        errorTopupUrl: errorTopupUrl,
      ));
    });
  }

  /// Set runtime mode. Pass `null` for production.
  static Future<void> setDebugMode(DebugMode? mode, [Map<String, String>? stubs]) {
    return _wrap(() => _host.setDebugMode(mode?.wireName, stubs));
  }

  // setApiBaseUrl is not exposed — the Swift SDK hardcodes
  // edge.appattest.dev. No published binary can be redirected at
  // another endpoint; that's the security model.
}

Future<T> _wrap<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on PlatformException catch (e) {
    // Pigeon errors land as PlatformException with code/message/details.
    // Forward the optional URL keys; consumers pick whichever matches.
    String? subscribeUrl;
    String? topupUrl;
    if (e.details is Map) {
      final d = (e.details as Map);
      subscribeUrl = d['subscribeUrl'] as String?;
      topupUrl = d['topupUrl'] as String?;
    }
    throw AppAttestError(
      code: e.code,
      message: e.message ?? 'unknown',
      subscribeUrl: subscribeUrl,
      topupUrl: topupUrl,
    );
  }
}
