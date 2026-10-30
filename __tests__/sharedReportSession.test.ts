// The credential mirror: what JS tells native about the App Group (iOS) and the
// minimal report record (iOS and Android), and when. Native storage, the
// extension and the background upload are covered by the native tests.

import { baseConfig, flush, identity, loadSdk } from './sdkTestKit';

// Header.Payload.Signature; the payload is {"appId":"app-1","uuid":"uuid-1","exp":4102444800}.
const jwt = (payload: object) =>
  `e30.${Buffer.from(JSON.stringify(payload)).toString('base64url')}.sig`;

function load() {
  const t = loadSdk();
  const { DefaultAuthRepository, AuthModel } = require('../src/api/authRepository');
  const accessToken = jwt({ appId: 'app-1', uuid: 'uuid-1', exp: 4102444800 });
  jest.spyOn(DefaultAuthRepository.prototype, 'createSignedToken').mockImplementation(
    async (config: any, userId: any, secret: any) =>
      new AuthModel({
        accessToken,
        sinchIdentity: { kind: 'selfSigned', userId, signedUserId: secret },
        clientID: config.clientID,
        projectID: config.projectID,
        configID: config.configID,
        region: config.region,
      }),
  );
  return { ...t, accessToken };
}

describe('mirroring the report credential to native', () => {
  beforeEach(() => {
    jest.spyOn(console, 'warn').mockImplementation(() => {});
  });
  afterEach(() => {
    jest.restoreAllMocks();
    require('react-native').Platform.OS = 'ios';
  });

  it('passes ios.appGroup to native on initialize, and null when there is none', async () => {
    const t = load();
    await t.sdk.initialize({ ...baseConfig, ios: { appGroup: 'group.com.example' } });
    expect(t.native.configureSharedReports).toHaveBeenLastCalledWith('group.com.example');

    await t.sdk.initialize(baseConfig);
    expect(t.native.configureSharedReports).toHaveBeenLastCalledWith(null);
  });

  it('mirrors { accessToken, reportBaseURL, userId, appId } after setIdentity, after the group is configured', async () => {
    const t = load();
    const order: string[] = [];
    t.native.configureSharedReports.mockImplementation(async () => void order.push('configure'));
    t.native.setSharedReportSession.mockImplementation(async () => void order.push('set'));
    await t.sdk.initialize({ ...baseConfig, ios: { appGroup: 'group.com.example' } });
    await t.sdk.setIdentity(identity);
    await flush();

    expect(t.native.setSharedReportSession).toHaveBeenCalledWith({
      accessToken: t.accessToken,
      reportBaseURL: 'https://grpc.sinch-push.prod.sinch.com',
      userId: 'alice',
      appId: 'app-1',
    });
    expect(order[0]).toBe('configure');
    expect(JSON.stringify(t.native.setSharedReportSession.mock.calls)).not.toContain('sig-1');
  });

  it('uses the custom push host as the report base URL', async () => {
    const t = load();
    await t.sdk.initialize({
      ...baseConfig,
      env: 'custom',
      customPushApiUrl: 'https://push.example.test',
      customChatApiUrl: 'https://chat.example.test',
    });
    await t.sdk.setIdentity(identity);
    await flush();
    expect(t.native.setSharedReportSession).toHaveBeenCalledWith(
      expect.objectContaining({ reportBaseURL: 'https://push.example.test' }),
    );
  });

  it('re-mirrors the stored credential on a later initialize', async () => {
    const t = load();
    await t.sdk.initialize(baseConfig);
    await t.sdk.setIdentity(identity);
    await flush();
    t.native.setSharedReportSession.mockClear();

    await t.sdk.initialize(baseConfig);
    await flush();
    expect(t.native.setSharedReportSession).toHaveBeenCalledTimes(1);
  });

  it('clears the mirror on removeIdentity', async () => {
    const t = load();
    await t.sdk.initialize(baseConfig);
    await t.sdk.setIdentity(identity);
    await flush();
    t.native.setSharedReportSession.mockClear();

    await t.sdk.removeIdentity(identity);
    expect(t.native.setSharedReportSession).toHaveBeenCalledWith(null);
  });

  it('mirrors nothing before there is an identity, and clears what a previous initialize left', async () => {
    const t = load();
    await t.sdk.initialize(baseConfig);
    await flush();
    expect(t.native.setSharedReportSession.mock.calls).toEqual([[null]]);
  });

  it('clears the previous session when initialize switches to an account without a token', async () => {
    const t = load();
    await t.sdk.initialize(baseConfig);
    await t.sdk.setIdentity(identity);
    await flush();
    t.native.setSharedReportSession.mockClear();

    // Another project: its own (empty) token slot, so the old reportBaseURL + JWT must go.
    await t.sdk.initialize({ ...baseConfig, projectID: 'project-2' });
    await flush();
    expect(t.native.setSharedReportSession.mock.calls).toEqual([[null]]);
  });

  it('does not clear a session that setIdentity stored while initialize was still reading', async () => {
    const t = load();
    await t.sdk.initialize(baseConfig);
    t.sdk.setDeviceToken('token-1');
    await t.sdk.setIdentity(identity);
    await t.sdk.initialize({ ...baseConfig, projectID: 'project-2' });
    t.native.setSharedReportSession.mockClear();
    // The first read (at initialize) found nothing; a login lands before the re-check.
    await t.sdk.setIdentity(identity);
    await flush();
    const calls = t.native.setSharedReportSession.mock.calls;
    expect(calls[calls.length - 1]).toEqual([expect.objectContaining({ userId: 'alice' })]);
  });

  it('does not stop setIdentity when native cannot mirror', async () => {
    const t = load();
    t.native.setSharedReportSession.mockRejectedValue(new Error('no keychain'));
    await t.sdk.initialize(baseConfig);
    t.sdk.setDeviceToken('token-1');
    await expect(t.sdk.setIdentity(identity)).resolves.toBeUndefined();
    expect(t.send).toHaveBeenCalled();
  });

  it('leaves the App Group to iOS, but mirrors and clears the record on Android', async () => {
    const t = load();
    require('react-native').Platform.OS = 'android';
    await t.sdk.initialize({ ...baseConfig, ios: { appGroup: 'group.com.example' } });
    await t.sdk.setIdentity(identity);
    await flush();
    expect(t.native.configureSharedReports).not.toHaveBeenCalled();
    expect(t.native.setSharedReportSession).toHaveBeenCalledWith({
      accessToken: t.accessToken,
      reportBaseURL: 'https://grpc.sinch-push.prod.sinch.com',
      userId: 'alice',
      appId: 'app-1',
    });

    t.native.setSharedReportSession.mockClear();
    await t.sdk.removeIdentity(identity);
    expect(t.native.setSharedReportSession).toHaveBeenLastCalledWith(null);
  });

  it('re-mirrors the stored credential on Android when initialize finds a stored token', async () => {
    const t = load();
    require('react-native').Platform.OS = 'android';
    await t.sdk.initialize(baseConfig);
    await t.sdk.setIdentity(identity);
    await flush();
    t.native.setSharedReportSession.mockClear();

    await t.sdk.initialize(baseConfig);
    await flush();
    expect(t.native.setSharedReportSession).toHaveBeenCalledTimes(1);
    expect(t.native.setSharedReportSession).toHaveBeenCalledWith(
      expect.objectContaining({ accessToken: t.accessToken }),
    );
  });

  it('mirrors nothing on Android before there is an identity', async () => {
    const t = load();
    require('react-native').Platform.OS = 'android';
    await t.sdk.initialize(baseConfig);
    await flush();
    expect(t.native.setSharedReportSession.mock.calls).toEqual([[null]]);
  });
});

