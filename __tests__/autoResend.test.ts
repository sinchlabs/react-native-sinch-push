import SinchPush from '../src';
import { _store } from './__mocks__/react-native-keychain';

const baseConfig = {
  projectID: 'project-1',
  clientID: 'client-1',
  configID: 'config-1',
  env: 'eu1' as const,
};

function fireTokenReceived(token: string, type: 'apns' | 'fcm' = 'fcm') {
  (global as any).__fireSinchPushEvent('SinchPush:onTokenReceived', { token, type });
}

function PlatformOSForTest(): 'ios' | 'android' {
  const Platform = require('react-native').Platform as { OS: 'ios' | 'android' };
  return Platform.OS;
}

function defaultTokenTypeForTest(): 'apns' | 'fcm' {
  return PlatformOSForTest() === 'ios' ? 'apns' : 'fcm';
}

describe('auto device-token resend on token change', () => {
  let originalFetch: typeof globalThis.fetch;
  let subscribeCalls: Array<{ body: Uint8Array; url: string }>;

  function countSubscribe() {
    return subscribeCalls.filter((c) => c.url.endsWith('/Subscribe')).length;
  }

  beforeEach(() => {
    subscribeCalls = [];
    _store.clear();
    originalFetch = globalThis.fetch;
    (globalThis as any).fetch = async (url: string, init: any) => {
      const body = init?.body ? new Uint8Array(init.body as ArrayBuffer) : new Uint8Array();
      subscribeCalls.push({ url, body });
      return {
        status: 200,
        statusText: 'OK',
        headers: new Headers({ 'content-type': 'application/grpc-web+proto' }),
        async arrayBuffer() {
          return new ArrayBuffer(0);
        },
      } as any;
    };
  });

  afterEach(() => {
    (globalThis as any).fetch = originalFetch;
  });

  it('does nothing when no identity is set (not logged in)', async () => {
    await SinchPush.initialize(baseConfig);

    fireTokenReceived('fcm-token-1', 'fcm');

    await new Promise((r) => setImmediate(r));

    expect(countSubscribe()).toBe(0);
  });

  it('sends the token on setIdentity, then re-sends when the token rotates', async () => {
    await SinchPush.initialize(baseConfig);

    SinchPush.setDeviceToken('fcm-token-1');

    await SinchPush.setIdentity({
      userID: 'alice',
      signedUserID: 'sig-1',
    });

    expect(countSubscribe()).toBe(1);

    fireTokenReceived('fcm-token-rotated', defaultTokenTypeForTest());
    await new Promise((r) => setImmediate(r));

    expect(countSubscribe()).toBe(2);
  });

  it('does NOT re-send when the same token is delivered again', async () => {
    await SinchPush.initialize(baseConfig);

    SinchPush.setDeviceToken('fcm-token-1');

    await SinchPush.setIdentity({
      userID: 'alice',
      signedUserID: 'sig-1',
    });

    const countAfterLogin = countSubscribe();
    expect(countAfterLogin).toBe(1);

    fireTokenReceived('fcm-token-1', defaultTokenTypeForTest());
    await new Promise((r) => setImmediate(r));

    expect(countSubscribe()).toBe(1);
  });

  it('ignores token events whose type does not match the platform', async () => {
    await SinchPush.initialize(baseConfig);

    await SinchPush.setIdentity({
      userID: 'alice',
      signedUserID: 'sig-1',
    });

    const countAfterLogin = countSubscribe();

    fireTokenReceived('token-x', PlatformOSForTest() === 'ios' ? 'fcm' : 'apns');
    await new Promise((r) => setImmediate(r));

    expect(countSubscribe()).toBe(countAfterLogin);
  });

  it('clears the last-sent device token on removeIdentity', async () => {
    await SinchPush.initialize(baseConfig);

    SinchPush.setDeviceToken('fcm-token-1');

    await SinchPush.setIdentity({
      userID: 'alice',
      signedUserID: 'sig-1',
    });

    const keychain = require('react-native-keychain');
    const before = await keychain.getGenericPassword({ service: 'com.sinch.push.deviceToken' });
    expect(before).not.toBe(false);
    expect(before?.password).toBe('fcm-token-1');

    await SinchPush.removeIdentity({
      userID: 'alice',
      signedUserID: 'sig-1',
    });

    const after = await keychain.getGenericPassword({ service: 'com.sinch.push.deviceToken' });
    expect(after === false || after?.password === '').toBe(true);
  });
});
