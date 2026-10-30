import {
  Code,
  ConnectError,
  createContextValues,
  type ContextValues,
  type Interceptor,
  type StreamRequest,
  type StreamResponse,
  type Transport,
  type UnaryRequest,
  type UnaryResponse,
} from '@connectrpc/connect';
import {
  create,
  fromBinary,
  fromJsonString,
  toBinary,
  toJsonString,
  type DescMessage,
  type DescMethodStreaming,
  type DescMethodUnary,
  type MessageInitShape,
  type MessageShape,
} from '@bufbuild/protobuf';
import type { SinchPushConfig } from '../types';
import { decodeUtf8 } from '../textEncoding';

export type { Transport } from '@connectrpc/connect';

type AnyFn = (
  req: UnaryRequest | StreamRequest
) => Promise<UnaryResponse | StreamResponse>;

const EU1_RELAY_WS_URL = 'wss://relay.sinch-push.prod.sinch.com/ws';
const US1_RELAY_WS_URL = 'wss://relay.sinch-push.us1.prod.sinch.com/ws';

// Per-region relay WebSocket URLs (see `resolveWsUrl`). The production ingress
// may not route `GET /ws` to the relay yet; until it does the native client
// reconnects with backoff while FCM / APNs keep delivering, and a host opts out
// with `socket.enabled: false`.
export const RELAY_WS_URLS: Record<'eu1' | 'us1', string> = {
  eu1: EU1_RELAY_WS_URL,
  us1: US1_RELAY_WS_URL,
};

// The relay of an `env: 'custom'` config, derived from the host of its
// `customPushApiUrl` (lowercase). Mirrors the iOS and Android SDKs.
const RELAY_WS_URL_BY_PUSH_HOST: Record<string, string> = {
  'grpc.sinch-push.prod.sinch.com': EU1_RELAY_WS_URL,
  'grpc.sinch-push.us1.prod.sinch.com': US1_RELAY_WS_URL,
};

