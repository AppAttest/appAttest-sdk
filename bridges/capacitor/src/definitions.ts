/**
 * Capacitor plugin interface for AppAttest.
 *
 * The native plugin exposes options as objects and returns results as
 * objects. The friendlier `AppAttest` client in `index.ts` unwraps these
 * for consumer ergonomics.
 *
 * Errors: rejection bodies carry `code` + `message`, plus (for the 402
 * family) one of `subscribeUrl` (`subscription_required`) or `topupUrl`
 * (`credits_required`) via Capacitor's `data:` payload.
 */

import type { PluginListenerHandle } from '@capacitor/core';

export interface NativeAppAttestState {
  name: string;
  error?: {
    code: string;
    message: string;
    subscribeUrl?: string;
    topupUrl?: string;
  };
}

export interface AppAttestPlugin {
  // Lifecycle

  start(): Promise<void>;
  waitForReady(): Promise<void>;
  retry(): Promise<void>;
  reset(): Promise<void>;
  /** Wipe the cached secrets bundle and immediately sync. Keeps
   *  attestation; forces a 200 (1 credit on production). */
  invalidateBundle(): Promise<void>;

  // Reads

  getSecret(options: { name: string }): Promise<{ value: string | null }>;
  getAllSecrets(): Promise<{ secrets: Record<string, string> }>;
  getState(): Promise<NativeAppAttestState>;

  // Configuration

  setDebugMode(options: {
    name: 'production' | 'local' | null;
    stubs?: Record<string, string>;
  }): Promise<void>;

  // setApiBaseUrl is not exposed — base URL hardcoded in Swift SDK.

  // Events

  /** Subscribe to state transitions. Native pushes a snapshot on every
   *  transition; the listener receives `{ name, error? }`. */
  addListener(
    eventName: 'stateChanged',
    listenerFunc: (data: NativeAppAttestState) => void,
  ): Promise<PluginListenerHandle>;

  removeAllListeners(): Promise<void>;
}
