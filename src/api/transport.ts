import type { Interceptor, Transport } from '@connectrpc/connect';
import { createConnectTransport } from '@connectrpc/connect-web';
import type { SinchPushConfig } from '../types';

export type { Transport } from '@connectrpc/connect';

const HOSTS = {
  eu1: {
    push: 'https://grpc.sinch-push.prod.sinch.com',
    chat: 'https://grpc.sinch-chat.prod.sinch.com',
  },
  us1: {
    push: 'https://grpc.sinch-push.us1.prod.sinch.com',
    chat: 'https://grpc.sinch-chat.us1.prod.sinch.com',
  },
} as const;

export type Region = 'eu1' | 'us1' | 'custom';

export interface RegionConfig {
  pushBaseUrl: string;
  chatBaseUrl: string;
}

export interface TransportOptions {
  pushBaseUrl: string;
  chatBaseUrl: string;
  enableLogging?: boolean;
}

let _authToken: string | null = null;

export function setAuthToken(token: string | null): void {
  _authToken = token;
}

export function getAuthToken(): string | null {
  return _authToken;
}

export function resolveRegion(config: SinchPushConfig): RegionConfig {
  if (config.env === 'custom') {
    if (!config.customPushApiUrl) {
      throw new Error(
        'customPushApiUrl is required when env is set to "custom"'
      );
    }
    if (!config.customChatApiUrl) {
      throw new Error(
        'customChatApiUrl is required when env is set to "custom"'
      );
    }
    return {
      pushBaseUrl: config.customPushApiUrl,
      chatBaseUrl: config.customChatApiUrl,
    };
  }
  const hosts = HOSTS[config.env];
  return {
    pushBaseUrl: hosts.push,
    chatBaseUrl: hosts.chat,
  };
}

const authInterceptor: Interceptor = (next) => async (req) => {
  // TODO: verify against live EU1 endpoint in T9 — current default
  // is `Bearer <jwt>` per the locked decision in wayfinder/README.md.
  // The Swift SDK sends the raw JWT (no prefix); R2 §5 leaves the
  // question open and T9 confirms live behaviour.
  const token = getAuthToken();
  if (token) {
    req.header.set('Authorization', `Bearer ${token}`);
  }
  return next(req);
};

const loggingInterceptor: Interceptor = (next) => async (req) => {
  // eslint-disable-next-line no-console
  console.log('[sinch] →', req.requestMethod, req.url);
  const res = await next(req);
  // eslint-disable-next-line no-console
  console.log('[sinch] ←', res.header);
  return res;
};

export function buildTransport(opts: TransportOptions): Transport {
  const interceptors: Interceptor[] = [authInterceptor];
  if (opts.enableLogging) {
    interceptors.push(loggingInterceptor);
  }

  return createConnectTransport({
    baseUrl: opts.pushBaseUrl,
    useBinaryFormat: false,
    fetch: globalThis.fetch,
    interceptors,
  });
}