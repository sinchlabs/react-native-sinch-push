import { accountKeyFor, KeychainTokenStorage } from '../src/api/tokenStorage';
import { AuthModel } from '../src/api/authRepository';
import { _store } from './__mocks__/react-native-keychain';

describe('accountKeyFor', () => {
  it('uses "EU1" for region "eu1"', () => {
    expect(
      accountKeyFor({
        clientID: 'a',
        projectID: 'b',
        configID: 'c',
        region: 'eu1',
      }),
    ).toBe('a.b.c.EU1');
  });

  it('uses "US1" for region "us1"', () => {
    expect(
      accountKeyFor({
        clientID: 'a',
        projectID: 'b',
        configID: 'c',
        region: 'us1',
      }),
    ).toBe('a.b.c.US1');
  });

  it('uses "custom.<host>" for region "custom"', () => {
    expect(
      accountKeyFor({
        clientID: 'a',
        projectID: 'b',
        configID: 'c',
        region: 'custom',
        customPushApiUrl: 'https://x.example.com',
      }),
    ).toBe('a.b.c.custom.https://x.example.com');
  });
});

describe('KeychainTokenStorage', () => {
  beforeEach(() => {
    _store.clear();
  });

  it('returns null on a cold storage', async () => {
    const storage = new KeychainTokenStorage('test-account');
    expect(await storage.read()).toBeNull();
  });

  it('round-trips an AuthModel through the mock keychain', async () => {
    const storage = new KeychainTokenStorage('test-account');
    const token = new AuthModel({
      accessToken: 'jwt-test',
      sinchIdentity: { kind: 'selfSigned', userId: 'u', signedUserId: 's' },
      clientID: 'a',
      projectID: 'b',
      configID: 'c',
      region: 'eu1',
    });

    await storage.save(token);
    const read = await storage.read();

    expect(read?.accessToken).toBe('jwt-test');
    expect(read?.clientID).toBe('a');
    expect(read?.sinchIdentity).toEqual({ kind: 'selfSigned', userId: 'u', signedUserId: 's' });
  });

  it('delete() clears the keychain entry', async () => {
    const storage = new KeychainTokenStorage('test-account');
    await storage.save(
      new AuthModel({
        accessToken: 'jwt-test',
        sinchIdentity: { kind: 'selfSigned', userId: 'u', signedUserId: 's' },
        clientID: 'a',
        projectID: 'b',
        configID: 'c',
        region: 'eu1',
      }),
    );
    await storage.delete();
    expect(await storage.read()).toBeNull();
  });
});