/** Host of an absolute URL, as written: no scheme, userinfo or port. */
function hostOf(url: string): string {
  const withoutScheme = url.trim().replace(/^[a-z][a-z0-9+.-]*:\/\//i, '');
  const authority = withoutScheme.split(/[/?#]/, 1)[0] ?? '';
  const hostPort = authority.slice(authority.lastIndexOf('@') + 1);
  const host = hostPort.startsWith('[')
    ? hostPort.slice(0, hostPort.indexOf(']') + 1)
    : hostPort.split(':', 1)[0] ?? '';
  return host;
}

/**
 * Deadline of a unary call that does not set its own `timeoutMs`. React
 * Native's networking has no connect/read timeout of its own on Android, so
 * without one an unreachable host stalls the call (and whatever awaits it, e.g.
 * `setIdentity`) for the OS's TCP timeout, close to a minute.
 */
export const DEFAULT_UNARY_TIMEOUT_MS = 15_000;

const HOSTS = {
  eu1: {
    push: 'https://grpc.sinch-push.prod.sinch.com',
    chat: 'https://grpc-web.sinch-chat.prod.sinch.com',
  },
  us1: {
    push: 'https://grpc.sinch-push.us1.prod.sinch.com',
    chat: 'https://grpc-web.sinch-chat.us1.prod.sinch.com',
  },
} as const;

export type Region = 'eu1' | 'us1' | 'custom';

export interface RegionConfig {
  pushBaseUrl: string;
  chatBaseUrl: string;
}

export interface TransportOptions {
  baseUrl: string;
  useBinaryFormat?: boolean;
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

export type WsUrlErrorCode = 'E_WS_NOT_CONFIGURED' | 'E_WS_INSECURE';

export class WsUrlError extends Error {
  readonly code: WsUrlErrorCode;

  constructor(code: WsUrlErrorCode, message: string) {
    super(`${code}: ${message}`);
    this.name = 'WsUrlError';
    this.code = code;
  }
}

export interface ResolveWsUrlOptions {
  isDev?: boolean;
}

declare const __DEV__: boolean | undefined;

/**
 * Outcome of `resolveWsUrl`: either the URL to connect to, or the reason the
 * relay is disabled (for the caller to log or surface).
 */
export type WsUrlResolution = { url: string } | { disabled: string };

/**
 * Resolve an explicit/region URL, or explain why unavailable. Validate supplied
 * schemes. Native enforces the persisted relay switch.
 *
 * The URL is `socket.customWsUrl` when given, else the region's relay
 * (`RELAY_WS_URLS`), else — for `env: 'custom'` — the relay derived from the
 * host of `customPushApiUrl` when that is a production push host. Other
 * environments pass `socket.customWsUrl`.
 *
 * Returns `{ disabled: reason }` — not an error — when there is nothing to
 * connect to: an `env: 'custom'` push host without a relay and without
 * `socket.customWsUrl`. A URL
 * that is present but unusable (wrong scheme, insecure `ws://`) throws
 * `WsUrlError`.
 */
export function resolveWsUrl(
  config: SinchPushConfig,
  opts?: ResolveWsUrlOptions
): WsUrlResolution {
  const isDev = opts?.isDev ?? (typeof __DEV__ !== 'undefined' && __DEV__);
  let url = config.socket?.customWsUrl;
  if (!url) {
    if (config.env === 'custom') {
      // An explicit `customWsUrl` always wins over the derived one.
      const pushHost = hostOf(config.customPushApiUrl ?? '');
      const derived = RELAY_WS_URL_BY_PUSH_HOST[pushHost.toLowerCase()];
      if (!derived) {
        return { disabled: `no relay host for push host ${pushHost}` };
      }
      url = derived;
    } else {
      url = RELAY_WS_URLS[config.env];
    }
  }
  const lowered = url.toLowerCase();
  if (!lowered.startsWith('ws://') && !lowered.startsWith('wss://')) {
    throw new WsUrlError(
      'E_WS_NOT_CONFIGURED',
      `WebSocket URL must use the ws:// or wss:// scheme (got "${url}")`
    );
  }
  if (
    lowered.startsWith('ws://') &&
    !isDev &&
    config.socket?.allowInsecureWs !== true
  ) {
    throw new WsUrlError(
      'E_WS_INSECURE',
      'ws:// URLs are only allowed in dev (__DEV__) or with socket.allowInsecureWs'
    );
  }
  return { url };
}

const authInterceptor: Interceptor = (next) => async (req) => {
  // The Swift SDK sends the raw JWT (no `Bearer ` prefix).
  // Explicit per-call headers win; only fall back to the module token.
  const token = getAuthToken();
  if (token && !req.header.has('Authorization')) {
    req.header.set('Authorization', token);
  }
  return next(req);
};

function frameGrpcWeb(bytes: Uint8Array): Uint8Array {
  const framed = new Uint8Array(5 + bytes.length);
  framed[0] = 0;
  const len = bytes.length;
  framed[1] = (len >>> 24) & 0xff;
  framed[2] = (len >>> 16) & 0xff;
  framed[3] = (len >>> 8) & 0xff;
  framed[4] = len & 0xff;
  framed.set(bytes, 5);
  return framed;
}

function encodeUtf8(text: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    let cp = text.charCodeAt(i);
    if (cp >= 0xd800 && cp <= 0xdbff && i + 1 < text.length) {
      const lo = text.charCodeAt(i + 1);
      if (lo >= 0xdc00 && lo <= 0xdfff) {
        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
        i++;
      }
    }
    if (cp < 0x80) {
      out.push(cp);
    } else if (cp < 0x800) {
      out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
      out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    } else {
      out.push(
        0xf0 | (cp >> 18),
        0x80 | ((cp >> 12) & 0x3f),
        0x80 | ((cp >> 6) & 0x3f),
        0x80 | (cp & 0x3f)
      );
    }
  }
  return new Uint8Array(out);
}

const passthroughInterceptor: Interceptor = (next) => async (req) => next(req);

function decodeEnvelopes(bytes: Uint8Array): {flag: number; data: Uint8Array}[] {
  const out: {flag: number; data: Uint8Array}[] = [];
  let offset = 0;
  while (offset < bytes.length) {
    if (bytes.length - offset < 5) {
      break;
    }
    const flag = bytes[offset] as number;
    const len =
      ((bytes[offset + 1] as number) << 24) |
      ((bytes[offset + 2] as number) << 16) |
      ((bytes[offset + 3] as number) << 8) |
      (bytes[offset + 4] as number);
    offset += 5;
    if (offset + len > bytes.length) {
      break;
    }
    out.push({flag, data: bytes.slice(offset, offset + len)});
    offset += len;
  }
  return out;
}

function parseTrailer(data: Uint8Array): Record<string, string> {
  const text = decodeUtf8(data, false);
  const out: Record<string, string> = {};
  for (const line of text.split(/\r?\n/)) {
    const idx = line.indexOf(':');
    if (idx < 0) {
      continue;
    }
    out[line.slice(0, idx).trim().toLowerCase()] = line.slice(idx + 1).trim();
  }
  return out;
}

export function buildTransport(opts: TransportOptions): Transport {
  const useBinaryFormat = opts.useBinaryFormat ?? true;
  // Per-request verbose logging has been removed — `enableLogging` is kept on
  // the config for backwards compatibility but currently acts as a no-op.
  const interceptors: Interceptor[] = [authInterceptor, passthroughInterceptor];
  const contentType = useBinaryFormat
    ? 'application/grpc-web+proto'
    : 'application/grpc-web+json';
  const baseUrl = opts.baseUrl.replace(/\/?$/, '');

  return {
    async unary<I extends DescMessage, O extends DescMessage>(
      method: DescMethodUnary<I, O>,
      signal: AbortSignal | undefined,
      timeoutMs: number | undefined,
      header: HeadersInit | undefined,
      input: MessageInitShape<I>,
      contextValues?: ContextValues,
    ): Promise<UnaryResponse<I, O>> {
      const message = create(method.input, input);
      const reqHeader = new Headers(header);
      reqHeader.set('content-type', contentType);
      reqHeader.set('accept', contentType);
      reqHeader.set('x-grpc-web', '1');

      // One AbortController for the call: the caller's signal and the deadline
      // both abort it, and both also reject on their own so a fetch that
      // ignores the signal cannot outlive them.
      const deadlineMs =
        timeoutMs !== undefined && timeoutMs > 0
          ? timeoutMs
          : DEFAULT_UNARY_TIMEOUT_MS;
      const controller = new AbortController();
      let rejectCanceled: ((e: ConnectError) => void) | undefined;
      const onCallerAbort = () => {
        controller.abort();
        rejectCanceled?.(new ConnectError('the call was canceled', Code.Canceled));
      };
      let timer: ReturnType<typeof setTimeout> | undefined;
      let timedOut = false;

      const request: UnaryRequest<I, O> = {
        stream: false,
        service: method.parent,
        requestMethod: 'POST',
        url: `${baseUrl}/${method.parent.typeName}/${method.name}`,
        signal: controller.signal,
        header: reqHeader,
        contextValues: contextValues ?? createContextValues(),
        method,
        message,
      };

      const invoke: AnyFn = async (r) => {
        if (r.stream !== false) {
          throw new ConnectError(
            'streaming is not supported by this transport',
            Code.Unimplemented
          );
        }
        const serialized = useBinaryFormat
          ? toBinary(r.method.input, r.message)
          : encodeUtf8(toJsonString(r.method.input, r.message));
        const body = frameGrpcWeb(serialized);
        const res = await globalThis.fetch(r.url, {
          method: 'POST',
          headers: r.header,
          body: body as unknown as BodyInit,
          signal: r.signal,
        });
        const raw = await res.arrayBuffer();
        const buf = new Uint8Array(raw);
        let trailer: Record<string, string> = {};
        let messageBytes: Uint8Array | undefined;
        for (const env of decodeEnvelopes(buf)) {
          if (env.flag === 0x80) {
            trailer = {...trailer, ...parseTrailer(env.data)};
          } else if (messageBytes === undefined) {
            messageBytes = env.data;
          }
        }
        const headerStatus = res.headers.get('grpc-status');
        if (trailer['grpc-status'] === undefined && headerStatus !== null) {
          trailer['grpc-status'] = headerStatus;
        }
        const status = Number(trailer['grpc-status'] ?? '0');
        if (status !== 0) {
          throw new ConnectError(
            trailer['grpc-message'] ?? `grpc-status ${status}`,
            status
          );
        }
        const ur = r as UnaryRequest<I, O>;
        if (messageBytes === undefined) {
          // Native gRPC responses deliver the status in HTTP/2 trailers,
          // which fetch cannot expose; void RPCs then arrive as a 200 with an
          // empty body. Treat that as an empty (successful) response.
          return {
            stream: false,
            service: ur.method.parent,
            header: res.headers,
            trailer: new Headers(trailer),
            method: ur.method,
            message: create(ur.method.output, {} as MessageInitShape<O>),
          } as UnaryResponse<I, O>;
        }
        const out = (useBinaryFormat
          ? fromBinary(r.method.output, messageBytes)
          : fromJsonString(r.method.output, decodeUtf8(messageBytes, false))) as MessageShape<O>;
        const response: UnaryResponse<I, O> = {
          stream: false,
          service: ur.method.parent,
          header: res.headers,
          trailer: new Headers(trailer),
          method: ur.method,
          message: out,
        };
        return response;
      };

      try {
        const chain = interceptors.reduceRight<AnyFn>(
          (next, interceptor) => interceptor(next),
          invoke
        );
        const canceled = new Promise<never>((_, reject) => {
          rejectCanceled = reject;
        });
        const deadline = new Promise<never>((_, reject) => {
          timer = setTimeout(() => {
            timedOut = true;
            controller.abort();
            reject(
              new ConnectError(
                `${method.name} timed out after ${deadlineMs}ms`,
                Code.DeadlineExceeded
              )
            );
          }, deadlineMs);
        });
        if (signal?.aborted) {
          onCallerAbort();
        } else {
          signal?.addEventListener('abort', onCallerAbort);
        }
        return (await Promise.race([
          chain(request),
          deadline,
          canceled,
        ])) as UnaryResponse<I, O>;
      } catch (e) {
        if (signal?.aborted && !timedOut) {
          // fetch's own AbortError says nothing a caller can match on.
          throw new ConnectError('the call was canceled', Code.Canceled);
        }
        throw e;
      } finally {
        clearTimeout(timer);
        signal?.removeEventListener('abort', onCallerAbort);
      }
    },

    async stream<I extends DescMessage, O extends DescMessage>(
      _method: DescMethodStreaming<I, O>,
      _signal: AbortSignal | undefined,
      _timeoutMs: number | undefined,
      _header: HeadersInit | undefined,
      _input: AsyncIterable<MessageInitShape<I>>,
      _contextValues?: ContextValues,
    ): Promise<StreamResponse<I, O>> {
      throw new ConnectError(
        'streaming is not supported by this transport',
        Code.Unimplemented
      );
    },
  };
}