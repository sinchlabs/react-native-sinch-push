import * as Keychain from 'react-native-keychain';

const SERVICE = 'com.sinch.push.deviceToken';
const ACCOUNT = 'lastSent';
// A separate service: react-native-keychain keys an item by service, so the
// fingerprint would otherwise overwrite `lastSent`.
const FINGERPRINT_SERVICE = 'com.sinch.push.subscribeFingerprint';
const FINGERPRINT_ACCOUNT = 'lastSubscribedFingerprint';

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

  /**
   * Optional: a host that implements all three keeps its own fingerprint
   * record; otherwise the SDK uses the built-in Keychain store.
   */
  readLastSubscribedFingerprint?(): Promise<string | null>;
  writeLastSubscribedFingerprint?(fingerprint: string): Promise<void>;
  clearLastSubscribedFingerprint?(): Promise<void>;
}

/**
 * What the last successful `Subscribe` was made with: the token plus the
 * device facts the push API was told, as one opaque comparable string.
 * `read` is `null` when none was recorded, which reads as "changed".
 */
export interface FingerprintStore {
  readLastSubscribedFingerprint(): Promise<string | null>;
  writeLastSubscribedFingerprint(fingerprint: string): Promise<void>;
  clearLastSubscribedFingerprint(): Promise<void>;
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

export class KeychainFingerprintStore implements FingerprintStore {
  async readLastSubscribedFingerprint(): Promise<string | null> {
    const creds = await Keychain.getGenericPassword({ service: FINGERPRINT_SERVICE });
    if (!creds || creds.password === '') return null;
    return creds.password;
  }

  async writeLastSubscribedFingerprint(fingerprint: string): Promise<void> {
    await Keychain.setGenericPassword(FINGERPRINT_ACCOUNT, fingerprint, {
      service: FINGERPRINT_SERVICE,
      accessible: Keychain.ACCESSIBLE.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
    });
  }

  async clearLastSubscribedFingerprint(): Promise<void> {
    await Keychain.resetGenericPassword({ service: FINGERPRINT_SERVICE });
  }
}

export const defaultDeviceTokenStorage: DeviceTokenStorage =
  new KeychainDeviceTokenStorage();

export const defaultFingerprintStore: FingerprintStore =
  new KeychainFingerprintStore();

export function resolveFingerprintStore(
  storage: DeviceTokenStorage,
): FingerprintStore {
  if (
    typeof storage.readLastSubscribedFingerprint === 'function' &&
    typeof storage.writeLastSubscribedFingerprint === 'function' &&
    typeof storage.clearLastSubscribedFingerprint === 'function'
  ) {
    return storage as FingerprintStore;
  }
  return defaultFingerprintStore;
}
