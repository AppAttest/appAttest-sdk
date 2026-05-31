// Unit tests for the public Dart API. Pigeon channel is mocked so
// these tests don't touch the native side.

import 'package:flutter_test/flutter_test.dart';

import 'package:appattest_flutter/appattest_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ErrorCode constants match Swift', () {
    expect(ErrorCode.subscriptionRequired, equals('subscription_required'));
    expect(ErrorCode.creditsRequired, equals('credits_required'));
    expect(ErrorCode.attestationRejected, equals('attestation_rejected'));
    expect(ErrorCode.serviceUnavailable, equals('service_unavailable'));
    expect(ErrorCode.network, equals('network'));
  });

  test('AppAttestError carries subscribeUrl for subscription_required', () {
    // No projectId on the error — the deep-link URL already encodes
    // any project routing in its path.
    final err = AppAttestError(
      code: 'subscription_required',
      message: 'subscribe',
      subscribeUrl: 'https://app.appattest.dev/projects/proj_01HX/subscribe',
    );
    expect(err.subscribeUrl, equals('https://app.appattest.dev/projects/proj_01HX/subscribe'));
    expect(err.topupUrl, isNull);
    expect(err.actionUrl, equals(err.subscribeUrl));
    expect(err.toString(), contains('subscription_required'));
  });

  test('AppAttestError carries topupUrl for credits_required', () {
    final err = AppAttestError(
      code: 'credits_required',
      message: 'top up',
      topupUrl: 'https://app.appattest.dev/projects/proj_01HX/billing',
    );
    expect(err.topupUrl, equals('https://app.appattest.dev/projects/proj_01HX/billing'));
    expect(err.actionUrl, equals(err.topupUrl));
    expect(err.subscribeUrl, isNull);
  });

  test('AppAttestError actionUrl is null when no URL field is set', () {
    final err = AppAttestError(code: 'attestation_rejected', message: 'cert');
    expect(err.actionUrl, isNull);
  });

  test('AppAttestStateName covers the seven states', () {
    expect(AppAttestStateName.values.length, equals(7));
    expect(AppAttestStateName.values, contains(AppAttestStateName.ready));
    expect(AppAttestStateName.values, contains(AppAttestStateName.subscriptionRequired));
    expect(AppAttestStateName.values, contains(AppAttestStateName.creditsRequired));
    expect(AppAttestStateName.values, contains(AppAttestStateName.unavailable));
  });

  test('DebugMode wireName matches Swift (.local only)', () {
    expect(DebugMode.values, contains(DebugMode.local));
    expect(DebugMode.values.length, equals(1));
  });

  // SecretsBucket enum is not present — Apple AAGUID is the sole
  // bucket signal; SDK is bucket-blind.
}
