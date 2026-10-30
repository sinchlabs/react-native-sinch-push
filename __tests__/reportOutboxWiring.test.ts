// How the SDK drives the report outbox flusher: what triggers a flush and how
// identity changes treat the queue. The flusher itself is covered by
// reportOutbox.test.ts; here the push repository is spied and the native outbox
// is a plain array.

import { baseConfig, flush, identity, loadSdk } from './sdkTestKit';

const EVENT_REPORT_QUEUED = 'SinchPush:onReportQueued';
const EVENT_BACKGROUND_WAKE = 'SinchPushBackgroundWake';

function fire(event: string, payload: unknown = {}) {
  (global as any).__fireSinchPushEvent(event, payload);
}

function setAppState(state: 'active' | 'background' | 'inactive') {
  (global as any).__setAppState(state);
}

function load() {
  const t = loadSdk();
  const { DefaultAuthRepository, AuthModel } = require('../src/api/authRepository');
  const { DefaultPushRepository } = require('../src/api/pushRepository');

  // Real tokens: the faked fetch answers with an empty body, i.e. an empty JWT.
  let minted = 0;
  const mint = jest
    .spyOn(DefaultAuthRepository.prototype, 'createSignedToken')
    .mockImplementation(async (config: any, userId: any, secret: any) => {
      minted += 1;
      return new AuthModel({
        accessToken: `jwt-${userId}-${minted}`,
        sinchIdentity: { kind: 'selfSigned', userId, signedUserId: secret },
        clientID: config.clientID,
        projectID: config.projectID,
        configID: config.configID,
        region: config.region,
      });
    });
  const report = jest
    .spyOn(DefaultPushRepository.prototype, 'reportEvents')
    .mockResolvedValue(undefined);

  const queue: Array<{ messageId: string; subscriberId: string; enqueuedAt: number }> = [];
  const order: string[] = [];
  t.native.getReportOutbox = jest.fn(async () => [...queue]);
  t.native.removeReportOutboxEntries = jest.fn(async (entries: Array<{ messageId: string }>) => {
    const gone = new Set(entries.map((e) => e.messageId));
    queue.splice(0, queue.length, ...queue.filter((e) => !gone.has(e.messageId)));
  });
  t.native.clearReportOutbox = jest.fn(async () => {
    order.push('clear');
    queue.length = 0;
  });
  mint.mockImplementation(
    ((impl) => async (...args: unknown[]) => {
      order.push('mint');
      return (impl as any)(...args);
    })(mint.getMockImplementation()),
  );

  const enqueue = (n: number) =>
    queue.push({ messageId: `m${n}`, subscriberId: `s${n}`, enqueuedAt: Date.now() });

  return { ...t, report, queue, order, enqueue };
}

async function initialized(t: ReturnType<typeof load>) {
  await t.sdk.initialize(baseConfig);
  t.sdk.setDeviceToken('token-1');
  await flush();
}

/** Replaces the stored JWT with one minted for an anonymous identity. */
function storeAnonymousToken() {
  const { _store } = require('react-native-keychain');
  const key = [..._store.keys()].find((k: string) => k.startsWith('com.sinch.push.auth.'));
  const stored = JSON.parse(_store.get(key));
  _store.set(
    key,
    JSON.stringify({ ...stored, accessToken: 'jwt-anon', sinchIdentity: { kind: 'anonymous' } }),
  );
}

async function loggedIn(t: ReturnType<typeof load>) {
  await initialized(t);
  await t.sdk.setIdentity(identity);
  await flush();
  t.native.getReportOutbox.mockClear();
  t.report.mockClear();
  t.order.length = 0;
}

