import * as Keychain from 'react-native-keychain';
import type { AuthModel, Region } from './authRepository';

export interface TokenStorage {
  read(): Promise<AuthModel | null>;
  save(token: AuthModel): Promise<void>;
  delete(): Promise<void>;
}

const SERVICE = 'com.sinch.push.auth';

export function accountKeyFor(config: {
  clientID: string;
  projectID: string;
  configID: string;
  region: Region;
  customPushApiUrl?: string;
}): string {
  const regionComponent =
    config.region === 'eu1'
      ? 'EU1'
      : config.region === 'us1'
        ? 'US1'
        : `custom.${config.customPushApiUrl ?? 'unknown'}`;
  return [
    config.clientID,
    config.projectID,
    config.configID,
    regionComponent,
  ].join('.');
}

export class KeychainTokenStorage implements TokenStorage {
  private readonly service: string;

  constructor(account: string) {
    this.service = `${SERVICE}.${account}`;
  }

  async read(): Promise<AuthModel | null> {
    const creds = await Keychain.getGenericPassword({ service: this.service });
    if (!creds || creds.password === '') return null;
    try {
      return JSON.parse(creds.password) as AuthModel;
    } catch {
      return null;
    }
  }

  async save(token: AuthModel): Promise<void> {
    await Keychain.setGenericPassword('token', JSON.stringify(token), {
      service: this.service,
      accessible: Keychain.ACCESSIBLE.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
    });
  }

  async delete(): Promise<void> {
    await Keychain.resetGenericPassword({ service: this.service });
  }
}