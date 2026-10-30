import { decodeUtf8 } from '../textEncoding';

/**
 * Typed subset of JWT claims used by the SDK.
 *
 * Payloads may carry these under camelCase (`projectId`) or snake_case
 * (`project_id`) names; both are accepted and normalised to camelCase here.
 */
export interface JwtClaims {
  appId?: string;
  clientId?: string;
  projectId?: string;
  uuid?: string;
  exp?: number;
  iat?: number;
}

const BASE64URL_RE = /^[A-Za-z0-9_-]*$/;
const PAD_CODE = 61; // '='

/** Base64url sextet value for a char code, or -1 when invalid. */
function sextet(code: number): number {
  if (code >= 65 && code <= 90) return code - 65; // A-Z
  if (code >= 97 && code <= 122) return code - 71; // a-z
  if (code >= 48 && code <= 57) return code + 4; // 0-9
  if (code === 43 || code === 45) return 62; // '+' or '-' (url)
  if (code === 47 || code === 95) return 63; // '/' or '_' (url)
  return -1;
}

/**
 * Decodes a base64url segment to bytes without `atob`/`Buffer`, so it works
 * on React Native / Hermes as well as Node. Missing padding is tolerated;
 * returns null when the segment is not valid base64url.
 */
function base64UrlToBytes(segment: string): Uint8Array | null {
  const unpadded = segment.replace(/=+$/, '');
  if (unpadded.length === 0 || unpadded.length % 4 === 1) return null;
  if (!BASE64URL_RE.test(unpadded)) return null;
  const padded = unpadded + '='.repeat((4 - (unpadded.length % 4)) % 4);
  const out = new Uint8Array((padded.length / 4) * 3 - (padded.length - unpadded.length));
  let o = 0;
  for (let i = 0; i < padded.length; i += 4) {
    const v0 = sextet(padded.charCodeAt(i));
    const v1 = sextet(padded.charCodeAt(i + 1));
    const c2 = padded.charCodeAt(i + 2);
    const c3 = padded.charCodeAt(i + 3);
    const v2 = c2 === PAD_CODE ? 0 : sextet(c2);
    const v3 = c3 === PAD_CODE ? 0 : sextet(c3);
    if (v0 < 0 || v1 < 0 || v2 < 0 || v3 < 0) return null;
    const triple = (v0 << 18) | (v1 << 12) | (v2 << 6) | v3;
    out[o++] = (triple >> 16) & 0xff;
    if (c2 !== PAD_CODE) out[o++] = (triple >> 8) & 0xff;
    if (c3 !== PAD_CODE) out[o++] = triple & 0xff;
  }
  return out;
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' ? value : undefined;
}

function asNumber(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

/**
 * Decodes the payload of a JWT access token into typed claims.
 *
 * Pure manual base64url + UTF-8 decoding (no `atob`/`Buffer`/`TextDecoder`
 * globals), so unicode claims survive on Hermes. Never throws: any malformed
 * input yields null. Unknown claims are dropped; known claims with the wrong
 * type are ignored.
 */
export function decodeJwtClaims(token: unknown): JwtClaims | null {
  try {
    if (typeof token !== 'string') return null;
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    const segment = parts[1];
    if (!segment) return null;
    const bytes = base64UrlToBytes(segment);
    if (!bytes) return null;
    const payload: unknown = JSON.parse(decodeUtf8(bytes, true));
    if (typeof payload !== 'object' || payload === null || Array.isArray(payload)) {
      return null;
    }
    const record = payload as Record<string, unknown>;
    const claims: JwtClaims = {};
    const appId = asString(record.appId ?? record.app_id);
    if (appId !== undefined) claims.appId = appId;
    const clientId = asString(record.clientId ?? record.client_id);
    if (clientId !== undefined) claims.clientId = clientId;
    const projectId = asString(record.projectId ?? record.project_id);
    if (projectId !== undefined) claims.projectId = projectId;
    const uuid = asString(record.uuid);
    if (uuid !== undefined) claims.uuid = uuid;
    const exp = asNumber(record.exp);
    if (exp !== undefined) claims.exp = exp;
    const iat = asNumber(record.iat);
    if (iat !== undefined) claims.iat = iat;
    return claims;
  } catch {
    return null;
  }
}
