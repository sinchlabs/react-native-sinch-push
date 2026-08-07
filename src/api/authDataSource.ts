import type {
  AppConfig,
  AuthModel,
  AuthRepository,
  SinchIdentity,
} from './authRepository';
import { setAuthToken } from './transport';
import type { TokenStorage } from './tokenStorage';

export interface AuthDataSource {
  generateToken(config: AppConfig, identity: SinchIdentity): Promise<AuthModel>;
  currentAccessToken(): Promise<string | null>;
  currentAuthorization(): Promise<AuthModel | null>;
  isLoggedIn(): Promise<boolean>;
  identityHashValue(): Promise<string | null>;
  deleteToken(): Promise<void>;
}

export class DefaultAuthDataSource implements AuthDataSource {
  constructor(
    private readonly repo: AuthRepository,
    private readonly storage: TokenStorage,
  ) {}

  async generateToken(
    config: AppConfig,
    identity: SinchIdentity,
  ): Promise<AuthModel> {
    const cached = await this.storage.read();
    if (
      cached &&
      cached.clientID === config.clientID &&
      cached.projectID === config.projectID &&
      cached.configID === config.configID &&
      cached.region === config.region &&
      identityHashOf(identity) === cached.identityHash
    ) {
      setAuthToken(cached.accessToken);
      return cached;
    }

    let token: AuthModel;
    if (identity.kind === 'anonymous') {
      token = await this.repo.createAnonymousToken(config);
    } else if (identity.kind === 'selfSigned') {
      token = await this.repo.createSignedToken(
        config,
        identity.userId,
        identity.signedUserId,
      );
    } else {
      const secret = await hmacSha512Hex(identity.userId, identity.appSecret);
      token = await this.repo.createSignedToken(config, identity.userId, secret);
    }

    await this.storage.save(token);
    setAuthToken(token.accessToken);
    return token;
  }

  async currentAccessToken(): Promise<string | null> {
    const m = await this.storage.read();
    return m?.accessToken ?? null;
  }

  async currentAuthorization(): Promise<AuthModel | null> {
    return this.storage.read();
  }

  async isLoggedIn(): Promise<boolean> {
    return (await this.storage.read()) !== null;
  }

  async identityHashValue(): Promise<string | null> {
    const m = await this.storage.read();
    return m?.identityHash ?? null;
  }

  async deleteToken(): Promise<void> {
    await this.storage.delete();
    setAuthToken(null);
  }
}

function identityHashOf(identity: SinchIdentity): string {
  if (identity.kind === 'selfSignedWithAppSecret') {
    return `selfSigned.${identity.userId}`;
  }
  if (identity.kind === 'selfSigned') {
    return `selfSigned.${identity.userId}.${identity.signedUserId}`;
  }
  return `anonymous`;
}

async function hmacSha512Hex(message: string, key: string): Promise<string> {
  const CryptoJS = await import('crypto-js');
  return CryptoJS.HmacSHA512(message, key).toString(CryptoJS.enc.Hex);
}