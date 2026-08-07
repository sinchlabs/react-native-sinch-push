import { create } from '@bufbuild/protobuf';
import {
  IssueTokenWithSignedUuidResponseSchema,
} from '../src/generated/sinch/chat/sdk/v1alpha2/sdk_pb';
import { AuthModel } from '../src/api/authRepository';
import { DefaultAuthDataSource } from '../src/api/authDataSource';
import type { AuthRepository } from '../src/api/authRepository';
import type { TokenStorage } from '../src/api/tokenStorage';
import { fakeTransport } from './fakeTransport';

const config = {
  clientID: 'client-1',
  projectID: 'project-1',
  configID: 'config-1',
  region: 'eu1' as const,
};

class InMemoryStorage implements TokenStorage {
  private value: AuthModel | null = null;
  read = async () => this.value;
  save = async (t: AuthModel) => { this.value = t; };
  delete = async () => { this.value = null; };
}

function makeRepo(): { repo: AuthRepository; calls: { n: number } } {
  const calls = { n: 0 };
  const repo: AuthRepository = {
    createAnonymousToken: async () => {
      throw new Error('not used');
    },
    createSignedToken: async (cfg, userId, secret) => {
      calls.n += 1;
      return new AuthModel({
        accessToken: 'jwt-fresh',
        sinchIdentity: { kind: 'selfSigned', userId, signedUserId: secret },
        clientID: cfg.clientID,
        projectID: cfg.projectID,
        configID: cfg.configID,
        region: cfg.region,
      });
    },
  };
  return { repo, calls };
}

describe('DefaultAuthDataSource.generateToken', () => {
  it('returns the cached token without calling the repo when config + identity match', async () => {
    const storage = new InMemoryStorage();
    const { repo, calls } = makeRepo();
    const identity = { kind: 'selfSigned' as const, userId: 'alice', signedUserId: 'sig-1' };
    const dataSource = new DefaultAuthDataSource(repo, storage);

    const first = await dataSource.generateToken(config, identity);
    const second = await dataSource.generateToken(config, identity);

    expect(calls.n).toBe(1); // only the first call hits the repo
    expect(second.accessToken).toBe(first.accessToken);
  });

  it('calls the repo and saves when no cached token is present', async () => {
    const storage = new InMemoryStorage();
    const { repo, calls } = makeRepo();
    const dataSource = new DefaultAuthDataSource(repo, storage);

    const token = await dataSource.generateToken(config, {
      kind: 'selfSigned',
      userId: 'bob',
      signedUserId: 'sig-2',
    });

    expect(calls.n).toBe(1);
    expect(token.accessToken).toBe('jwt-fresh');

    const cached = await storage.read();
    expect(cached?.accessToken).toBe('jwt-fresh');
  });

  it('calls the repo again when identity changes (different signedUserID)', async () => {
    const storage = new InMemoryStorage();
    const { repo, calls } = makeRepo();
    const dataSource = new DefaultAuthDataSource(repo, storage);

    await dataSource.generateToken(config, { kind: 'selfSigned', userId: 'alice', signedUserId: 'sig-1' });
    await dataSource.generateToken(config, { kind: 'selfSigned', userId: 'alice', signedUserId: 'sig-2' });

    expect(calls.n).toBe(2);
  });

  it('returns null access token from currentAccessToken when storage is empty', async () => {
    const storage = new InMemoryStorage();
    const { repo } = makeRepo();
    const dataSource = new DefaultAuthDataSource(repo, storage);

    expect(await dataSource.currentAccessToken()).toBeNull();
  });

  it('clears the keychain and resets the auth token on deleteToken', async () => {
    const storage = new InMemoryStorage();
    const { repo } = makeRepo();
    const dataSource = new DefaultAuthDataSource(repo, storage);

    await dataSource.generateToken(config, { kind: 'selfSigned', userId: 'alice', signedUserId: 'sig' });
    await dataSource.deleteToken();

    expect(await storage.read()).toBeNull();
    expect(await dataSource.currentAccessToken()).toBeNull();
  });
});
