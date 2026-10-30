// SB-61: Subscribe carries the device info; a change re-subscribes.
//
// The repository is spied rather than the network faked: what these tests pin is
// *when* the SDK subscribes and with what, not the wire format (that is
// pushRepository.test.ts). The storage is the real Keychain-backed one over the
// in-memory Keychain mock, so "the fingerprint is persisted" is observed, not
// assumed. Each test loads a fresh copy of the module: the SDK keeps its state
// (config, token, queue, timers) in module scope.

import {
  BackgroundServiceState,
  Platform,
} from '../src/generated/sinch/push/v1beta1/resources_pb';
import { baseConfig, flush, identity, loadSdk, logIn } from './sdkTestKit';

const FINGERPRINT_SERVICE = 'com.sinch.push.subscribeFingerprint';
const LAST_SENT_SERVICE = 'com.sinch.push.deviceToken';

type Info = {
  installationId: string;
  platform: 'ios' | 'android';
  osVersion: string;
  sdkVersion: string;
  bundleId: string;
  backgroundService: string;
};

const INFO: Info = {
  installationId: '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
  platform: 'android',
  osVersion: '14',
  sdkVersion: 'rn-sinch-push/1.1.0',
  bundleId: 'com.example.app',
  backgroundService: 'ENABLED_RUNNING',
};

// Only Android emits onDeviceInfoChanged, so the SDK listens for it only there.
let platformOS: 'ios' | 'android' = 'ios';

function load() {
  const t = loadSdk();
  require('react-native').Platform.OS = platformOS;
  const keychain = require('react-native-keychain');

  let current: Info = { ...INFO };
  const getDeviceInfo = jest
    .spyOn(t.native, 'getDeviceInfo')
    .mockImplementation(async () => ({ ...current }));

  return {
    ...t,
    getDeviceInfo,
    fireDeviceInfoChanged: () =>
      (global as any).__fireSinchPushEvent('SinchPush:onDeviceInfoChanged', {}),
    fireToken: (token: string) =>
      (global as any).__fireSinchPushEvent('SinchPush:onTokenReceived', {
        token,
        type: require('react-native').Platform.OS === 'ios' ? 'apns' : 'fcm',
      }),
    setInfo: (patch: Partial<Info>) => {
      current = { ...current, ...patch };
    },
    stored: async (service: string) => {
      const c = await keychain.getGenericPassword({ service });
      return c === false ? null : (c.password as string);
    },
  };
}

describe('Subscribe carries device info (RN-043)', () => {
  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('setIdentity subscribes with the device info native reports', async () => {
    const t = load();
    await t.sdk.initialize(baseConfig);
    t.sdk.setDeviceToken('token-1');

    await t.sdk.setIdentity(identity);

    expect(t.send).toHaveBeenCalledTimes(1);
    const [token, accessToken, configID, info] = t.send.mock.calls[0] as any[];
    expect(token).toBe('token-1');
    expect(typeof accessToken).toBe('string');
    expect(configID).toBe('config-1');
    expect(info).toEqual({
      installationId: INFO.installationId,
      platform: Platform.ANDROID,
      osVersion: '14',
      sdkVersion: 'rn-sinch-push/1.1.0',
      bundleId: 'com.example.app',
      backgroundService: BackgroundServiceState.ENABLED_RUNNING,
    });
    // The numbers are the contract (CONTRACT §2.2), not the enum member names.
    expect(info.platform).toBe(4);
    expect(info.backgroundService).toBe(3);
  });

  it.each([
    ['ios', 3],
    ['android', 4],
  ] as const)('platform %s is resources.Platform %i', async (platform, number) => {
    const t = load();
    t.setInfo({ platform });
    await t.sdk.initialize(baseConfig);
    t.sdk.setDeviceToken('token-1');
    await t.sdk.setIdentity(identity);
    expect((t.send.mock.calls[0] as any[])[3].platform).toBe(number);
  });

  it.each([
    ['UNSUPPORTED', 1],
    ['DISABLED', 2],
    ['ENABLED_RUNNING', 3],
    ['ENABLED_NOT_RUNNING', 4],
  ] as const)('background_service %s is %i', async (name, number) => {
    const t = load();
    t.setInfo({ backgroundService: name });
    await t.sdk.initialize(baseConfig);
    t.sdk.setDeviceToken('token-1');
    await t.sdk.setIdentity(identity);
    expect((t.send.mock.calls[0] as any[])[3].backgroundService).toBe(number);
  });

  it('records the fingerprint after a successful Subscribe, next to lastSent', async () => {
    const t = load();
    await t.sdk.initialize(baseConfig);
    t.sdk.setDeviceToken('token-1');
    await t.sdk.setIdentity(identity);

    expect(await t.stored(LAST_SENT_SERVICE)).toBe('token-1');
    const fingerprint = JSON.parse((await t.stored(FINGERPRINT_SERVICE)) as string);
    expect(fingerprint).toEqual({
      token: 'token-1',
      configID: 'config-1',
      installationId: INFO.installationId,
      sdkVersion: INFO.sdkVersion,
      osVersion: '14',
      bundleId: 'com.example.app',
      backgroundService: 'ENABLED_RUNNING',
    });
  });

  it('does not record a fingerprint when the Subscribe failed', async () => {
    const t = load();
    await t.sdk.initialize(baseConfig);
    t.sdk.setDeviceToken('token-1');
    t.send.mockRejectedValueOnce(new Error('503'));

    await expect(t.sdk.setIdentity(identity)).rejects.toThrow('503');

    expect(await t.stored(FINGERPRINT_SERVICE)).toBeNull();
  });
});

