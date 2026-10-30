// SB-66: the relay off switch.
//
// Native owns the persisted switch; these tests pin what JS does around it: the
// precedence between `initialize`'s `socket.enabled` and the persisted value, the
// immediate (not debounced) re-subscribe on `setRelayEnabled`, that an unchanged
// switch costs no Subscribe, and that a refused `startPushSocket` surfaces.
// The repository is spied, as in subscribeDeviceInfo.test.ts; each test loads a
// fresh copy of the module because the SDK keeps its state in module scope.

import { BackgroundServiceState } from '../src/generated/sinch/push/v1beta1/resources_pb';
import { baseConfig, flush, loadSdk, logIn } from './sdkTestKit';

const FINGERPRINT_SERVICE = 'com.sinch.push.subscribeFingerprint';

function load(persistedEnabled = true) {
  const t = loadSdk();

  // Native's persisted switch, and the `backgroundService` it implies.
  let enabled = persistedEnabled;
  const calls: string[] = [];
  t.native.setRelayEnabled = jest.fn(async (value: boolean) => {
    calls.push(`setRelayEnabled:${value}`);
    enabled = value;
  });
  t.native.isRelayEnabled = jest.fn(async () => enabled);
  t.native.getDeviceInfo = jest.fn(async () => ({
    installationId: '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
    platform: 'android',
    osVersion: '14',
    sdkVersion: 'rn-sinch-push/1.1.0',
    bundleId: 'com.example.app',
    backgroundService: enabled ? 'ENABLED_RUNNING' : 'RELAY_DISABLED',
  }));
  t.send.mockImplementation(async () => {
    calls.push('subscribe');
  });
  t.native.startPushSocket = jest.fn(async () => {
    if (!enabled) {
      throw Object.assign(new Error('the relay is turned off'), { code: 'E_RELAY_DISABLED' });
    }
  });

  return { ...t, calls, isEnabled: () => enabled, setEnabled: (v: boolean) => (enabled = v) };
}

/**
 * The Keychain is the SDK's only persistence here, and it lives in the mocked
 * module, so `load` starts it empty. An app restart carries it over.
 */
function keychainStore(): Map<string, string> {
  return (require('react-native-keychain') as { _store: Map<string, string> })._store;
}

/** A restart: a fresh copy of the SDK, with what survives a restart carried over. */
function restart(persistedEnabled = true) {
  const persisted = new Map(keychainStore());
  const t = load(persistedEnabled);
  for (const [service, value] of persisted) keychainStore().set(service, value);
  // The device token is native's (the FCM / APNs token), not the SDK's.
  t.native.getDeviceToken = jest.fn(async () => ({ token: 'token-1' }));
  return t;
}

/** initialize + a token + setIdentity: the state after a normal login. */
async function loggedIn(t: ReturnType<typeof load>) {
  await logIn(t);
  t.calls.length = 0;
}

function sentBackgroundService(t: ReturnType<typeof load>, call = -1): unknown {
  const calls = t.send.mock.calls;
  return (calls.at(call) as any[])[3].backgroundService;
}

