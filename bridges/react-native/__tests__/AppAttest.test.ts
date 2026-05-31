/**
 * Unit tests for the TS wrapper. Native module is mocked.
 */

import { AppAttest, AppAttestError, ErrorCode } from '../src/index';

jest.mock('../src/NativeAppAttest', () => {
  const module = {
    start: jest.fn(() => Promise.resolve()),
    waitForReady: jest.fn(() => Promise.resolve()),
    retry: jest.fn(() => Promise.resolve()),
    reset: jest.fn(() => Promise.resolve()),
    getSecret: jest.fn((name: string) => Promise.resolve(name === 'known' ? 'value' : null)),
    getAllSecrets: jest.fn(() => Promise.resolve({ A: '1', B: '2' })),
    getState: jest.fn(() => Promise.resolve({ name: 'ready' })),
    setDebugMode: jest.fn(() => Promise.resolve()),
    addListener: jest.fn(),
    removeListeners: jest.fn(),
  };
  return { __esModule: true, default: module };
});

jest.mock('react-native', () => ({
  NativeModules: {
    RNAppAttest: {
      addListener: jest.fn(),
      removeListeners: jest.fn(),
    },
  },
  NativeEventEmitter: jest.fn().mockImplementation(() => ({
    addListener: jest.fn((_event: string, _cb: (state: unknown) => void) => ({
      remove: jest.fn(),
    })),
  })),
}));

describe('AppAttest TS wrapper', () => {
  test('start delegates to native zero-arg (bucket-blind)', async () => {
    const native = await import('../src/NativeAppAttest');
    await AppAttest.start();
    expect(native.default.start).toHaveBeenCalled();
  });

  test('getSecret returns null for missing keys', async () => {
    expect(await AppAttest.getSecret('unknown')).toBeNull();
    expect(await AppAttest.getSecret('known')).toBe('value');
  });

  test('getAllSecrets returns a map', async () => {
    expect(await AppAttest.getAllSecrets()).toEqual({ A: '1', B: '2' });
  });

  test('getState returns AppAttestState shape', async () => {
    const s = await AppAttest.getState();
    expect(s.name).toBe('ready');
    expect(s.error).toBeUndefined();
  });

  test('setDebugMode passes mode + stubs to native', async () => {
    const native = await import('../src/NativeAppAttest');
    await AppAttest.setDebugMode('local', { A: '1' });
    expect(native.default.setDebugMode).toHaveBeenLastCalledWith('local', { A: '1' });
  });

  test('setDebugMode null defaults to production', async () => {
    const native = await import('../src/NativeAppAttest');
    await AppAttest.setDebugMode(null);
    expect(native.default.setDebugMode).toHaveBeenLastCalledWith(null, null);
  });

  test('native rejection becomes AppAttestError', async () => {
    const native = await import('../src/NativeAppAttest');
    native.default.start = jest.fn(() =>
      Promise.reject({ code: 'attestation_rejected', message: 'cert chain' }),
    );
    await expect(AppAttest.start()).rejects.toMatchObject({
      name: 'AppAttestError',
      code: 'attestation_rejected',
      message: 'cert chain',
    });
  });

  test('subscription_required rejection surfaces subscribeUrl', async () => {
    // Error envelope no longer carries projectId — the deep-link URL
    // already encodes any project routing in its path.
    const native = await import('../src/NativeAppAttest');
    native.default.waitForReady = jest.fn(() =>
      Promise.reject({
        code: 'subscription_required',
        message: 'subscribe',
        userInfo: {
          subscribeUrl: 'https://app.appattest.dev/projects/proj_01HX/subscribe',
        },
      }),
    );
    try {
      await AppAttest.waitForReady();
      throw new Error('expected reject');
    } catch (e) {
      const err = e as AppAttestError;
      expect(err.code).toBe('subscription_required');
      expect(err.subscribeUrl).toBe('https://app.appattest.dev/projects/proj_01HX/subscribe');
      expect(err.actionUrl).toBe('https://app.appattest.dev/projects/proj_01HX/subscribe');
      expect(err.topupUrl).toBeUndefined();
    }
  });

  test('credits_required rejection surfaces topupUrl', async () => {
    const native = await import('../src/NativeAppAttest');
    native.default.waitForReady = jest.fn(() =>
      Promise.reject({
        code: 'credits_required',
        message: 'top up',
        userInfo: {
          topupUrl: 'https://app.appattest.dev/projects/proj_01HX/billing',
        },
      }),
    );
    try {
      await AppAttest.waitForReady();
      throw new Error('expected reject');
    } catch (e) {
      const err = e as AppAttestError;
      expect(err.code).toBe('credits_required');
      expect(err.topupUrl).toBe('https://app.appattest.dev/projects/proj_01HX/billing');
      expect(err.actionUrl).toBe('https://app.appattest.dev/projects/proj_01HX/billing');
      expect(err.subscribeUrl).toBeUndefined();
    }
  });

  test('actionUrl is undefined when no URL field present', () => {
    const err = new AppAttestError('attestation_rejected', 'cert chain');
    expect(err.actionUrl).toBeUndefined();
  });

  test('addStateListener returns unsubscribe', () => {
    const unsub = AppAttest.addStateListener(() => {});
    expect(typeof unsub).toBe('function');
    unsub();
  });

  test('ErrorCode constants match Swift', () => {
    expect(ErrorCode.SubscriptionRequired).toBe('subscription_required');
    expect(ErrorCode.CreditsRequired).toBe('credits_required');
    expect(ErrorCode.AttestationRejected).toBe('attestation_rejected');
    expect(ErrorCode.ServiceUnavailable).toBe('service_unavailable');
    expect(ErrorCode.Network).toBe('network');
  });
});
