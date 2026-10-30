import { Code } from '@connectrpc/connect';
import { SdkService } from '../src/generated/sinch/push/sdk/v1beta1/sdk_pb';
import {
  buildTransport,
  DEFAULT_UNARY_TIMEOUT_MS,
  getAuthToken,
  setAuthToken,
  RELAY_WS_URLS,
  resolveRegion,
  resolveWsUrl,
  WsUrlError,
} from '../src/api/transport';

describe('resolveRegion', () => {
  const base = { projectID: 'p', clientID: 'c', configID: 'cfg' } as const;

  beforeEach(() => {
    setAuthToken(null);
  });

  it('returns the EU1 push + chat hosts for env "eu1"', () => {
    const result = resolveRegion({ ...base, env: 'eu1' } as any);
    expect(result.pushBaseUrl).toBe('https://grpc.sinch-push.prod.sinch.com');
    expect(result.chatBaseUrl).toBe(
      'https://grpc-web.sinch-chat.prod.sinch.com'
    );
  });

  it('returns the US1 push + chat hosts for env "us1"', () => {
    const result = resolveRegion({ ...base, env: 'us1' } as any);
    expect(result.pushBaseUrl).toBe(
      'https://grpc.sinch-push.us1.prod.sinch.com'
    );
    expect(result.chatBaseUrl).toBe(
      'https://grpc-web.sinch-chat.us1.prod.sinch.com'
    );
  });

  it('returns the custom URLs verbatim when env "custom" + both URLs provided', () => {
    const result = resolveRegion({
      ...base,
      env: 'custom',
      customPushApiUrl: 'https://push.example.test',
      customChatApiUrl: 'https://chat.example.test',
    } as any);
    expect(result.pushBaseUrl).toBe('https://push.example.test');
    expect(result.chatBaseUrl).toBe('https://chat.example.test');
  });

  it('throws when env "custom" and customChatApiUrl is missing', () => {
    expect(() =>
      resolveRegion({
        ...base,
        env: 'custom',
        customPushApiUrl: 'https://push.example.test',
      } as any)
    ).toThrow(/customChatApiUrl/);
  });

  it('throws when env "custom" and customPushApiUrl is missing', () => {
    expect(() =>
      resolveRegion({
        ...base,
        env: 'custom',
        customChatApiUrl: 'https://chat.example.test',
      } as any)
    ).toThrow(/customPushApiUrl/);
  });
});

describe('resolveWsUrl', () => {
  const base = { projectID: 'p', clientID: 'c', configID: 'cfg' } as const;
  const custom = {
    ...base,
    env: 'custom',
    customPushApiUrl: 'https://push.example.test',
    customChatApiUrl: 'https://chat.example.test',
  } as const;

  function wsErrorOf(fn: () => unknown): WsUrlError {
    try {
      fn();
    } catch (e) {
      expect(e).toBeInstanceOf(WsUrlError);
      return e as WsUrlError;
    }
    throw new Error('expected resolveWsUrl to throw');
  }

  it('has a relay URL for each built-in region', () => {
    expect(RELAY_WS_URLS).toEqual({
      eu1: 'wss://relay.sinch-push.prod.sinch.com/ws',
      us1: 'wss://relay.sinch-push.us1.prod.sinch.com/ws',
    });
  });

  it.each(['eu1', 'us1'] as const)('resolves the relay of env "%s"', (env) => {
    expect(resolveWsUrl({ ...base, env }, { isDev: false })).toEqual({
      url: RELAY_WS_URLS[env],
    });
  });

  describe('env "custom" without customWsUrl derives the relay from the push host', () => {
    const EU1 = 'wss://relay.sinch-push.prod.sinch.com/ws';
    const US1 = 'wss://relay.sinch-push.us1.prod.sinch.com/ws';

    it.each([
      ['https://grpc.sinch-push.prod.sinch.com', EU1],
      ['https://grpc.sinch-push.us1.prod.sinch.com', US1],
      ['HTTPS://GRPC.Sinch-Push.Prod.Sinch.com:443/some/path?x=1', EU1],
      ['https://grpc.sinch-push.prod.sinch.com:443', EU1],
      ['https://GRPC.SINCH-PUSH.US1.PROD.SINCH.COM:443/', US1],
      ['https://user:pw@grpc.sinch-push.prod.sinch.com/x', EU1],
      ['grpc.sinch-push.prod.sinch.com', EU1],
      ['grpc.sinch-push.us1.prod.sinch.com:443/path', US1],
      ['  GRPC.sinch-push.prod.sinch.com  ', EU1],
    ])('%s -> %s', (customPushApiUrl, url) => {
      expect(
        resolveWsUrl({ ...custom, customPushApiUrl }, { isDev: false })
      ).toEqual({ url });
    });

    it('disables the relay for an unknown push host', () => {
      expect(resolveWsUrl(custom, { isDev: false })).toEqual({
        disabled: 'no relay host for push host push.example.test',
      });
    });

    it('lets an explicit customWsUrl win over the derived one', () => {
      expect(
        resolveWsUrl(
          {
            ...custom,
            customPushApiUrl: 'https://grpc.sinch-push.prod.sinch.com',
            socket: { customWsUrl: 'wss://relay.example.test/ws' },
          },
          { isDev: false }
        )
      ).toEqual({ url: 'wss://relay.example.test/ws' });
    });
  });

  it('does not read socket.enabled: the relay off switch is native (RN-048)', () => {
    expect(
      resolveWsUrl(
        {
          ...custom,
          socket: { enabled: false, customWsUrl: 'wss://relay.example.test/ws' },
        },
        { isDev: false }
      )
    ).toEqual({ url: 'wss://relay.example.test/ws' });
  });

  it('customWsUrl overrides a disabled region', () => {
    expect(
      resolveWsUrl(
        {
          ...base,
          env: 'eu1',
          socket: { customWsUrl: 'wss://relay.example.test/ws' },
        },
        { isDev: false }
      )
    ).toEqual({ url: 'wss://relay.example.test/ws' });
  });

  it('resolves env "custom" from customWsUrl', () => {
    expect(
      resolveWsUrl(
        { ...custom, socket: { customWsUrl: 'wss://relay.example.test/ws' } },
        { isDev: false }
      )
    ).toEqual({ url: 'wss://relay.example.test/ws' });
  });

  it('rejects ws:// in prod with E_WS_INSECURE', () => {
    const err = wsErrorOf(() =>
      resolveWsUrl(
        { ...custom, socket: { customWsUrl: 'ws://localhost:8080/ws' } },
        { isDev: false }
      )
    );
    expect(err.code).toBe('E_WS_INSECURE');
  });

  it('allows ws:// in dev', () => {
    expect(
      resolveWsUrl(
        { ...custom, socket: { customWsUrl: 'ws://localhost:8080/ws' } },
        { isDev: true }
      )
    ).toEqual({ url: 'ws://localhost:8080/ws' });
  });

  it('allows ws:// in prod with allowInsecureWs', () => {
    expect(
      resolveWsUrl(
        {
          ...custom,
          socket: {
            customWsUrl: 'ws://localhost:8080/ws',
            allowInsecureWs: true,
          },
        },
        { isDev: false }
      )
    ).toEqual({ url: 'ws://localhost:8080/ws' });
  });

  it('rejects non-ws schemes', () => {
    const err = wsErrorOf(() =>
      resolveWsUrl(
        { ...custom, socket: { customWsUrl: 'https://relay.example.test/ws' } },
        { isDev: true }
      )
    );
    expect(err.code).toBe('E_WS_NOT_CONFIGURED');
  });
});