describe('the relay off switch (RN-048)', () => {
  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  describe('initialize precedence', () => {
    it('applies and persists an explicit socket.enabled: false', async () => {
      const t = load(true);
      await t.sdk.initialize({ ...baseConfig, socket: { enabled: false } });

      expect(t.native.setRelayEnabled).toHaveBeenCalledWith(false);
      expect(await t.sdk.isRelayEnabled()).toBe(false);
    });

    it('applies and persists an explicit socket.enabled: true over a persisted off', async () => {
      const t = load(false);
      await t.sdk.initialize({ ...baseConfig, socket: { enabled: true } });

      expect(t.native.setRelayEnabled).toHaveBeenCalledWith(true);
      expect(await t.sdk.isRelayEnabled()).toBe(true);
    });

    it('keeps the persisted value when socket.enabled is omitted', async () => {
      const off = load(false);
      await off.sdk.initialize({ ...baseConfig, socket: { allowInsecureWs: true } });
      expect(off.native.setRelayEnabled).not.toHaveBeenCalled();
      expect(await off.sdk.isRelayEnabled()).toBe(false);

      const on = load(true);
      await on.sdk.initialize(baseConfig);
      expect(on.native.setRelayEnabled).not.toHaveBeenCalled();
      expect(await on.sdk.isRelayEnabled()).toBe(true);
    });

    it('applies the switch before the start-up Subscribe check, which then sees RELAY_DISABLED', async () => {
      // Logged in once with the relay on: a Subscribe went out and its
      // fingerprint is what the next start compares against.
      const first = load(true);
      await loggedIn(first);
      expect(
        JSON.parse(keychainStore().get(FINGERPRINT_SERVICE) as string),
      ).toMatchObject({ token: 'token-1', backgroundService: 'ENABLED_RUNNING' });

      // App restart with socket.enabled: false: the switch goes out first, and
      // the start-up check behind it sees the switch, so the fingerprint
      // changed and one Subscribe goes out with RELAY_DISABLED.
      const again = restart(true);
      await again.sdk.initialize({ ...baseConfig, socket: { enabled: false } });
      await flush();

      expect(again.calls).toEqual(['setRelayEnabled:false', 'subscribe']);
      expect(sentBackgroundService(again, 0)).toBe(
        BackgroundServiceState.RELAY_DISABLED,
      );
      // The number is the contract (CONTRACT §2.2), not the enum member name.
      expect(sentBackgroundService(again, 0)).toBe(5);
    });

    it('initializes anyway when native cannot apply the switch, and the check still runs', async () => {
      const t = load(true);
      await loggedIn(t);
      const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
      // Native persisted the switch and then failed to answer: the failure is
      // the host's to see, but it must not stop initialize, and the check
      // behind it must still run against what native now holds.
      t.native.setRelayEnabled = jest.fn(async () => {
        t.calls.push('setRelayEnabled');
        t.setEnabled(false);
        throw new Error('E_SET_RELAY_ENABLED');
      });

      await expect(
        t.sdk.initialize({ ...baseConfig, socket: { enabled: false } })
      ).resolves.toBeUndefined();
      await flush();

      expect(warn).toHaveBeenCalledWith(
        '[sinch] could not apply socket.enabled:',
        expect.any(Error),
      );
      expect(t.calls).toEqual(['setRelayEnabled', 'subscribe']);
      expect(sentBackgroundService(t, 0)).toBe(BackgroundServiceState.RELAY_DISABLED);
    });
  });

  describe('setRelayEnabled', () => {
    it('off: one immediate Subscribe with background_service RELAY_DISABLED', async () => {
      jest.useFakeTimers({ doNotFake: ['setImmediate'] });
      const t = load(true);
      await loggedIn(t);

      await t.sdk.setRelayEnabled(false);

      // Not debounced: no timer was advanced.
      expect(t.calls).toEqual(['setRelayEnabled:false', 'subscribe']);
      expect(t.send).toHaveBeenCalledTimes(1);
      expect(sentBackgroundService(t)).toBe(BackgroundServiceState.RELAY_DISABLED);
      expect(BackgroundServiceState.RELAY_DISABLED).toBe(5);
    });

    it('back on: one Subscribe with the real state', async () => {
      const t = load(true);
      await loggedIn(t);
      await t.sdk.setRelayEnabled(false);
      t.send.mockClear();

      await t.sdk.setRelayEnabled(true);

      expect(t.send).toHaveBeenCalledTimes(1);
      expect(sentBackgroundService(t)).toBe(BackgroundServiceState.ENABLED_RUNNING);
    });

    it('unchanged: no Subscribe', async () => {
      const t = load(true);
      await loggedIn(t);

      await t.sdk.setRelayEnabled(true);
      expect(t.send).not.toHaveBeenCalled();

      await t.sdk.setRelayEnabled(false);
      t.send.mockClear();
      await t.sdk.setRelayEnabled(false);
      expect(t.send).not.toHaveBeenCalled();
    });

    it('the device-info event that follows the switch costs no second Subscribe', async () => {
      jest.useFakeTimers({ doNotFake: ['setImmediate'] });
      const t = load(true);
      await loggedIn(t);

      await t.sdk.setRelayEnabled(false);
      // Android emits onDeviceInfoChanged for the same change; debounced 1s.
      (global as any).__fireSinchPushEvent('SinchPush:onDeviceInfoChanged', {});
      await jest.advanceTimersByTimeAsync(2000);
      await flush();

      expect(t.send).toHaveBeenCalledTimes(1);
    });

    it('does not subscribe without an identity, but still applies the switch', async () => {
      const t = load(true);
      await t.sdk.initialize(baseConfig);
      await flush();

      await t.sdk.setRelayEnabled(false);

      expect(t.native.setRelayEnabled).toHaveBeenCalledWith(false);
      expect(t.send).not.toHaveBeenCalled();
    });

    it('a failed Subscribe is logged, not thrown: the switch is applied', async () => {
      const t = load(true);
      await loggedIn(t);
      const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
      t.send.mockRejectedValueOnce(new Error('network down'));

      await expect(t.sdk.setRelayEnabled(false)).resolves.toBeUndefined();

      expect(t.isEnabled()).toBe(false);
      expect(warn).toHaveBeenCalled();
    });

    it('rejects a non-boolean without touching native', async () => {
      const t = load(true);
      await expect(t.sdk.setRelayEnabled('no' as any)).rejects.toThrow('requires a boolean');
      expect(t.native.setRelayEnabled).not.toHaveBeenCalled();
    });

    it('is on the default export too', async () => {
      const t = load(true);
      expect(typeof t.sdk.setRelayEnabled).toBe('function');
      expect(typeof t.sdk.isRelayEnabled).toBe('function');
      const named = require('../src');
      expect(named.setRelayEnabled).toBe(t.sdk.setRelayEnabled);
      expect(named.isRelayEnabled).toBe(t.sdk.isRelayEnabled);
    });
  });

  describe('startPushSocket while off', () => {
    const socketArgs = {
      url: 'wss://relay.example.test/ws',
      authToken: 'tok',
      projectId: 'p',
      appId: 'app',
      userId: 'user-1',
    };

    it('rejects with E_RELAY_DISABLED before native is called, and starts after switching on', async () => {
      const t = load(true);
      await t.sdk.initialize({ ...baseConfig, autoRegisterForToken: false });
      await t.sdk.setRelayEnabled(false);

      await expect(t.sdk.startPushSocket(socketArgs)).rejects.toMatchObject({
        code: 'E_RELAY_DISABLED',
      });
      expect(t.native.startPushSocket).not.toHaveBeenCalled();

      await t.sdk.setRelayEnabled(true);
      await t.sdk.startPushSocket(socketArgs);
      expect(t.native.startPushSocket).toHaveBeenCalledTimes(1);
      await t.sdk.stopPushSocket();
    });

    it('is off by default: a start without opting in names socket.enabled and the gradle property', async () => {
      const t = load(false);
      await t.sdk.initialize({ ...baseConfig, autoRegisterForToken: false });

      expect(await t.sdk.isRelayEnabled()).toBe(false);
      // Even without credentials the answer is the opt-in, not E_NOT_AUTHENTICATED.
      const error = await t.sdk.startPushSocket({ url: socketArgs.url }).catch((e) => e);
      expect(error.code).toBe('E_RELAY_DISABLED');
      expect(error.message).toContain('socket.enabled: true');
      expect(error.message).toContain('SinchPush_relay=true');
      expect(t.native.startPushSocket).not.toHaveBeenCalled();
      expect(t.native.setRelayEnabled).not.toHaveBeenCalled();
    });

    it('adds the opt-in hint to a refusal native makes itself', async () => {
      const t = load(true);
      await t.sdk.initialize({ ...baseConfig, autoRegisterForToken: false });
      // The switch was on when JS looked and off when native started.
      t.native.startPushSocket = jest.fn(async () => {
        t.setEnabled(false);
        throw Object.assign(new Error('the relay is turned off'), { code: 'E_RELAY_DISABLED' });
      });

      const error = await t.sdk.startPushSocket(socketArgs).catch((e) => e);
      expect(error.code).toBe('E_RELAY_DISABLED');
      expect(error.message).toContain('socket.enabled: true');
    });

    it('keeps native\'s own refusal message when the switch reads on', async () => {
      const t = load(true);
      await t.sdk.initialize({ ...baseConfig, autoRegisterForToken: false });
      t.native.startPushSocket = jest.fn(async () => {
        throw Object.assign(new Error('relay not built in'), { code: 'E_RELAY_DISABLED' });
      });

      const error = await t.sdk.startPushSocket(socketArgs).catch((e) => e);
      expect(error.code).toBe('E_RELAY_DISABLED');
      expect(error.message).toContain('relay not built in');
      expect(error.message).not.toContain('socket.enabled: true');
    });

    it('setRelayEnabled(false) drops a running socket from JS: no active config, no poll', async () => {
      jest.useFakeTimers({ doNotFake: ['setImmediate'] });
      const t = load(true);
      const { getActivePushSocketConfig } = require('../src/pushSocket');
      await t.sdk.initialize({ ...baseConfig, autoRegisterForToken: false });
      await t.sdk.startPushSocket(socketArgs);
      expect(getActivePushSocketConfig()).not.toBeNull();

      await t.sdk.setRelayEnabled(false);

      expect(getActivePushSocketConfig()).toBeNull();
      t.native.getPushSocketState.mockClear();
      await jest.advanceTimersByTimeAsync(5000);
      expect(t.native.getPushSocketState).not.toHaveBeenCalled();
    });

    it('a start refused by the switch clears what an earlier start left in JS', async () => {
      jest.useFakeTimers({ doNotFake: ['setImmediate'] });
      const t = load(true);
      const { getActivePushSocketConfig } = require('../src/pushSocket');
      await t.sdk.initialize({ ...baseConfig, autoRegisterForToken: false });
      await t.sdk.startPushSocket(socketArgs);
      // The switch went off behind JS's back (e.g. natively).
      t.setEnabled(false);

      await expect(t.sdk.startPushSocket(socketArgs)).rejects.toMatchObject({
        code: 'E_RELAY_DISABLED',
      });

      expect(getActivePushSocketConfig()).toBeNull();
      t.native.getPushSocketState.mockClear();
      await jest.advanceTimersByTimeAsync(5000);
      expect(t.native.getPushSocketState).not.toHaveBeenCalled();
    });

    it('turning the relay on starts no socket', async () => {
      const t = load(false);
      await t.sdk.initialize({ ...baseConfig, autoRegisterForToken: false });

      await t.sdk.setRelayEnabled(true);

      expect(t.native.startPushSocket).not.toHaveBeenCalled();
    });

    it('a start native refuses leaves no active socket config behind', async () => {
      const t = load(true);
      const { getActivePushSocketConfig } = require('../src/pushSocket');
      await t.sdk.initialize({ ...baseConfig, autoRegisterForToken: false });
      await t.sdk.setRelayEnabled(false);

      await expect(t.sdk.startPushSocket(socketArgs)).rejects.toMatchObject({
        code: 'E_RELAY_DISABLED',
      });

      expect(getActivePushSocketConfig()).toBeNull();
      // Nothing is running, so nothing polls the native store either.
      expect(t.native.getPushSocketState).not.toHaveBeenCalled();
    });
  });
});