describe('re-subscribe on change (RN-043)', () => {
  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('app start with an unchanged fingerprint does not subscribe', async () => {
    const t = load();
    await logIn(t);

    await t.sdk.initialize(baseConfig);
    await flush();

    expect(t.send).not.toHaveBeenCalled();
  });

  it('app start without an identity does not subscribe', async () => {
    const t = load();
    t.sdk.setDeviceToken('token-1');
    await t.sdk.initialize(baseConfig);
    await flush();
    expect(t.send).not.toHaveBeenCalled();
  });

  it('app start with an identity but no fingerprint (an upgrade) subscribes once', async () => {
    const t = load();
    await logIn(t);
    const keychain = require('react-native-keychain');
    await keychain.resetGenericPassword({ service: FINGERPRINT_SERVICE });

    await t.sdk.initialize(baseConfig);
    await flush();

    expect(t.send).toHaveBeenCalledTimes(1);
    expect((t.send.mock.calls[0] as any[])[3].installationId).toBe(INFO.installationId);
  });

  it.each([
    ['installationId', { installationId: '00000000-0000-4000-8000-000000000000' }],
    ['sdkVersion', { sdkVersion: 'rn-sinch-push/1.1.1' }],
    ['osVersion', { osVersion: '15' }],
    ['bundleId', { bundleId: 'com.example.other' }],
    ['backgroundService', { backgroundService: 'ENABLED_NOT_RUNNING' }],
  ] as const)('a changed %s re-subscribes exactly once on app start', async (_name, patch) => {
    const t = load();
    await logIn(t);
    t.setInfo(patch);

    await t.sdk.initialize(baseConfig);
    await flush();
    expect(t.send).toHaveBeenCalledTimes(1);
    const sent = (t.send.mock.calls[0] as any[])[3];
    const [key, value] = Object.entries(patch)[0]!;
    expect(sent[key]).toBe(key === 'backgroundService' ? BackgroundServiceState.ENABLED_NOT_RUNNING : value);

    // ...and the new state is now the recorded one.
    t.send.mockClear();
    await t.sdk.initialize(baseConfig);
    await flush();
    expect(t.send).not.toHaveBeenCalled();
  });

  it('a changed configID re-subscribes on app start', async () => {
    const t = load();
    await logIn(t);
    // Logged in under another config too: that Subscribe is the recorded one.
    await t.sdk.initialize({ ...baseConfig, configID: 'config-2' });
    await t.sdk.setIdentity(identity);
    await flush();
    expect(JSON.parse((await t.stored(FINGERPRINT_SERVICE)) as string).configID).toBe('config-2');
    t.send.mockClear();

    // Back on config-1, whose identity is still there: what was last sent was
    // for config-2, so it must go again - and only once.
    await t.sdk.initialize(baseConfig);
    await flush();
    expect(t.send).toHaveBeenCalledTimes(1);
    expect((t.send.mock.calls[0] as any[])[2]).toBe('config-1');

    t.send.mockClear();
    await t.sdk.initialize(baseConfig);
    await flush();
    expect(t.send).not.toHaveBeenCalled();
  });

  it('a rotated token re-subscribes once, with device info, and records it', async () => {
    const t = load();
    await logIn(t);

    t.fireToken('token-2');
    await flush();

    expect(t.send).toHaveBeenCalledTimes(1);
    const [token, , , info] = t.send.mock.calls[0] as any[];
    expect(token).toBe('token-2');
    expect(info.installationId).toBe(INFO.installationId);
    expect(JSON.parse((await t.stored(FINGERPRINT_SERVICE)) as string).token).toBe('token-2');

    // The same token again changes nothing.
    t.send.mockClear();
    t.fireToken('token-2');
    await flush();
    expect(t.send).not.toHaveBeenCalled();
  });

  describe('on SinchPush:onDeviceInfoChanged', () => {
    beforeEach(() => {
      platformOS = 'android';
      jest.useFakeTimers({ doNotFake: ['setImmediate', 'nextTick'] });
    });
    afterEach(() => {
      platformOS = 'ios';
    });

    it('re-subscribes once after the debounce when the device info changed', async () => {
      const t = load();
      await logIn(t);
      t.setInfo({ backgroundService: 'ENABLED_NOT_RUNNING' });

      t.fireDeviceInfoChanged();
      await jest.advanceTimersByTimeAsync(900);
      expect(t.send).not.toHaveBeenCalled();
      await jest.advanceTimersByTimeAsync(200);
      await flush();

      expect(t.send).toHaveBeenCalledTimes(1);
      expect((t.send.mock.calls[0] as any[])[3].backgroundService).toBe(
        BackgroundServiceState.ENABLED_NOT_RUNNING,
      );
    });

    it('does not subscribe when the event fires but nothing differs', async () => {
      const t = load();
      await logIn(t);

      t.fireDeviceInfoChanged();
      await jest.advanceTimersByTimeAsync(1500);
      await flush();

      expect(t.send).not.toHaveBeenCalled();
    });

    it('collapses a burst of events into one Subscribe', async () => {
      const t = load();
      await logIn(t);
      t.setInfo({ backgroundService: 'DISABLED' });

      for (let i = 0; i < 5; i++) {
        t.fireDeviceInfoChanged();
        await jest.advanceTimersByTimeAsync(300);
      }
      await jest.advanceTimersByTimeAsync(1000);
      await flush();

      expect(t.send).toHaveBeenCalledTimes(1);
    });

    it('never has two Subscribes in flight, and runs once more for a change that arrived during one', async () => {
      const t = load();
      await logIn(t);

      let inFlight = 0;
      let maxInFlight = 0;
      const releases: Array<() => void> = [];
      t.send.mockImplementation(async () => {
        inFlight++;
        maxInFlight = Math.max(maxInFlight, inFlight);
        await new Promise<void>((resolve) => releases.push(resolve));
        inFlight--;
      });

      t.setInfo({ backgroundService: 'ENABLED_NOT_RUNNING' });
      t.fireDeviceInfoChanged();
      await jest.advanceTimersByTimeAsync(1000);
      await flush();
      expect(t.send).toHaveBeenCalledTimes(1); // in flight, held

      // Another change lands while that Subscribe is still out.
      t.setInfo({ backgroundService: 'ENABLED_RUNNING' });
      t.fireDeviceInfoChanged();
      await jest.advanceTimersByTimeAsync(1000);
      await flush();
      expect(t.send).toHaveBeenCalledTimes(1); // queued behind it, not started

      releases.shift()!();
      await flush();
      expect(t.send).toHaveBeenCalledTimes(2);
      expect((t.send.mock.calls[1] as any[])[3].backgroundService).toBe(
        BackgroundServiceState.ENABLED_RUNNING,
      );
      releases.shift()!();
      await flush();

      expect(maxInFlight).toBe(1);
      expect(t.send).toHaveBeenCalledTimes(2);
    });

    it('a failed re-subscribe leaves the queue usable and is retried by the next event', async () => {
      const t = load();
      await logIn(t);
      t.setInfo({ osVersion: '15' });
      const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
      t.send.mockRejectedValueOnce(new Error('offline'));

      t.fireDeviceInfoChanged();
      await jest.advanceTimersByTimeAsync(1000);
      await flush();
      expect(t.send).toHaveBeenCalledTimes(1);
      expect(warn).toHaveBeenCalled();

      t.fireDeviceInfoChanged();
      await jest.advanceTimersByTimeAsync(1000);
      await flush();
      expect(t.send).toHaveBeenCalledTimes(2);
    });

    it('setIdentity while a check is pending subscribes once, and the timer then finds nothing to do', async () => {
      const t = load();
      await logIn(t);
      t.setInfo({ backgroundService: 'ENABLED_NOT_RUNNING' });

      t.fireDeviceInfoChanged();
      await jest.advanceTimersByTimeAsync(400);
      await t.sdk.setIdentity(identity);
      expect(t.send).toHaveBeenCalledTimes(1);
      expect((t.send.mock.calls[0] as any[])[3].backgroundService).toBe(
        BackgroundServiceState.ENABLED_NOT_RUNNING,
      );

      await jest.advanceTimersByTimeAsync(2000);
      await flush();
      expect(t.send).toHaveBeenCalledTimes(1);
    });

    it('removeIdentity cancels a pending check', async () => {
      const t = load();
      await logIn(t);
      t.setInfo({ osVersion: '15' });

      t.fireDeviceInfoChanged();
      await t.sdk.removeIdentity(identity);
      await jest.advanceTimersByTimeAsync(2000);
      await flush();

      expect(t.send).not.toHaveBeenCalled();
    });
  });
});