describe('the provider-push report outbox', () => {
  beforeEach(() => {
    jest.spyOn(console, 'warn').mockImplementation(() => {});
  });
  afterEach(() => jest.restoreAllMocks());

  describe('flush triggers', () => {
    it('flushes after setIdentity, reporting with the token it just minted', async () => {
      const t = load();
      await initialized(t);
      t.enqueue(1);

      await t.sdk.setIdentity(identity);
      await flush();

      expect(t.report).toHaveBeenCalledTimes(1);
      expect(t.report).toHaveBeenCalledWith([expect.objectContaining({ messageId: 'm1' })], 'jwt-alice-1');
      expect(t.queue).toEqual([]);
    });

    it('flushes on initialize when the app launches active with a stored token', async () => {
      const t = load();
      await loggedIn(t);
      t.enqueue(1);

      await t.sdk.initialize(baseConfig);
      await flush();

      expect(t.report).toHaveBeenCalledTimes(1);
      expect(t.queue).toEqual([]);
    });

    it('does not flush on initialize when the app launches in the background', async () => {
      const t = load();
      await loggedIn(t);
      setAppState('background');
      t.native.getReportOutbox.mockClear();
      t.enqueue(1);

      await t.sdk.initialize(baseConfig);
      await flush();

      expect(t.native.getReportOutbox).not.toHaveBeenCalled();
      expect(t.queue).toHaveLength(1);
    });

    it('does not flush on initialize before any token exists', async () => {
      const t = load();
      t.enqueue(1);

      await t.sdk.initialize(baseConfig);
      await flush();

      expect(t.native.getReportOutbox).not.toHaveBeenCalled();
    });

    it('makes no RPC after setIdentity when the outbox is empty', async () => {
      const t = load();
      await initialized(t);

      await t.sdk.setIdentity(identity);
      await flush();

      expect(t.native.getReportOutbox).toHaveBeenCalled();
      expect(t.report).not.toHaveBeenCalled();
    });

    it('does not flush when setIdentity fails', async () => {
      const t = load();
      await initialized(t);
      t.enqueue(1);

      await expect(t.sdk.setIdentity({ userID: 'alice', signedUserID: '' })).rejects.toThrow();
      await flush();

      expect(t.native.getReportOutbox).not.toHaveBeenCalled();
    });

    it('flushes on onReportQueued while the app is active and a token exists', async () => {
      const t = load();
      await loggedIn(t);
      t.enqueue(1);

      fire(EVENT_REPORT_QUEUED);
      await flush();

      expect(t.report).toHaveBeenCalledTimes(1);
    });

    it('does not flush on onReportQueued while the app is in the background', async () => {
      const t = load();
      await loggedIn(t);
      setAppState('background');
      t.native.getReportOutbox.mockClear();
      t.enqueue(1);

      fire(EVENT_REPORT_QUEUED);
      await flush();

      expect(t.native.getReportOutbox).not.toHaveBeenCalled();
      expect(t.report).not.toHaveBeenCalled();
      expect(t.queue).toHaveLength(1);
    });

    it('does not flush on onReportQueued before any token exists', async () => {
      const t = load();
      await initialized(t);
      t.enqueue(1);

      fire(EVENT_REPORT_QUEUED);
      await flush();

      expect(t.native.getReportOutbox).not.toHaveBeenCalled();
    });

    it('flushes what queued in the background when the app becomes active', async () => {
      const t = load();
      await loggedIn(t);
      setAppState('background');
      t.enqueue(1);
      fire(EVENT_REPORT_QUEUED);
      await flush();
      expect(t.report).not.toHaveBeenCalled();

      setAppState('active');
      await flush();

      expect(t.report).toHaveBeenCalledTimes(1);
      expect(t.queue).toEqual([]);
    });

    it('does not flush when the app moves to the background', async () => {
      const t = load();
      await loggedIn(t);
      t.enqueue(1);

      setAppState('background');
      await flush();

      expect(t.native.getReportOutbox).not.toHaveBeenCalled();
    });

    it('keeps the queue and does not throw when the transport fails', async () => {
      const t = load();
      await loggedIn(t);
      t.report.mockRejectedValue(new Error('offline'));
      jest.spyOn(global, 'setTimeout').mockImplementation(((fn: () => void) => {
        fn();
        return 0;
      }) as any);
      t.enqueue(1);

      fire(EVENT_REPORT_QUEUED);
      await flush();

      expect(t.queue).toHaveLength(1);
      expect(console.warn).toHaveBeenCalledWith(
        '[sinch] reporting delivered pushes failed',
        expect.any(Error),
      );
    });

    it('installs its listeners once however many times initialize runs', async () => {
      const t = load();
      await initialized(t);
      await t.sdk.initialize(baseConfig);

      expect((global as any).__sinchPushListenerCount()[EVENT_REPORT_QUEUED]).toBe(1);
      expect((global as any).__sinchPushAppStateListenerCount()).toBe(1);
    });
  });

  describe('identity', () => {
    it('does not clear the outbox when no token is stored', async () => {
      const t = load();
      await initialized(t);

      await t.sdk.setIdentity(identity);

      expect(t.native.clearReportOutbox).not.toHaveBeenCalled();
    });

    it('does not clear the outbox when the same identity is set again', async () => {
      const t = load();
      await loggedIn(t);

      await t.sdk.setIdentity(identity);

      expect(t.native.clearReportOutbox).not.toHaveBeenCalled();
    });

    it('keeps the outbox when the same user is signed again with a different signature', async () => {
      const t = load();
      await loggedIn(t);
      t.enqueue(1);

      await t.sdk.setIdentity({ userID: 'alice', signedUserID: 'sig-2' });

      expect(t.native.clearReportOutbox).not.toHaveBeenCalled();
      expect(t.order).toEqual(['mint']);
    });

    it('clears the outbox when an anonymous identity is replaced by a user', async () => {
      const t = load();
      await loggedIn(t);
      storeAnonymousToken();
      t.enqueue(1);

      await t.sdk.setIdentity(identity);

      expect(t.order).toEqual(['clear', 'mint']);
    });

    it('clears the outbox before minting the token of a different user', async () => {
      const t = load();
      await loggedIn(t);
      t.enqueue(1);

      await t.sdk.setIdentity({ userID: 'bob', signedUserID: 'sig-2' });

      expect(t.order).toEqual(['clear', 'mint']);
      expect(t.report).not.toHaveBeenCalled();
    });

    it('still sets the identity when clearing the outbox fails', async () => {
      const t = load();
      await loggedIn(t);
      t.native.clearReportOutbox.mockRejectedValue(new Error('bridge down'));

      await expect(
        t.sdk.setIdentity({ userID: 'bob', signedUserID: 'sig-2' }),
      ).resolves.toBeUndefined();

      expect(t.order).toEqual(['mint']);
      expect(console.warn).toHaveBeenCalledWith(
        '[sinch] clearing the report outbox failed',
        expect.any(Error),
      );
    });

    it('clears the outbox on removeIdentity', async () => {
      const t = load();
      await loggedIn(t);
      t.enqueue(1);

      await t.sdk.removeIdentity(identity);

      expect(t.native.clearReportOutbox).toHaveBeenCalledTimes(1);
      expect(t.queue).toEqual([]);
    });

    it('still removes the identity when clearing the outbox fails', async () => {
      const t = load();
      await loggedIn(t);
      t.native.clearReportOutbox.mockRejectedValue(new Error('bridge down'));

      await expect(t.sdk.removeIdentity(identity)).resolves.toBeUndefined();

      fire(EVENT_REPORT_QUEUED);
      await flush();
      expect(t.report).not.toHaveBeenCalled();
    });
  });

  describe('iOS background wake', () => {
    it('flushes once, then tells native the reports were sent', async () => {
      const t = load();
      await loggedIn(t);
      setAppState('background');
      t.enqueue(1);

      fire(EVENT_BACKGROUND_WAKE, { wakeId: 'wake-1' });
      await flush();

      expect(t.report).toHaveBeenCalledTimes(1);
      expect(t.queue).toEqual([]);
      expect(t.native.completeBackgroundWake).toHaveBeenCalledTimes(1);
      expect(t.native.completeBackgroundWake).toHaveBeenCalledWith('wake-1', true);
    });

    it('tells native `sent: false` when the reports could not be sent', async () => {
      const t = load();
      await loggedIn(t);
      setAppState('background');
      t.enqueue(1);
      t.report.mockRejectedValue(new Error('offline'));
      jest.useFakeTimers({ doNotFake: ['setImmediate', 'nextTick'] });

      fire(EVENT_BACKGROUND_WAKE, { wakeId: 'wake-2' });
      // The flusher backs off between its attempts; the wake gives up first.
      await jest.advanceTimersByTimeAsync(20_000);

      expect(t.native.completeBackgroundWake).toHaveBeenCalledTimes(1);
      expect(t.native.completeBackgroundWake).toHaveBeenCalledWith('wake-2', false);
      expect(t.queue).toHaveLength(1);
      jest.useRealTimers();
    });

    it('answers `sent: false` without a stored token (the flush cannot report)', async () => {
      const t = load();
      await initialized(t);
      setAppState('background');
      t.enqueue(1);

      fire(EVENT_BACKGROUND_WAKE, { wakeId: 'wake-3' });
      await flush();

      expect(t.report).not.toHaveBeenCalled();
      expect(t.native.completeBackgroundWake).toHaveBeenCalledWith('wake-3', false);
    });

    it('answers `sent: true` for an empty outbox', async () => {
      const t = load();
      await loggedIn(t);
      setAppState('background');

      fire(EVENT_BACKGROUND_WAKE, { wakeId: 'wake-4' });
      await flush();

      expect(t.report).not.toHaveBeenCalled();
      expect(t.native.completeBackgroundWake).toHaveBeenCalledWith('wake-4', true);
    });

    it('answers every wake it is given', async () => {
      const t = load();
      await loggedIn(t);
      t.enqueue(1);

      fire(EVENT_BACKGROUND_WAKE, { wakeId: 'a' });
      fire(EVENT_BACKGROUND_WAKE, { wakeId: 'b' });
      await flush();

      expect(t.report).toHaveBeenCalledTimes(1);
      expect(t.native.completeBackgroundWake.mock.calls.map((c: unknown[]) => c[0]).sort()).toEqual([
        'a',
        'b',
      ]);
    });

    it('holds a wake that beats initialize and answers it once initialize has run', async () => {
      const t = load();
      fire(EVENT_BACKGROUND_WAKE, { wakeId: 'early' });
      await flush();
      expect(t.native.completeBackgroundWake).not.toHaveBeenCalled();

      await t.sdk.initialize(baseConfig);
      await flush();

      expect(t.native.completeBackgroundWake).toHaveBeenCalledTimes(1);
      expect(t.native.completeBackgroundWake).toHaveBeenCalledWith('early', true);
    });

    it('answers `sent: false` within 20 s when initialize never runs', async () => {
      const t = load();
      jest.useFakeTimers({ doNotFake: ['setImmediate', 'nextTick'] });

      fire(EVENT_BACKGROUND_WAKE, { wakeId: 'never' });
      await jest.advanceTimersByTimeAsync(19_000);
      expect(t.native.completeBackgroundWake).not.toHaveBeenCalled();
      await jest.advanceTimersByTimeAsync(1_000);

      expect(t.native.completeBackgroundWake).toHaveBeenCalledTimes(1);
      expect(t.native.completeBackgroundWake).toHaveBeenCalledWith('never', false);
      jest.useRealTimers();
    });

    it('ignores an event without a wakeId', async () => {
      const t = load();
      await loggedIn(t);

      fire(EVENT_BACKGROUND_WAKE, {});
      await flush();

      expect(t.native.completeBackgroundWake).not.toHaveBeenCalled();
    });

    it('survives a native completeBackgroundWake that rejects', async () => {
      const t = load();
      await loggedIn(t);
      t.native.completeBackgroundWake.mockRejectedValue(new Error('gone'));

      fire(EVENT_BACKGROUND_WAKE, { wakeId: 'wake-5' });
      await flush();

      expect(console.warn).toHaveBeenCalledWith(
        '[sinch] completing the background wake failed',
        expect.any(Error),
      );
    });

    it('does not stack listeners over repeated initialize calls', async () => {
      const t = load();
      await loggedIn(t);
      await t.sdk.initialize(baseConfig);
      await t.sdk.initialize(baseConfig);

      fire(EVENT_BACKGROUND_WAKE, { wakeId: 'wake-6' });
      await flush();

      expect(t.native.completeBackgroundWake).toHaveBeenCalledTimes(1);
    });
  });
});
