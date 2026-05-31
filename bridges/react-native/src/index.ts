/**
 * @appattest/react-native — public API.
 *
 * Surface mirrors the Swift SDK's bridge translation:
 *   - AppAttest.start() — fire-and-forget setup (zero-arg)
 *   - AppAttest.getSecret(name) — Promise<string | null>
 *   - AppAttest.getAllSecrets() — Promise<Record<string, string>>
 *   - AppAttest.getState() — Promise<AppAttestState>
 *   - AppAttest.waitForReady() — Promise<void>
 *   - AppAttest.retry() — Promise<void>
 *   - AppAttest.addStateListener(fn) — (state) => void; returns unsubscribe
 *   - AppAttest.setDebugMode
 *
 * React hooks (idiomatic for RN consumers):
 *   - useSecret(name) — string | null, re-renders on rotation
 *   - useAllSecrets() — Record<string, string>, re-renders on rotation
 *   - useAppAttestState() — AppAttestState, re-renders on transition
 *
 * There is no sandbox-mode modal logic. Developers handle their
 * own UX for `.subscriptionRequired` / `.creditsRequired` / `.unavailable`.
 */

import { useEffect, useState } from 'react';
import { NativeEventEmitter, NativeModules } from 'react-native';
import NativeAppAttest from './NativeAppAttest';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const eventEmitter = new NativeEventEmitter(NativeModules.RNAppAttest as any);

/**
 * Lifecycle state. Mirrors `AppAttestClient.State` on the native side.
 */
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
 * Typed error thrown by every method. `code` matches the Swift SDK's
 * `AppAttestError.code` one-for-one.
 */
export class AppAttestError extends Error {
  readonly code: string;
  /** For `subscription_required`: URL to (re)start the project subscription. */
  readonly subscribeUrl?: string;
  /** For `credits_required`: URL to top up the project balance. */
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
   * Single accessor for the dashboard URL regardless of code. Returns
   * `subscribeUrl` for `subscription_required`, `topupUrl` for
   * `credits_required`, else `undefined`.
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

export type DebugMode = 'production' | 'local';

interface ErrorEnvelope {
  code?: string;
  message?: string;
  userInfo?: {
    subscribeUrl?: string;
    topupUrl?: string;
  };
  // RN flattens NSError userInfo onto the rejection too; cover both shapes.
  subscribeUrl?: string;
  topupUrl?: string;
}

function buildError(e: ErrorEnvelope, native: unknown): AppAttestError {
  return new AppAttestError(e.code ?? 'internal_error', e.message ?? String(native), {
    subscribeUrl: e.userInfo?.subscribeUrl ?? e.subscribeUrl,
    topupUrl: e.userInfo?.topupUrl ?? e.topupUrl,
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

interface NativeStateRaw {
  name: string;
  error?: ErrorEnvelope;
}

function decodeState(raw: NativeStateRaw): AppAttestState {
  const error = raw.error ? buildError(raw.error, raw.error) : undefined;
  return { name: raw.name as AppAttestStateName, error };
}

export const AppAttest = {
  /**
   * Synchronous, idempotent setup. Zero-argument. Apple's AAGUID
   * determines the bucket (sandbox vs production) server-side; the SDK
   * is bucket-blind.
   */
  start(): Promise<void> {
    return wrap(NativeAppAttest.start());
  },

  /** Awaits a terminal state. Resolves on `ready`; rejects with
   *  AppAttestError on subscriptionRequired / creditsRequired / unavailable. */
  waitForReady(): Promise<void> {
    return wrap(NativeAppAttest.waitForReady());
  },

  /** Re-runs the background sync. */
  retry(): Promise<void> {
    return wrap(NativeAppAttest.retry());
  },

  /** Wipes stored credentials and secrets. */
  reset(): Promise<void> {
    return wrap(NativeAppAttest.reset());
  },

  /**
   * Invalidate the cached secrets bundle and immediately sync. Keeps
   * attestation credentials. Forces a 200 on the next sync, which
   * consumes one credit on the production bucket.
   *
   * Use this for host-app "force refresh" / "sync now" UX. For wiping
   * everything (including attestation), see ``reset()``.
   */
  invalidateBundle(): Promise<void> {
    return wrap(NativeAppAttest.invalidateBundle());
  },

  /** Returns the secret for `name`, or `null`. */
  getSecret(name: string): Promise<string | null> {
    return wrap(NativeAppAttest.getSecret(name));
  },

  /** Snapshot of every synced secret. */
  getAllSecrets(): Promise<Record<string, string>> {
    return wrap(NativeAppAttest.getAllSecrets());
  },

  /** Current state snapshot. */
  async getState(): Promise<AppAttestState> {
    const raw = await wrap(NativeAppAttest.getState());
    return decodeState(raw as NativeStateRaw);
  },

  /** Subscribe to state transitions. Returns an unsubscribe fn. */
  addStateListener(listener: (state: AppAttestState) => void): () => void {
    const subscription = eventEmitter.addListener('stateChanged', (raw) => {
      listener(decodeState(raw as NativeStateRaw));
    });
    return () => subscription.remove();
  },

  /** Set runtime mode. `'production'` (or `null`) is default. */
  setDebugMode(mode: DebugMode | null, stubs?: Record<string, string>): Promise<void> {
    return wrap(NativeAppAttest.setDebugMode(mode, stubs ?? null));
  },

  // setApiBaseUrl is not exposed — the base URL is hardcoded in the Swift
  // SDK. There is no runtime override path from JavaScript.
};

// MARK: - React hooks

/**
 * React hook returning the current value of `secrets[name]`. Re-renders
 * the host component whenever the underlying value changes (e.g. after
 * a foreground rotation pulled new data).
 */
export function useSecret(name: string): string | null {
  const [value, setValue] = useState<string | null>(null);
  useEffect(() => {
    let active = true;
    AppAttest.getSecret(name).then((v) => { if (active) setValue(v); }).catch(() => {});
    const unsubscribe = AppAttest.addStateListener(async (s) => {
      if (s.name === 'ready') {
        try {
          const v = await AppAttest.getSecret(name);
          if (active) setValue(v);
        } catch { /* ignore */ }
      }
    });
    return () => {
      active = false;
      unsubscribe();
    };
  }, [name]);
  return value;
}

/**
 * React hook returning every synced secret. Re-renders on rotation.
 */
export function useAllSecrets(): Record<string, string> {
  const [all, setAll] = useState<Record<string, string>>({});
  useEffect(() => {
    let active = true;
    AppAttest.getAllSecrets().then((v) => { if (active) setAll(v); }).catch(() => {});
    const unsubscribe = AppAttest.addStateListener(async (s) => {
      if (s.name === 'ready') {
        try {
          const v = await AppAttest.getAllSecrets();
          if (active) setAll(v);
        } catch { /* ignore */ }
      }
    });
    return () => {
      active = false;
      unsubscribe();
    };
  }, []);
  return all;
}

/**
 * React hook returning the current `AppAttestState`. Re-renders on
 * every transition.
 */
export function useAppAttestState(): AppAttestState {
  const [state, setState] = useState<AppAttestState>({ name: 'initializing' });
  useEffect(() => {
    let active = true;
    AppAttest.getState().then((s) => { if (active) setState(s); }).catch(() => {});
    const unsubscribe = AppAttest.addStateListener((s) => {
      if (active) setState(s);
    });
    return () => {
      active = false;
      unsubscribe();
    };
  }, []);
  return state;
}

export default AppAttest;