describe('native device info failure (RN-043)', () => {
  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('subscribes without device info, logs, and does not throw', async () => {
    const t = load();
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    t.getDeviceInfo.mockRejectedValue(
      Object.assign(new Error('keychain locked'), { code: 'E_INSTALLATION_ID_UNAVAILABLE' }),
    );
    await t.sdk.initialize(baseConfig);
    t.sdk.setDeviceToken('token-1');

    await expect(t.sdk.setIdentity(identity)).resolves.toBeUndefined();

    expect(t.send).toHaveBeenCalledTimes(1);
    const [token, , configID, info] = t.send.mock.calls[0] as any[];
    expect(token).toBe('token-1');
    expect(configID).toBe('config-1');
    expect(info).toBeUndefined();
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('getDeviceInfo failed'), expect.anything());
  });

  it('treats a malformed answer the same way', async () => {
    const t = load();
    jest.spyOn(console, 'warn').mockImplementation(() => {});
    t.getDeviceInfo.mockResolvedValue({ installationId: '' } as any);
    await t.sdk.initialize(baseConfig);
    t.sdk.setDeviceToken('token-1');

    await t.sdk.setIdentity(identity);

    expect((t.send.mock.calls[0] as any[])[3]).toBeUndefined();
  });

  it('once native answers again, the next check re-subscribes with the info', async () => {
    const t = load();
    jest.spyOn(console, 'warn').mockImplementation(() => {});
    t.getDeviceInfo.mockRejectedValueOnce(new Error('boom'));
    await t.sdk.initialize(baseConfig);
    t.sdk.setDeviceToken('token-1');
    await t.sdk.setIdentity(identity);
    await flush();
    t.send.mockClear();

    await t.sdk.initialize(baseConfig);
    await flush();

    expect(t.send).toHaveBeenCalledTimes(1);
    expect((t.send.mock.calls[0] as any[])[3]).toMatchObject({ installationId: INFO.installationId });
  });
});

