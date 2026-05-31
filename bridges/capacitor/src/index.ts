/**
 * @appattest/capacitor — public TypeScript API.
 *
 * Wraps the native plugin with a friendlier surface: unwraps result
 * objects, translates rejected promises into typed `AppAttestError`,
 * exposes state events via a cancellable subscription.
 *
 * iOS-only. Calls on the web runtime throw `AppAttestError` with code
 * `attestation_rejected`.
 *
 * There is no sandbox-mode modal logic. Developers handle
 * their own UX for `subscription_required` / `credits_required` /
 * `unavailable`.
 */

import { registerPlugin, type PluginListenerHandle } from '@capacitor/core';

import type { AppAttestPlugin, NativeAppAttestState } from './definitions';

const Native = registerPlugin<AppAttestPlugin>('AppAttest', {
  web: () => import('./web').then((m) => new m.AppAttestWeb()),
});

export * from './definitions';

export type DebugMode = 'production' | 'local';

export type AppAttestStateName =
  | 'initializing'
  | 'attesting'
  | 'syncing'
  | 'ready'
  | 'subscription_required'
  | 'credits_required'
  | 'unavailable';

export interface AppAttestState {
  name: AppAttestStateName;
  error?: AppAttestError;
}

/**
 * Typed error thrown by every method. `code` matches Swift's
 * `AppAttestError.code` one-for-one.
 */
export class AppAttestError extends Error {
  readonly code: string;
  /** `subscription_required` only — URL to (re)start the subscription. */
  readonly subscribeUrl?: string;
  /** `credits_required` only — URL to top up the project balance. */
  readonly topupUrl?: string;
  readonly nativeError?: unknown;

  constructor(
    code: string,
    message: string,
    extras?: {
      subscribeUrl?: string;
      topupUrl?: string;
      nativeError?: unknown;
    },
  ) {
    super(message);
    this.name = 'AppAttestError';
    this.code = code;
    this.subscribeUrl = extras?.subscribeUrl;
    this.topupUrl = extras?.topupUrl;
    this.nativeError = extras?.nativeError;
  }

  /**
   * Single accessor for the dashboard URL regardless of code.
   */
  get actionUrl(): string | undefined {
    return this.subscribeUrl ?? this.topupUrl;
  }
}

/** Stable string codes. Match Swift `AppAttestError.code` one-for-one. */
export const ErrorCode = {
  SubscriptionRequired: 'subscription_required',
  CreditsRequired: 'credits_required',
  AttestationRejected: 'attestation_rejected',
  ServiceUnavailable: 'service_unavailable',
  Network: 'network',
  DebugModeReleaseBlocked: 'debug_mode_release_blocked',
  InvalidArgument: 'invalid_argument',
} as const;

export type ErrorCode = (typeof ErrorCode)[keyof typeof ErrorCode];

interface ErrorEnvelope {
  code?: string;
  message?: string;
  subscribeUrl?: string;
  topupUrl?: string;
  data?: {
    subscribeUrl?: string;
    topupUrl?: string;
  };
}

function buildError(e: ErrorEnvelope, native: unknown): AppAttestError {
  return new AppAttestError(e.code ?? 'internal_error', e.message ?? String(native), {
    subscribeUrl: e.data?.subscribeUrl ?? e.subscribeUrl,
    topupUrl: e.data?.topupUrl ?? e.topupUrl,
    nativeError: native,
  });
}

async function wrap<T>(p: Promise<T>): Promise<T> {
  try {
    return await p;
  } catch (err) {
    throw buildError(err as ErrorEnvelope, err);
  }
}

function decodeState(raw: NativeAppAttestState): AppAttestState {
  const error = raw.error ? buildError(raw.error, raw.error) : undefined;
  return { name: raw.name as AppAttestStateName, error };
}

/**
 * Public client. Static-only namespace; no stateful JS object.
 *
 * ```ts
 * import { AppAttest } from '@appattest/capacitor';
 *
 * await AppAttest.start();
 * await AppAttest.waitForReady();
 * const key = await AppAttest.getSecret('OPENAI_API_KEY');
 * ```
 */
export const AppAttest = {
  /**
   * Synchronous, idempotent setup. Zero-argument. Apple's AAGUID
   * determines the bucket (sandbox vs production) server-side; the SDK
   * is bucket-blind.
   */
  start(): Promise<void> {
    return wrap(Native.start());
  },

  /** Awaits ready; rejects on terminal failures. */
  waitForReady(): Promise<void> {
    return wrap(Native.waitForReady());
  },

  /** Re-runs the background sync. */
  retry(): Promise<void> {
    return wrap(Native.retry());
  },

  /** Wipes stored credentials and secrets. */
  reset(): Promise<void> {
    return wrap(Native.reset());
  },

  /**
   * Invalidate the cached secrets bundle and immediately sync. Keeps
   * attestation credentials. Forces a 200 (1 credit on production).
   * Use for "force refresh" / "sync now" UX.
   */
  invalidateBundle(): Promise<void> {
    return wrap(Native.invalidateBundle());
  },

  /** Returns the secret for `name`, or `null`. */
  async getSecret(name: string): Promise<string | null> {
    const { value } = await wrap(Native.getSecret({ name }));
    return value;
  },

  /** Snapshot of every synced secret. */
  async getAllSecrets(): Promise<Record<string, string>> {
    const { secrets } = await wrap(Native.getAllSecrets());
    return secrets;
  },

  /** Current state snapshot. */
  async getState(): Promise<AppAttestState> {
    const raw = await wrap(Native.getState());
    return decodeState(raw);
  },

  /** Subscribe to state transitions. Returns a Capacitor handle whose
   *  `remove()` detaches the listener. */
  addStateListener(
    listener: (state: AppAttestState) => void,
  ): Promise<PluginListenerHandle> {
    return Native.addListener('stateChanged', (raw) => listener(decodeState(raw)));
  },

  /** Detach every listener this plugin has registered. */
  removeAllListeners(): Promise<void> {
    return Native.removeAllListeners();
  },

  /** Set runtime mode. `null` (or omitted) is production. */
  setDebugMode(mode: DebugMode | null, stubs?: Record<string, string>): Promise<void> {
    return wrap(Native.setDebugMode({ name: mode, stubs }));
  },

  // setApiBaseUrl is not exposed — the base URL is hardcoded in the Swift SDK
  // (https://edge.appattest.dev). No runtime override path exists in the
  // native plugin, definitions, or web stub.
};

export default AppAttest;
