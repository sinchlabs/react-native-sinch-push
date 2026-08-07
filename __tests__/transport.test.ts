import { getAuthToken, resolveRegion, setAuthToken } from '../src/api/transport';

describe('resolveRegion', () => {
  const base = { projectID: 'p', clientID: 'c', configID: 'cfg' } as const;

  beforeEach(() => {
    setAuthToken(null);
  });

  it('returns the EU1 push + chat hosts for env "eu1"', () => {
    const result = resolveRegion({ ...base, env: 'eu1' } as any);
    expect(result.pushBaseUrl).toBe('https://grpc.sinch-push.prod.sinch.com');
    expect(result.chatBaseUrl).toBe('https://grpc.sinch-chat.prod.sinch.com');
  });

  it('returns the US1 push + chat hosts for env "us1"', () => {
    const result = resolveRegion({ ...base, env: 'us1' } as any);
    expect(result.pushBaseUrl).toBe('https://grpc.sinch-push.us1.prod.sinch.com');
    expect(result.chatBaseUrl).toBe('https://grpc.sinch-chat.us1.prod.sinch.com');
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
      } as any),
    ).toThrow(/customChatApiUrl/);
  });

  it('throws when env "custom" and customPushApiUrl is missing', () => {
    expect(() =>
      resolveRegion({
        ...base,
        env: 'custom',
        customChatApiUrl: 'https://chat.example.test',
      } as any),
    ).toThrow(/customPushApiUrl/);
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
