// startPushSocket without credentials: authToken defaults to the JWT setIdentity
// stored, appId / userId to its claims, projectId to initialize's projectID.
// A new JWT restarts the socket with it.

import { flush, loadSdk } from './sdkTestKit';

const config = {
  projectID: 'project-1',
  clientID: 'client-1',
  configID: 'config-1',
  env: 'eu1' as const,
  autoRegisterForToken: false,
};

function jwt(claims: Record<string, unknown>): string {
  const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return `${b64({ alg: 'HS256' })}.${b64(claims)}.sig`;
}

function load() {
  const t = loadSdk();
  // The relay is opt-in; these tests are about what a start does once it is on.
  void t.native.setRelayEnabled(true);
  const { DefaultAuthRepository, AuthModel } = require('../src/api/authRepository');
  jest
    .spyOn(DefaultAuthRepository.prototype, 'createSignedToken')
    .mockImplementation(async (c: any, userId: any, secret: any) => {
      return new AuthModel({
        accessToken: jwt({
          appId: 'app-from-jwt',
          uuid: `uuid-${userId}-${secret}`,
          projectId: 'project-1',
        }),
        sinchIdentity: { kind: 'selfSigned', userId, signedUserId: secret },
        clientID: c.clientID,
        projectID: c.projectID,
        configID: c.configID,
        region: c.region,
      });
    });
  current = t;
  return t;
}

let current: ReturnType<typeof load> | null = null;

const startedWith = (t: ReturnType<typeof load>, call = 0) =>
  t.native.startPushSocket.mock.calls[call][0] as Record<string, unknown>;

