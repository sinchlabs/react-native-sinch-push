import { AuthModel } from '../src/api/authRepository';

const HEADER = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
const SIGNATURE = 'sig';

function makeJwt(payload: object): string {
  return [HEADER, Buffer.from(JSON.stringify(payload)).toString('base64url'), SIGNATURE].join('.');
}

describe('AuthModel.getUserID', () => {
  it('returns the "uuid" claim from the JWT payload', () => {
    const token = new AuthModel({
      accessToken: makeJwt({ uuid: 'user-42', project_id: 'p1' }),
      sinchIdentity: { kind: 'selfSigned', userId: 'user-42', signedUserId: 'sig' },
      clientID: 'c',
      projectID: 'p',
      configID: 'cfg',
      region: 'eu1',
    });

    expect(token.getUserID()).toBe('user-42');
  });

  it('returns null when the access token is not a JWT', () => {
    const token = new AuthModel({
      accessToken: 'opaque-not-a-jwt',
      sinchIdentity: { kind: 'selfSigned', userId: 'x', signedUserId: 's' },
      clientID: 'c',
      projectID: 'p',
      configID: 'cfg',
      region: 'eu1',
    });

    expect(token.getUserID()).toBeNull();
  });

  it('returns null when the payload has no uuid', () => {
    const token = new AuthModel({
      accessToken: makeJwt({ project_id: 'p1' }),
      sinchIdentity: { kind: 'selfSigned', userId: 'x', signedUserId: 's' },
      clientID: 'c',
      projectID: 'p',
      configID: 'cfg',
      region: 'eu1',
    });

    expect(token.getUserID()).toBeNull();
  });
});

describe('AuthModel.identityHash', () => {
  it('is deterministic for the same input', () => {
    const opts = {
      accessToken: 'jwt-x',
      sinchIdentity: { kind: 'selfSigned' as const, userId: 'u', signedUserId: 's' },
      clientID: 'c',
      projectID: 'p',
      configID: 'cfg',
      region: 'eu1' as const,
    };
    const a = new AuthModel(opts);
    const b = new AuthModel(opts);
    expect(a.identityHash).toBe(b.identityHash);
  });

  it('changes when the identity changes', () => {
    const base = {
      clientID: 'c',
      projectID: 'p',
      configID: 'cfg',
      region: 'eu1' as const,
      accessToken: 'jwt-x',
    };
    const a = new AuthModel({ ...base, sinchIdentity: { kind: 'selfSigned', userId: 'u1', signedUserId: 's' } });
    const b = new AuthModel({ ...base, sinchIdentity: { kind: 'selfSigned', userId: 'u2', signedUserId: 's' } });
    expect(a.identityHash).not.toBe(b.identityHash);
  });
});
