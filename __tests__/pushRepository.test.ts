import { create } from '@bufbuild/protobuf';
import {
  SubscribeRequestSchema,
  UnsubscribeRequestSchema,
  GetPublicKeyRequestSchema,
  GetPublicKeyResponseSchema,
} from '../src/generated/sinch/push/sdk/v1beta1/sdk_pb';
import { DefaultPushRepository } from '../src/api/pushRepository';
import { fakeTransport } from './fakeTransport';

const CONFIG_ID = 'cfg-1';

describe('DefaultPushRepository', () => {
  it('sendDeviceToken calls Subscribe with { token, config }', async () => {
    const seen: Array<{ method: string; request: any }> = [];
    const transport = fakeTransport((method, request) => {
      seen.push({ method, request });
      return undefined;
    });
    const repo = new DefaultPushRepository(transport);

    await repo.sendDeviceToken('APNS-token-hex', 'jwt-1', CONFIG_ID);

    expect(seen).toHaveLength(1);
    expect(seen[0]?.method).toBe('Subscribe');
    expect(seen[0]?.request).toEqual(
      create(SubscribeRequestSchema, { token: 'APNS-token-hex', config: CONFIG_ID }),
    );
  });

  it('unsubscribe calls Unsubscribe and swallows transport errors', async () => {
    const seen: Array<{ method: string }> = [];
    const transport = fakeTransport((method) => {
      seen.push({ method });
      throw new Error('boom');
    });
    const repo = new DefaultPushRepository(transport);

    // Must NOT throw — mirrors Swift's "log + return" semantics
    await expect(repo.unsubscribe('APNS-token-hex', 'jwt-1', CONFIG_ID)).resolves.toBeUndefined();
    expect(seen).toHaveLength(1);
    expect(seen[0]?.method).toBe('Unsubscribe');
  });

  it('unsubscribe carries the same { token, config } shape as subscribe', async () => {
    const seen: Array<{ method: string; request: any }> = [];
    const transport = fakeTransport((method, request) => {
      seen.push({ method, request });
      return undefined;
    });
    const repo = new DefaultPushRepository(transport);

    await repo.unsubscribe('APNS-token-hex', 'jwt-1', CONFIG_ID);

    expect(seen[0]?.method).toBe('Unsubscribe');
    expect(seen[0]?.request).toEqual(
      create(UnsubscribeRequestSchema, { token: 'APNS-token-hex', config: CONFIG_ID }),
    );
  });

  it('getPublicKey returns the publicKey field from the response', async () => {
    const transport = fakeTransport((method, request) => {
      expect(method).toBe('GetPublicKey');
      expect(request).toEqual(create(GetPublicKeyRequestSchema, { config: CONFIG_ID }));
      return create(GetPublicKeyResponseSchema, { publicKey: '-----BEGIN PUBLIC KEY-----\n-----END PUBLIC KEY-----' });
    });
    const repo = new DefaultPushRepository(transport);

    const key = await repo.getPublicKey(CONFIG_ID, 'jwt-1');
    expect(key).toContain('BEGIN PUBLIC KEY');
  });
});