describe('removeIdentity (RN-043)', () => {
  afterEach(() => jest.restoreAllMocks());

  it('clears the fingerprint with the token record, so the next login always subscribes', async () => {
    const t = load();
    await logIn(t);
    expect(await t.stored(FINGERPRINT_SERVICE)).not.toBeNull();

    await t.sdk.removeIdentity(identity);

    expect(await t.stored(FINGERPRINT_SERVICE)).toBeNull();
    expect(await t.stored(LAST_SENT_SERVICE)).toBeNull();
  });

  /** The auth backend answers with a JWT named for the user it was asked for. */
  function mockJwts() {
    const { DefaultAuthRepository } = require('../src/api/authRepository');
    return jest
      .spyOn(DefaultAuthRepository.prototype, 'createSignedToken')
      .mockImplementation(async (config: any, userId: string, secret: string) => ({
        accessToken: `jwt-${userId}`,
        expiresAt: new Date(Date.now() + 3_600_000),
        identityHash: `selfSigned.${userId}.${secret}`,
        clientID: config.clientID,
        projectID: config.projectID,
        configID: config.configID,
        region: config.region,
      }));
  }

  function storedJwt() {
    return require('react-native-keychain')
      .getGenericPassword({ service: 'com.sinch.push.auth.client-1.project-1.config-1.EU1' })
      .then((c: any) => (c === false ? null : (JSON.parse(c.password).accessToken as string)));
  }

  it('while a Subscribe is in flight: it unsubscribes after it, and the fingerprint is not written back', async () => {
    const t = load();
    mockJwts();
    await logIn(t);
    const { DefaultPushRepository } = require('../src/api/pushRepository');
    const order: string[] = [];
    const unsubscribe = jest
      .spyOn(DefaultPushRepository.prototype, 'unsubscribe')
      .mockImplementation(async () => {
        order.push('unsubscribe');
      });
    let release!: () => void;
    t.send.mockImplementation(async () => {
      order.push('subscribe:start');
      await new Promise<void>((resolve) => (release = resolve));
      order.push('subscribe:end');
    });

    t.fireToken('token-2'); // a Subscribe goes out for the rotated token
    await flush();
    expect(order).toEqual(['subscribe:start']);

    const removal = t.sdk.removeIdentity(identity); // not awaited
    await flush();
    expect(unsubscribe).not.toHaveBeenCalled();

    release();
    await removal;

    expect(order).toEqual(['subscribe:start', 'subscribe:end', 'unsubscribe']);
    expect(unsubscribe).toHaveBeenCalledTimes(1);
    expect(await t.stored(FINGERPRINT_SERVICE)).toBeNull();
    expect(await t.stored(LAST_SENT_SERVICE)).toBeNull();
  });

  it('a non-awaited removeIdentity(A) then setIdentity(B) unsubscribes with A and keeps B', async () => {
    const t = load();
    const jwts = mockJwts();
    await logIn(t);
    const { DefaultPushRepository } = require('../src/api/pushRepository');
    const unsubscribed: Array<[string, string]> = [];
    jest
      .spyOn(DefaultPushRepository.prototype, 'unsubscribe')
      .mockImplementation(async (deviceToken: string, accessToken: string) => {
        unsubscribed.push([deviceToken, accessToken]);
      });
    expect(await storedJwt()).toBe('jwt-alice');
    jwts.mockClear();

    const removal = t.sdk.removeIdentity(identity); // not awaited
    const login = t.sdk.setIdentity({ userID: 'bob', signedUserID: 'sig-2' });
    await Promise.all([removal, login]);

    // A's Unsubscribe carried A's JWT; B's JWT was minted after it and survived.
    expect(unsubscribed).toEqual([['token-1', 'jwt-alice']]);
    expect(jwts).toHaveBeenCalledTimes(1);
    expect(t.send).toHaveBeenCalledTimes(1);
    expect((t.send.mock.calls[0] as any[])[1]).toBe('jwt-bob');
    expect(await storedJwt()).toBe('jwt-bob');
    expect(await t.stored(FINGERPRINT_SERVICE)).not.toBeNull();
  });
});

