/**
 * TurboModule spec for the AppAttest iOS native module.
 *
 * Codegen reads this file. The shape is restricted to what TurboModule
 * codegen can serialize (primitives, Object, arrays of primitives,
 * Promises, null).
 *
 * Errors: rejection objects carry `{ code, message,
 * subscribeUrl?, topupUrl? }`. The TS wrapper in `index.ts` translates
 * these into `AppAttestError`.
 */
import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export interface Spec extends TurboModule {
  // Lifecycle

  /** Synchronous, idempotent setup. Zero-argument (bucket is
   *  AAGUID-derived server-side). */
  start(): Promise<void>;

  /** Awaits the next terminal state. Resolves on `ready`; rejects on
   *  subscriptionRequired / creditsRequired / unavailable. */
  waitForReady(): Promise<void>;

  /** Re-runs the background sync. */
  retry(): Promise<void>;

  /** Wipes stored credentials and secrets. */
  reset(): Promise<void>;

  /** Invalidate the cached secrets bundle and immediately sync. Keeps
   *  attestation; forces a 200 (1 credit on production). */
  invalidateBundle(): Promise<void>;

  // Reads

  /** Synchronous-feeling secret lookup. Returns `null` if not yet
   *  synced or absent. */
  getSecret(name: string): Promise<string | null>;

  /** Snapshot of every synced secret as `{ [name]: value }`. */
  getAllSecrets(): Promise<{ [key: string]: string }>;

  /** Current state as `{ name, error? }`. */
  getState(): Promise<{
    name: string;
    error?: {
      code: string;
      message: string;
      subscribeUrl?: string;
      topupUrl?: string;
    };
  }>;

  // Configuration

  /** `null` / `'production'` for production; `'local'` for the DEBUG-only
   *  stub mode. `'local'` requires `stubs`. */
  setDebugMode(name: string | null, stubs: { [key: string]: string } | null): Promise<void>;

  // setApiBaseUrl removed — base URL is hardcoded in the Swift SDK.

  // Event emitter plumbing

  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('RNAppAttest');