describe('the mirror and removeIdentity (iOS)', () => {
  beforeEach(() => {
    jest.spyOn(console, 'warn').mockImplementation(() => {});
  });
  afterEach(() => {
    jest.restoreAllMocks();
    require('react-native').Platform.OS = 'ios';
  });

  it('ends with the shared session cleared when removeIdentity races the start-up mirror', async () => {
    const t = load();
    await t.sdk.initialize(baseConfig);
    await t.sdk.setIdentity(identity);
    await flush();
    t.native.setSharedReportSession.mockClear();

    // A slow read of the stored credential: whoever reads it before removeIdentity deleted it
    // still holds the old JWT when removeIdentity is done.
    const { DefaultAuthDataSource } = require('../src/api/authDataSource');
    const read = DefaultAuthDataSource.prototype.currentAuthorization;
    jest
      .spyOn(DefaultAuthDataSource.prototype, 'currentAuthorization')
      .mockImplementation(async function (this: unknown) {
        const stored = await read.call(this);
        await new Promise((r) => setTimeout(r, 20));
        return stored;
      });

    const init = t.sdk.initialize(baseConfig);
    const removed = t.sdk.removeIdentity(identity);
    await Promise.all([init, removed]);
    await new Promise((r) => setTimeout(r, 100));
    await flush();

    const calls = t.native.setSharedReportSession.mock.calls;
    expect(calls.length).toBeGreaterThan(0);
    expect(calls[calls.length - 1]).toEqual([null]);
  });

  it('clears the shared session even when deleting the token throws', async () => {
    const t = load();
    await t.sdk.initialize(baseConfig);
    await t.sdk.setIdentity(identity);
    await flush();
    t.native.setSharedReportSession.mockClear();
    const { DefaultAuthDataSource } = require('../src/api/authDataSource');
    jest.spyOn(DefaultAuthDataSource.prototype, 'deleteToken').mockRejectedValue(new Error('keychain'));

    await expect(t.sdk.removeIdentity(identity)).rejects.toThrow('keychain');
    expect(t.native.setSharedReportSession).toHaveBeenCalledWith(null);
  });
});