describe('buildTransport unary deadline', () => {
  const realFetch = (global as any).fetch;
  afterEach(() => {
    (global as any).fetch = realFetch;
    jest.useRealTimers();
  });

  // Any unary method will do: the request body is built from the descriptor.
  const method = SdkService.method.subscribe;

  function call(timeoutMs?: number, signal?: AbortSignal) {
    const transport = buildTransport({ baseUrl: 'https://push.example.test' });
    return transport.unary(method, signal, timeoutMs, undefined, {});
  }

  /** A fetch that never answers, and rejects like the real one when aborted. */
  function hangingFetch() {
    const seen: { signal?: AbortSignal } = {};
    (global as any).fetch = (_url: string, init: { signal: AbortSignal }) => {
      seen.signal = init.signal;
      return new Promise((_, reject) => {
        init.signal.addEventListener('abort', () =>
          reject(Object.assign(new Error('Aborted'), { name: 'AbortError' }))
        );
      });
    };
    return seen;
  }

  it('fails with deadline_exceeded after the given timeoutMs and aborts the request', async () => {
    jest.useFakeTimers();
    const seen = hangingFetch();
    const pending = call(5_000);
    const assertion = expect(pending).rejects.toMatchObject({
      code: Code.DeadlineExceeded,
      rawMessage: expect.stringContaining('timed out after 5000ms'),
    });
    await jest.advanceTimersByTimeAsync(4_999);
    expect(seen.signal?.aborted).toBe(false);
    await jest.advanceTimersByTimeAsync(1);
    await assertion;
    expect(seen.signal?.aborted).toBe(true);
  });

  it('defaults to DEFAULT_UNARY_TIMEOUT_MS when none is given', async () => {
    jest.useFakeTimers();
    hangingFetch();
    const assertion = expect(call()).rejects.toMatchObject({ code: Code.DeadlineExceeded });
    await jest.advanceTimersByTimeAsync(DEFAULT_UNARY_TIMEOUT_MS);
    await assertion;
  });

  it('rejects even when fetch ignores the abort signal', async () => {
    jest.useFakeTimers();
    (global as any).fetch = () => new Promise(() => {});
    const assertion = expect(call(1_000)).rejects.toMatchObject({ code: Code.DeadlineExceeded });
    await jest.advanceTimersByTimeAsync(1_000);
    await assertion;
  });

  it('maps a caller abort to canceled, not to a timeout', async () => {
    hangingFetch();
    const controller = new AbortController();
    const pending = call(60_000, controller.signal);
    const assertion = expect(pending).rejects.toMatchObject({ code: Code.Canceled });
    controller.abort();
    await assertion;
  });

  it('leaves no timer behind after a call that finished', async () => {
    jest.useFakeTimers();
    (global as any).fetch = async () => ({
      status: 200,
      headers: new Headers(),
      arrayBuffer: async () => new ArrayBuffer(0),
    });
    await call(5_000);
    expect(jest.getTimerCount()).toBe(0);
  });
});

describe('setAuthToken / getAuthToken', () => {
  it('round-trips the token via the closure', () => {
    setAuthToken(null);
    expect(getAuthToken()).toBeNull();

    setAuthToken('jwt-1');
    expect(getAuthToken()).toBe('jwt-1');

    setAuthToken('jwt-2');
    expect(getAuthToken()).toBe('jwt-2');

    setAuthToken(null);
    expect(getAuthToken()).toBeNull();
  });
});
