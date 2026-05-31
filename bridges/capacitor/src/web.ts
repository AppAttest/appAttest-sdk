/**
 * Web fallback for `@appattest/capacitor`.
 *
 * App Attest is iOS-only. Every method throws an error with code
 * `attestation_rejected` so consumers can detect the platform via the
 * error code and degrade gracefully.
 */

import { WebPlugin } from '@capacitor/core';

import type { AppAttestPlugin, NativeAppAttestState } from './definitions';

export class AppAttestWeb extends WebPlugin implements AppAttestPlugin {
  private reject(): never {
    const err = new Error('AppAttest is iOS-only. Web is not supported.');
    (err as unknown as { code: string }).code = 'attestation_rejected';
    throw err;
  }

  start(): Promise<void> { return this.reject(); }
  waitForReady(): Promise<void> { return this.reject(); }
  retry(): Promise<void> { return this.reject(); }
  reset(): Promise<void> { return this.reject(); }
  invalidateBundle(): Promise<void> { return this.reject(); }
  getSecret(): Promise<{ value: string | null }> { return this.reject(); }
  getAllSecrets(): Promise<{ secrets: Record<string, string> }> { return this.reject(); }
  getState(): Promise<NativeAppAttestState> { return this.reject(); }
  setDebugMode(): Promise<void> { return this.reject(); }
  // setApiBaseUrl + setSandboxModalEnabled are not exposed.
}
