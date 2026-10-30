// startPushSocket resolves its URL from the initialized config when none
// is given, and refuses to start when the relay is disabled for the region.
//
// Each test loads a fresh copy of the SDK: the config and the socket module keep
// their state in module scope.

import { loadSdk } from './sdkTestKit';

const base = { projectID: 'p', clientID: 'c', configID: 'cfg' };
const custom = {
  ...base,
  env: 'custom' as const,
  customPushApiUrl: 'https://push.example.test',
  customChatApiUrl: 'https://chat.example.test',
  autoRegisterForToken: false,
};
const socketArgs = {
  authToken: 'tok',
  projectId: 'p',
  appId: 'app',
  userId: 'user-1',
};

function load() {
  const t = loadSdk();
  // The relay is opt-in; these tests are about what a start does once it is on.
  void t.native.setRelayEnabled(true);
  current = t;
  return t;
}

// The SDK polls the native store every 1.5s for as long as a socket is started
// (that poll is what recovers messages while JS is detached), so a test that
// starts one owns stopping it - including when an assertion throws on the way
// out, or jest never exits.
let current: ReturnType<typeof load> | null = null;

describe('startPushSocket url resolution (RN-046)', () => {
  afterEach(async () => {
    await current?.sdk.stopPushSocket();
    current = null;
    jest.useRealTimers();
  });

  /**
   * The url the last start handed to native, and the socket stopped again.
   * `nativeCalls` is how many calls native saw: exactly one per
   * `startPushSocket()` - a start refused by native (the relay off switch)
   * still reaches native, which owns the switch.
   */
  async function startedUrl(t: ReturnType<typeof load>, nativeCalls = 1) {
    try {
      const calls = t.native.startPushSocket.mock.calls;
      expect(calls).toHaveLength(nativeCalls);
      const cfg = calls[calls.length - 1][0] as { url: string };
      return cfg.url;
    } finally {
      await t.sdk.stopPushSocket();
    }
  }

  it('resolves the url from an initialized custom config', async () => {
    const t = load();
    await t.sdk.initialize({
      ...custom,
      socket: { customWsUrl: 'wss://relay.example.test/ws' },
    });
    await t.sdk.startPushSocket(socketArgs);
    expect(await startedUrl(t)).toBe('wss://relay.example.test/ws');
  });

  it('honours allowInsecureWs for a ws:// customWsUrl', async () => {
    const t = load();
    await t.sdk.initialize({
      ...custom,
      socket: { customWsUrl: 'ws://localhost:8080/ws', allowInsecureWs: true },
    });
    await t.sdk.startPushSocket(socketArgs);
    expect(await startedUrl(t)).toBe('ws://localhost:8080/ws');
  });

  describe('ws:// without allowInsecureWs', () => {
    const g = global as any;
    const hadDev = '__DEV__' in g;
    const originalDev = g.__DEV__;

    afterEach(() => {
      if (hadDev) {
        g.__DEV__ = originalDev;
      } else {
        delete g.__DEV__;
      }
    });

    it('is rejected in a release build', async () => {
      g.__DEV__ = false;
      const t = load();
      await t.sdk.initialize({
        ...custom,
        socket: { customWsUrl: 'ws://localhost:8080/ws' },
      });
      await expect(t.sdk.startPushSocket(socketArgs)).rejects.toMatchObject({
        code: 'E_WS_INSECURE',
      });
      expect(t.native.startPushSocket).not.toHaveBeenCalled();
    });

    it('is allowed in a __DEV__ build', async () => {
      g.__DEV__ = true;
      const t = load();
      await t.sdk.initialize({
        ...custom,
        socket: { customWsUrl: 'ws://localhost:8080/ws' },
      });
      await t.sdk.startPushSocket(socketArgs);
      expect(await startedUrl(t)).toBe('ws://localhost:8080/ws');
    });
  });

  it('rejects a non-ws customWsUrl with E_WS_NOT_CONFIGURED', async () => {
    const t = load();
    await t.sdk.initialize({
      ...custom,
      socket: { customWsUrl: 'https://relay.example.test/ws' },
    });
    await expect(t.sdk.startPushSocket(socketArgs)).rejects.toMatchObject({
      code: 'E_WS_NOT_CONFIGURED',
      message: expect.stringMatching(/^E_WS_NOT_CONFIGURED: /),
    });
    expect(t.native.startPushSocket).not.toHaveBeenCalled();
  });

  it('uses the latest initialize config when re-initialized', async () => {
    const t = load();
    await t.sdk.initialize({ ...base, env: 'eu1', autoRegisterForToken: false });
    await t.sdk.initialize({
      ...custom,
      socket: { customWsUrl: 'wss://relay.example.test/ws' },
    });
    await t.sdk.startPushSocket(socketArgs);
    expect(await startedUrl(t)).toBe('wss://relay.example.test/ws');
  });

  it.each([
    ['eu1', 'wss://relay.sinch-push.prod.sinch.com/ws'],
    ['us1', 'wss://relay.sinch-push.us1.prod.sinch.com/ws'],
  ] as const)('derives the relay of env "%s"', async (env, url) => {
    const t = load();
    await t.sdk.initialize({ ...base, env, autoRegisterForToken: false });
    await t.sdk.startPushSocket(socketArgs);
    expect(await startedUrl(t)).toBe(url);
  });

  it('derives the relay from a production push host', async () => {
    const t = load();
    await t.sdk.initialize({
      ...custom,
      customPushApiUrl: 'https://grpc.sinch-push.us1.prod.sinch.com',
    });
    await t.sdk.startPushSocket(socketArgs);
    expect(await startedUrl(t)).toBe(
      'wss://relay.sinch-push.us1.prod.sinch.com/ws'
    );
  });

  it('rejects with E_RELAY_DISABLED for a push host without a relay', async () => {
    const t = load();
    await t.sdk.initialize(custom);
    await expect(t.sdk.startPushSocket(socketArgs)).rejects.toMatchObject({
      code: 'E_RELAY_DISABLED',
      message: 'E_RELAY_DISABLED: no relay host for push host push.example.test',
    });
    expect(t.native.startPushSocket).not.toHaveBeenCalled();
    expect(t.native.stopPushSocket).not.toHaveBeenCalled();
  });

  it('leaves socket.enabled to native: the switch is persisted there (RN-048)', async () => {
    // initialize applies the switch natively, native refuses (its own refusal,
    // here, as the mocked switch JS reads stays on), and a runtime
    // setRelayEnabled(true) is not shadowed by the init config.
    const t = load();
    let off = false;
    t.native.setRelayEnabled = jest.fn(async (enabled: boolean) => {
      off = !enabled;
    });
    t.native.startPushSocket = jest.fn(async () => {
      if (off) {
        throw Object.assign(new Error('the relay is turned off'), {
          code: 'E_RELAY_DISABLED',
        });
      }
    });
    await t.sdk.initialize({
      ...custom,
      socket: { enabled: false, customWsUrl: 'wss://relay.example.test/ws' },
    });
    await expect(t.sdk.startPushSocket(socketArgs)).rejects.toMatchObject({
      code: 'E_RELAY_DISABLED',
    });
    // The refused start got as far as native, with the url resolved from the
    // init config.
    expect(t.native.startPushSocket.mock.calls[0][0]).toMatchObject({
      url: 'wss://relay.example.test/ws',
    });

    await t.sdk.setRelayEnabled(true);
    await t.sdk.startPushSocket(socketArgs);
    // Two starts, two native calls: no retry, and one start is never two calls.
    expect(await startedUrl(t, 2)).toBe('wss://relay.example.test/ws');
  });

  it('rejects with E_NOT_INITIALIZED when initialize was not called', async () => {
    const t = load();
    await expect(t.sdk.startPushSocket(socketArgs)).rejects.toMatchObject({
      code: 'E_NOT_INITIALIZED',
    });
    expect(t.native.startPushSocket).not.toHaveBeenCalled();
  });

  it('uses an explicit url unchanged, with no initialize and on a disabled region', async () => {
    const t = load();
    await t.sdk.startPushSocket({ ...socketArgs, url: 'ws://10.0.2.2:8080/ws' });
    expect(await startedUrl(t)).toBe('ws://10.0.2.2:8080/ws');

    const t2 = load();
    await t2.sdk.initialize({ ...base, env: 'eu1', autoRegisterForToken: false });
    await t2.sdk.startPushSocket({ ...socketArgs, url: 'ws://10.0.2.2:8080/ws' });
    expect(await startedUrl(t2)).toBe('ws://10.0.2.2:8080/ws');
  });
});