describe('fingerprint store resolution and failures (RN-043)', () => {
  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  /** The storage a host wrote before the fingerprint existed: three methods only. */
  function legacyStorage() {
    let lastSent: string | null = null;
    return {
      readLastSent: jest.fn(async () => lastSent),
      writeLastSent: jest.fn(async (token: string) => {
        lastSent = token;
      }),
      clearLastSent: jest.fn(async () => {
        lastSent = null;
      }),
    };
  }

  it('a custom storage without the fingerprint methods keeps working on the built-in store', async () => {
    const t = load();
    const storage = legacyStorage();
    await t.sdk.initialize(baseConfig, { deviceTokenStorage: storage as any });
    t.sdk.setDeviceToken('token-1');

    await expect(t.sdk.setIdentity(identity)).resolves.toBeUndefined();
    expect(t.send).toHaveBeenCalledTimes(1);
    expect(storage.writeLastSent).toHaveBeenCalledWith('token-1');
    expect(await t.stored(FINGERPRINT_SERVICE)).not.toBeNull();

    // Unchanged at the next app start: nothing goes out.
    t.send.mockClear();
    await t.sdk.initialize(baseConfig, { deviceTokenStorage: storage as any });
    await flush();
    expect(t.send).not.toHaveBeenCalled();

    // ...a change still does.
    t.setInfo({ osVersion: '15' });
    await t.sdk.initialize(baseConfig, { deviceTokenStorage: storage as any });
    await flush();
    expect(t.send).toHaveBeenCalledTimes(1);

    await expect(t.sdk.removeIdentity(identity)).resolves.toBeUndefined();
    expect(storage.clearLastSent).toHaveBeenCalled();
    expect(await t.stored(FINGERPRINT_SERVICE)).toBeNull();
  });

  it('a custom storage with all three fingerprint methods is used instead of the Keychain', async () => {
    const t = load();
    let fingerprint: string | null = null;
    const storage = {
      ...legacyStorage(),
      readLastSubscribedFingerprint: jest.fn(async () => fingerprint),
      writeLastSubscribedFingerprint: jest.fn(async (f: string) => {
        fingerprint = f;
      }),
      clearLastSubscribedFingerprint: jest.fn(async () => {
        fingerprint = null;
      }),
    };
    await t.sdk.initialize(baseConfig, { deviceTokenStorage: storage });
    t.sdk.setDeviceToken('token-1');
    await t.sdk.setIdentity(identity);

    expect(storage.writeLastSubscribedFingerprint).toHaveBeenCalledTimes(1);
    expect(await t.stored(FINGERPRINT_SERVICE)).toBeNull();

    await t.sdk.removeIdentity(identity);
    expect(storage.clearLastSubscribedFingerprint).toHaveBeenCalledTimes(1);
  });

  it('a storage with only some of the fingerprint methods is not used for them', async () => {
    const t = load();
    const storage = {
      ...legacyStorage(),
      readLastSubscribedFingerprint: jest.fn(async () => null),
    };
    await t.sdk.initialize(baseConfig, { deviceTokenStorage: storage as any });
    t.sdk.setDeviceToken('token-1');
    await t.sdk.setIdentity(identity);

    expect(storage.readLastSubscribedFingerprint).not.toHaveBeenCalled();
    expect(await t.stored(FINGERPRINT_SERVICE)).not.toBeNull();
  });

  it('a fingerprint that cannot be read reads as changed: it subscribes', async () => {
    const t = load();
    await logIn(t);
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    const keychain = require('react-native-keychain');
    const original = keychain.getGenericPassword;
    jest.spyOn(keychain, 'getGenericPassword').mockImplementation(async (o: any) => {
      if (o?.service === FINGERPRINT_SERVICE) throw new Error('keychain locked');
      return original(o);
    });

    await t.sdk.initialize(baseConfig);
    await flush();

    expect(t.send).toHaveBeenCalledTimes(1);
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('reading the subscribe fingerprint'), expect.anything());
  });

  it('a fingerprint that cannot be written is logged and does not reject setIdentity', async () => {
    const t = load();
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    const keychain = require('react-native-keychain');
    const original = keychain.setGenericPassword;
    jest.spyOn(keychain, 'setGenericPassword').mockImplementation(async (...args: any[]) => {
      if (args[2]?.service === FINGERPRINT_SERVICE) throw new Error('keychain refused');
      return original(...args);
    });
    await t.sdk.initialize(baseConfig);
    t.sdk.setDeviceToken('token-1');

    await expect(t.sdk.setIdentity(identity)).resolves.toBeUndefined();

    expect(t.send).toHaveBeenCalledTimes(1);
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('recording the subscribe fingerprint'), expect.anything());
  });

  it('a fingerprint that cannot be written does not reject the re-subscribe check either', async () => {
    const t = load();
    await logIn(t);
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    const keychain = require('react-native-keychain');
    const original = keychain.setGenericPassword;
    jest.spyOn(keychain, 'setGenericPassword').mockImplementation(async (...args: any[]) => {
      if (args[2]?.service === FINGERPRINT_SERVICE) throw new Error('keychain refused');
      return original(...args);
    });
    t.setInfo({ osVersion: '15' });

    await t.sdk.initialize(baseConfig);
    await flush();

    expect(t.send).toHaveBeenCalledTimes(1);
    expect(warn).not.toHaveBeenCalledWith(expect.stringContaining('subscribe on start failed'), expect.anything());
    expect(warn).toHaveBeenCalledWith(expect.stringContaining('recording the subscribe fingerprint'), expect.anything());
  });
});

describe('getDeviceInfo export (RN-043)', () => {
  afterEach(() => jest.restoreAllMocks());

  it('is a passthrough to native, on the named and default exports', async () => {
    const t = load();
    const { getDeviceInfo } = require('../src');
    expect(t.sdk.getDeviceInfo).toBe(getDeviceInfo);
    await expect(getDeviceInfo()).resolves.toEqual(INFO);
  });

  it('propagates a native rejection', async () => {
    const t = load();
    t.getDeviceInfo.mockRejectedValue(new Error('E_INSTALLATION_ID_UNAVAILABLE'));
    await expect(t.sdk.getDeviceInfo()).rejects.toThrow('E_INSTALLATION_ID_UNAVAILABLE');
  });
});
