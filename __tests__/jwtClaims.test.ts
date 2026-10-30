import { decodeJwtClaims } from '../src/api/jwtClaims';

// Same fixture shape as __tests__/authModel.test.ts (Buffer is fine in the
// Node test env; the implementation under test uses no Buffer/atob).
const HEADER = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
const SIGNATURE = 'sig';

function makeJwt(payload: object): string {
  return [HEADER, Buffer.from(JSON.stringify(payload)).toString('base64url'), SIGNATURE].join('.');
}

function makeJwtRawSegment(segment: string): string {
  return [HEADER, segment, SIGNATURE].join('.');
}

describe('decodeJwtClaims', () => {
  it('decodes the fixture token from authModel.test.ts', () => {
    expect(decodeJwtClaims(makeJwt({ uuid: 'user-42', project_id: 'p1' }))).toEqual({
      uuid: 'user-42',
      projectId: 'p1',
    });
  });

  it('decodes a full camelCase claim set', () => {
    expect(
      decodeJwtClaims(
        makeJwt({
          appId: 'app-1',
          clientId: 'client-1',
          projectId: 'project-1',
          uuid: 'user-1',
          exp: 1780000000,
          iat: 1770000000,
        }),
      ),
    ).toEqual({
      appId: 'app-1',
      clientId: 'client-1',
      projectId: 'project-1',
      uuid: 'user-1',
      exp: 1780000000,
      iat: 1770000000,
    });
  });

  it('normalises snake_case claim names and drops unknown claims', () => {
    expect(
      decodeJwtClaims(makeJwt({ app_id: 'a', client_id: 'c', project_id: 'p', iss: 'x' })),
    ).toEqual({ appId: 'a', clientId: 'c', projectId: 'p' });
  });

  it('returns null when segments are missing', () => {
    expect(decodeJwtClaims('opaque-not-a-jwt')).toBeNull();
    expect(decodeJwtClaims('')).toBeNull();
    expect(decodeJwtClaims('a.b')).toBeNull();
    expect(decodeJwtClaims('a.b.c.d')).toBeNull();
    expect(decodeJwtClaims('a..c')).toBeNull();
  });

  it('returns null for non-string input', () => {
    expect(decodeJwtClaims(null)).toBeNull();
    expect(decodeJwtClaims(undefined)).toBeNull();
    expect(decodeJwtClaims(123)).toBeNull();
    expect(decodeJwtClaims({})).toBeNull();
    expect(decodeJwtClaims([])).toBeNull();
  });

  it('returns null for bad base64 in the payload segment', () => {
    expect(decodeJwtClaims(makeJwtRawSegment('***'))).toBeNull();
    expect(decodeJwtClaims(makeJwtRawSegment('!!!'))).toBeNull();
    expect(decodeJwtClaims(makeJwtRawSegment('ab=c'))).toBeNull();
    // Length % 4 === 1 can never be valid base64.
    expect(decodeJwtClaims(makeJwtRawSegment('abcde'))).toBeNull();
    // Valid base64 but invalid UTF-8.
    expect(
      decodeJwtClaims(makeJwtRawSegment(Buffer.from([0xff, 0xfe, 0xfd]).toString('base64url'))),
    ).toBeNull();
  });

  it('returns null for a non-JSON payload', () => {
    expect(
      decodeJwtClaims(makeJwtRawSegment(Buffer.from('not-json{').toString('base64url'))),
    ).toBeNull();
  });

  it('returns null for a non-object JSON payload', () => {
    for (const value of ['"just-a-string"', '123', 'true', 'null', '[1,2]', '["uuid"]']) {
      expect(
        decodeJwtClaims(makeJwtRawSegment(Buffer.from(value).toString('base64url'))),
      ).toBeNull();
    }
  });

  it('ignores claims with the wrong type', () => {
    expect(
      decodeJwtClaims(
        makeJwt({ uuid: 123, exp: 'soon', appId: ['x'], clientId: null, projectId: 'ok', iat: 456 }),
      ),
    ).toEqual({ projectId: 'ok', iat: 456 });
    expect(decodeJwtClaims(makeJwt({ uuid: 123, exp: NaN }))).toEqual({});
  });

  it('decodes unicode claims (UTF-8 safe, unlike atob)', () => {
    expect(decodeJwtClaims(makeJwt({ uuid: 'usér-🎉-42', projectId: 'prøjéct-😀' }))).toEqual({
      uuid: 'usér-🎉-42',
      projectId: 'prøjéct-😀',
    });
  });

  it('tolerates missing or present padding', () => {
    const unpadded = Buffer.from(JSON.stringify({ uuid: 'pad-me' })).toString('base64url');
    expect(unpadded).not.toContain('=');
    expect(decodeJwtClaims(makeJwtRawSegment(unpadded))).toEqual({ uuid: 'pad-me' });
    const padded = unpadded + '='.repeat((4 - (unpadded.length % 4)) % 4);
    expect(decodeJwtClaims(makeJwtRawSegment(padded))).toEqual({ uuid: 'pad-me' });
  });

  it('never throws on garbage input', () => {
    const inputs: unknown[] = ['', '.', '..', '…', '\0.\0.\0', 'a.b.c', 'hällö.wörld.sig'];
    for (const input of inputs) {
      expect(() => decodeJwtClaims(input)).not.toThrow();
    }
  });
});
