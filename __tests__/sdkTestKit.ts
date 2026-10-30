// Shared setup for the Jest suites: a fresh copy of the SDK, the native
// defaults every suite needs, and a fake fetch. Per-suite state (the relay
// switch, the device info), the timing advances and the assertions stay in
// the suite that owns them.

export type SdkUnderTest = {
  sdk: typeof import('../src').default;
  native: any;
  send: jest.SpyInstance;
};

export const baseConfig = {
  projectID: 'project-1',
  clientID: 'client-1',
  configID: 'config-1',
  env: 'eu1' as const,
};

export const identity = { userID: 'alice', signedUserID: 'sig-1' };

/** Lets every promise continuation and the mocked I/O settle. */
export async function flush(): Promise<void> {
  for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
}

/**
 * A fresh copy of the SDK - its config, token, queue and timers live in module
 * scope - with the native and fetch defaults the suites share.
 */
export function loadSdk(): SdkUnderTest {
  jest.resetModules();
  const sdk = require('../src').default as typeof import('../src').default;
  const { NativeModules } = require('react-native');
  const native = NativeModules.SinchPush;
  const { DefaultPushRepository } = require('../src/api/pushRepository');

  const send = jest
    .spyOn(DefaultPushRepository.prototype, 'sendDeviceToken')
    .mockResolvedValue(undefined);

  native.startPushSocket = jest.fn(async () => undefined);
  native.stopPushSocket = jest.fn(async () => undefined);
  native.setSocketHandlerRegistered = jest.fn(async () => undefined);
  native.getPushSocketState = jest.fn(async () => ({ status: 'idle' }));
  native.getPendingPushMessages = jest.fn(async () => []);
  native.getReportOutbox = jest.fn(async () => []);
  native.removeReportOutboxEntries = jest.fn(async () => undefined);
  native.clearReportOutbox = jest.fn(async () => undefined);
  native.completeBackgroundWake = jest.fn(async () => undefined);
  native.configureSharedReports = jest.fn(async () => undefined);
  native.setSharedReportSession = jest.fn(async () => undefined);

  (global as any).fetch = async () => ({
    status: 200,
    statusText: 'OK',
    headers: new Headers({ 'content-type': 'application/grpc-web+proto' }),
    async arrayBuffer() {
      return new ArrayBuffer(0);
    },
  });

  return { sdk, native, send };
}

/** initialize + a token + setIdentity: the state after a normal login. */
export async function logIn(t: SdkUnderTest): Promise<void> {
  await t.sdk.initialize(baseConfig);
  t.sdk.setDeviceToken('token-1');
  await t.sdk.setIdentity(identity);
  await flush();
  t.send.mockClear();
}
