import type { AuthModel } from './authRepository';
import { decodeJwtClaims } from './jwtClaims';

/**
 * The minimal credential native mirrors for the Notification Service Extension
 * and for background uploads. It holds what a `ReportEvents` call needs - the JWT
 * and the push API host - and never the HMAC secret.
 */
export interface SharedReportRecord {
  accessToken: string;
  /** The push API base URL, e.g. `https://grpc.sinch-push.prod.sinch.com`. */
  reportBaseURL: string;
  userId: string;
  appId: string;
}

export function buildSharedReportRecord(
  auth: Pick<AuthModel, 'accessToken'> & Partial<Pick<AuthModel, 'sinchIdentity'>>,
  reportBaseURL: string,
): SharedReportRecord {
  const claims = decodeJwtClaims(auth.accessToken);
  // A stored token is plain JSON that may predate `sinchIdentity`.
  const identity = auth.sinchIdentity;
  const userId =
    identity && identity.kind !== 'anonymous'
      ? identity.userId
      : (claims?.uuid ?? '');
  return {
    accessToken: auth.accessToken,
    reportBaseURL,
    userId,
    appId: claims?.appId ?? '',
  };
}
