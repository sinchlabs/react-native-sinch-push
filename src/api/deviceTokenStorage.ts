import * as Keychain from 'react-native-keychain';

const SERVICE = 'com.sinch.push.deviceToken';
const ACCOUNT = 'lastSent';

/**
 * Persists the device token most recently sent to the Sinch push backend so we
 * can decide whether a fresh `Subscribe` call is needed on app start (the FCM
 * token rotates over the lifetime of an install).
 *
 * Lives in a separate Keychain service from the auth JWT so that clearing
 * authentication on logout also clears the "we already subscribed with this
 * token" record.
 */
export interface DeviceTokenStorage {
  readLastSent(): Promise<string | null>;
  writeLastSent(token: string): Promise<void>;
  clearLastSent(): Promise<void>;
}

export class KeychainDeviceTokenStorage implements DeviceTokenStorage {
  async readLastSent(): Promise<string | null> {
    const creds = await Keychain.getGenericPassword({ service: SERVICE });
    if (!creds || creds.password === '') return null;
    return creds.password;
  }

  async writeLastSent(token: string): Promise<void> {
    await Keychain.setGenericPassword(ACCOUNT, token, {
      service: SERVICE,
      accessible: Keychain.ACCESSIBLE.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
    });
  }

  async clearLastSent(): Promise<void> {
    await Keychain.resetGenericPassword({ service: SERVICE });
  }
}

export const defaultDeviceTokenStorage: DeviceTokenStorage =
  new KeychainDeviceTokenStorage();