describe('push socket credentials default to the stored JWT', () => {
  beforeEach(() => {
    jest.spyOn(console, 'warn').mockImplementation(() => {});
  });
  afterEach(async () => {
    await current?.sdk.stopPushSocket();
    current = null;
    jest.restoreAllMocks();
  });

  it('takes authToken, appId and userId from the stored JWT and projectId from initialize', async () => {
    const t = load();
    await t.sdk.initialize(config);
    await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });
    await t.sdk.startPushSocket({});

    const token = jwt({
      appId: 'app-from-jwt',
      uuid: 'uuid-alice-s1',
      projectId: 'project-1',
    });
    expect(startedWith(t)).toMatchObject({
      url: 'wss://relay.sinch-push.prod.sinch.com/ws',
      authToken: token,
      appId: 'app-from-jwt',
      userId: 'uuid-alice-s1',
      projectId: 'project-1',
    });
  });

  it('lets explicit values win', async () => {
    const t = load();
    await t.sdk.initialize(config);
    await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });
    await t.sdk.startPushSocket({
      authToken: 'explicit',
      appId: 'a',
      userId: 'u',
      projectId: 'p',
    });
    expect(startedWith(t)).toMatchObject({
      authToken: 'explicit',
      appId: 'a',
      userId: 'u',
      projectId: 'p',
    });
  });

  it('derives appId / userId from an explicit authToken', async () => {
    const t = load();
    await t.sdk.initialize(config);
    await t.sdk.startPushSocket({
      authToken: jwt({ appId: 'x', uuid: 'y' }),
    });
    expect(startedWith(t)).toMatchObject({ appId: 'x', userId: 'y' });
  });

  it('rejects with E_NOT_AUTHENTICATED before setIdentity', async () => {
    const t = load();
    await t.sdk.initialize(config);
    await expect(t.sdk.startPushSocket({})).rejects.toMatchObject({
      code: 'E_NOT_AUTHENTICATED',
    });
    expect(t.native.startPushSocket).not.toHaveBeenCalled();
  });

  it('rejects when the JWT carries no appId / uuid and none was given', async () => {
    const t = load();
    await t.sdk.initialize(config);
    await expect(
      t.sdk.startPushSocket({ authToken: 'opaque-token' })
    ).rejects.toThrow(/requires appId and userId/);
    expect(t.native.startPushSocket).not.toHaveBeenCalled();
  });

  it('rejects an expired token with E_NOT_AUTHENTICATED', async () => {
    const t = load();
    await t.sdk.initialize(config);
    await expect(
      t.sdk.startPushSocket({
        authToken: jwt({ appId: 'a', uuid: 'u', exp: Math.floor(Date.now() / 1000) - 60 }),
      })
    ).rejects.toMatchObject({ code: 'E_NOT_AUTHENTICATED' });
    expect(t.native.startPushSocket).not.toHaveBeenCalled();
  });

  it('accepts a token that has not expired yet', async () => {
    const t = load();
    await t.sdk.initialize(config);
    await t.sdk.startPushSocket({
      authToken: jwt({ appId: 'a', uuid: 'u', exp: Math.floor(Date.now() / 1000) + 600 }),
    });
    expect(t.native.startPushSocket).toHaveBeenCalledTimes(1);
  });

  it('rejects a non-JWT token without appId / userId as E_NOT_AUTHENTICATED', async () => {
    const t = load();
    await t.sdk.initialize(config);
    await expect(
      t.sdk.startPushSocket({ authToken: 'opaque-token' })
    ).rejects.toMatchObject({ code: 'E_NOT_AUTHENTICATED' });
  });

  it('accepts a non-JWT token when appId and userId are given', async () => {
    const t = load();
    await t.sdk.initialize(config);
    await t.sdk.startPushSocket({ authToken: 'opaque', appId: 'a', userId: 'u' });
    expect(startedWith(t)).toMatchObject({ authToken: 'opaque', appId: 'a', userId: 'u' });
  });

  it("prefers the JWT's projectId over initialize's, and warns about the difference", async () => {
    const t = load();
    await t.sdk.initialize(config);
    await t.sdk.startPushSocket({
      authToken: jwt({ appId: 'a', uuid: 'u', projectId: 'project-from-jwt' }),
    });
    expect(startedWith(t)).toMatchObject({ projectId: 'project-from-jwt' });
    expect(console.warn).toHaveBeenCalledWith(expect.stringContaining('project-from-jwt'));
  });

  it("falls back to initialize's projectID when the JWT has no projectId", async () => {
    const t = load();
    await t.sdk.initialize(config);
    await t.sdk.startPushSocket({ authToken: jwt({ appId: 'a', uuid: 'u' }) });
    expect(startedWith(t)).toMatchObject({ projectId: 'project-1' });
  });

  describe('start / stop / restart are serialized', () => {
    function gate() {
      let release!: () => void;
      const promise = new Promise<void>((resolve) => {
        release = resolve;
      });
      return { promise, release };
    }

    it('a removeIdentity during a restart still stops the socket', async () => {
      const t = load();
      await t.sdk.initialize(config);
      await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });
      await t.sdk.startPushSocket({});

      // bob's restart gets stuck in native ...
      const held = gate();
      t.native.startPushSocket.mockImplementationOnce(async () => held.promise);
      await t.sdk.setIdentity({ userID: 'bob', signedUserID: 's2' });
      await flush();
      expect(t.native.startPushSocket).toHaveBeenCalledTimes(2);

      // ... the identity is removed meanwhile ...
      const removal = t.sdk.removeIdentity({ userID: 'bob', signedUserID: 's2' });
      await flush();
      held.release();
      await removal;
      await flush();

      // ... and the socket must end up stopped, not running bob's JWT.
      const lastStart = Math.max(...t.native.startPushSocket.mock.invocationCallOrder);
      const lastStop = Math.max(...t.native.stopPushSocket.mock.invocationCallOrder);
      expect(lastStop).toBeGreaterThan(lastStart);
      expect(t.native.startPushSocket).toHaveBeenCalledTimes(2);

      // A stopped socket is not revived by the next identity.
      await t.sdk.setIdentity({ userID: 'carol', signedUserID: 's3' });
      await flush();
      expect(t.native.startPushSocket).toHaveBeenCalledTimes(2);
    });

    it('a stopPushSocket during a restart wins over it', async () => {
      const t = load();
      await t.sdk.initialize(config);
      await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });
      await t.sdk.startPushSocket({});

      const held = gate();
      t.native.startPushSocket.mockImplementationOnce(async () => held.promise);
      await t.sdk.setIdentity({ userID: 'bob', signedUserID: 's2' });
      await flush();

      const stopsBefore = t.native.stopPushSocket.mock.calls.length;
      const stopped = t.sdk.stopPushSocket();
      await flush();
      // The stop waits its turn behind the held restart.
      expect(t.native.stopPushSocket).toHaveBeenCalledTimes(stopsBefore);
      held.release();
      await stopped;

      const lastStart = Math.max(...t.native.startPushSocket.mock.invocationCallOrder);
      const lastStop = Math.max(...t.native.stopPushSocket.mock.invocationCallOrder);
      expect(lastStop).toBeGreaterThan(lastStart);
      expect(t.native.startPushSocket).toHaveBeenCalledTimes(2);

      // The stop cleared the requested config, so the next identity revives nothing.
      await t.sdk.setIdentity({ userID: 'carol', signedUserID: 's3' });
      await flush();
      expect(t.native.startPushSocket).toHaveBeenCalledTimes(2);
    });

    it('a setIdentity during the first startPushSocket restarts it with the new JWT', async () => {
      const t = load();
      await t.sdk.initialize(config);
      await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });

      const held = gate();
      t.native.startPushSocket.mockImplementationOnce(async () => held.promise);
      const started = t.sdk.startPushSocket({});
      await flush();

      await t.sdk.setIdentity({ userID: 'bob', signedUserID: 's2' });
      held.release();
      await started;
      await flush();

      expect(t.native.startPushSocket).toHaveBeenCalledTimes(2);
      expect(startedWith(t, 0)).toMatchObject({ userId: 'uuid-alice-s1' });
      expect(startedWith(t, 1)).toMatchObject({ userId: 'uuid-bob-s2' });
    });

    it('does not let a failed start poison the queue', async () => {
      const t = load();
      await t.sdk.initialize(config);
      await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });
      t.native.startPushSocket.mockRejectedValueOnce(new Error('refused'));
      await expect(t.sdk.startPushSocket({})).rejects.toThrow('refused');

      await t.sdk.startPushSocket({});
      expect(t.native.startPushSocket).toHaveBeenCalledTimes(2);
    });
  });

  describe('a new JWT reaches the native client', () => {
    it('restarts the socket with the token and claims of a new identity', async () => {
      const t = load();
      await t.sdk.initialize(config);
      await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });
      await t.sdk.startPushSocket({});

      await t.sdk.setIdentity({ userID: 'bob', signedUserID: 's2' });
      await flush();

      expect(t.native.startPushSocket).toHaveBeenCalledTimes(2);
      expect(startedWith(t, 1)).toMatchObject({
        userId: 'uuid-bob-s2',
        authToken: jwt({
          appId: 'app-from-jwt',
          uuid: 'uuid-bob-s2',
          projectId: 'project-1',
        }),
      });
    });

    it('leaves the socket alone when the JWT did not change', async () => {
      const t = load();
      await t.sdk.initialize(config);
      await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });
      await t.sdk.startPushSocket({});

      await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });

      expect(t.native.startPushSocket).toHaveBeenCalledTimes(1);
    });

    it('leaves a pinned authToken alone', async () => {
      const t = load();
      await t.sdk.initialize(config);
      await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });
      await t.sdk.startPushSocket({ authToken: 'pinned', appId: 'a', userId: 'u' });

      await t.sdk.setIdentity({ userID: 'bob', signedUserID: 's2' });

      expect(t.native.startPushSocket).toHaveBeenCalledTimes(1);
    });

    it('does not restart a socket the host stopped', async () => {
      const t = load();
      await t.sdk.initialize(config);
      await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });
      await t.sdk.startPushSocket({});
      await t.sdk.stopPushSocket();

      await t.sdk.setIdentity({ userID: 'bob', signedUserID: 's2' });

      expect(t.native.startPushSocket).toHaveBeenCalledTimes(1);
    });

    it('stops the socket when the identity is removed', async () => {
      const t = load();
      await t.sdk.initialize(config);
      await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });
      await t.sdk.startPushSocket({});
      t.native.stopPushSocket.mockClear();

      await t.sdk.removeIdentity({ userID: 'alice', signedUserID: 's1' });
      await flush();

      expect(t.native.stopPushSocket).toHaveBeenCalledTimes(1);
      expect(t.native.startPushSocket).toHaveBeenCalledTimes(1);
    });

    it('does not fail setIdentity when the restart fails', async () => {
      const t = load();
      await t.sdk.initialize(config);
      await t.sdk.setIdentity({ userID: 'alice', signedUserID: 's1' });
      await t.sdk.startPushSocket({});
      t.native.startPushSocket.mockRejectedValue(new Error('refused'));

      await expect(
        t.sdk.setIdentity({ userID: 'bob', signedUserID: 's2' })
      ).resolves.toBeUndefined();
      await flush();
      expect(console.warn).toHaveBeenCalled();
    });
  });
});
