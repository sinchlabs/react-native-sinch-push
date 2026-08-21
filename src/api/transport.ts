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
      _timeoutMs: number | undefined,
      header: HeadersInit | undefined,
      input: MessageInitShape<I>,
      contextValues?: ContextValues,
    ): Promise<UnaryResponse<I, O>> {
      const message = create(method.input, input);
      const reqHeader = new Headers(header);
      reqHeader.set('content-type', contentType);
      reqHeader.set('accept', contentType);
      reqHeader.set('x-grpc-web', '1');

      const request: UnaryRequest<I, O> = {
        stream: false,
        service: method.parent,
        requestMethod: 'POST',
        url: `${baseUrl}/${method.parent.typeName}/${method.name}`,
        signal: signal ?? new AbortController().signal,
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

      const chain = interceptors.reduceRight<AnyFn>(
        (next, interceptor) => interceptor(next),
        invoke
      );
      return (await chain(request)) as UnaryResponse<I, O>;
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