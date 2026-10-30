// The public getInstallationId() export: native owns the id, JS passes it on.

import SinchPush, { getInstallationId } from '../src';
import { NativeModules } from 'react-native';

const INSTALLATION_ID = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';

const nativeModule = () => NativeModules.SinchPush;

function setNativeInstallationId(value: string) {
  jest.spyOn(nativeModule(), 'getInstallationId').mockResolvedValue(value);
}

describe('getInstallationId (RN-041)', () => {
  beforeEach(() => setNativeInstallationId(INSTALLATION_ID));
  afterEach(() => jest.restoreAllMocks());

  it('is exported both as a named function and on the default object', () => {
    expect(typeof getInstallationId).toBe('function');
    expect(typeof SinchPush.getInstallationId).toBe('function');
    expect(SinchPush.getInstallationId).toBe(getInstallationId);
  });

  it('resolves with the id native reports', async () => {
    await expect(getInstallationId()).resolves.toBe(INSTALLATION_ID);
    await expect(SinchPush.getInstallationId()).resolves.toBe(INSTALLATION_ID);
  });

  it('calls native rather than answering from a constant of its own', async () => {
    await getInstallationId();
    expect(nativeModule().getInstallationId).toHaveBeenCalledTimes(1);
  });

  it('passes the native value through without rewriting it', async () => {
    // Lowercase canonical UUID, and the SDK is not the thing that enforces it:
    // if a future native build ever changed the shape, the value must arrive at
    // the host as-is rather than silently normalised.
    const other = '00000000-0000-4000-8000-000000000000';
    setNativeInstallationId(other);
    await expect(getInstallationId()).resolves.toBe(other);
  });

  it('propagates a native rejection instead of inventing an id', async () => {
    jest
      .spyOn(nativeModule(), 'getInstallationId')
      .mockRejectedValue(new Error('E_INSTALLATION_ID_UNAVAILABLE'));
    await expect(getInstallationId()).rejects.toThrow('E_INSTALLATION_ID_UNAVAILABLE');
  });
});