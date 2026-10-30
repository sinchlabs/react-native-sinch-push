import { create, toBinary } from '@bufbuild/protobuf';
import { toSubscribeDeviceInfo } from '../src/api/deviceInfo';
import {
  SubscribeRequestSchema,
  UnsubscribeRequestSchema,
  GetPublicKeyRequestSchema,
  GetPublicKeyResponseSchema,
  ReportEventsRequestSchema,
} from '../src/generated/sinch/push/sdk/v1beta1/sdk_pb';
import { PushEventType } from '../src/generated/sinch/push/events/v1beta1/events_pb';
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

  describe('device info (RN-043)', () => {
    const info = {
      installationId: '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
      platform: 'android' as const,
      osVersion: '14',
      sdkVersion: 'rn-sinch-push/1.1.0',
      bundleId: 'com.example.app',
      backgroundService: 'ENABLED_RUNNING' as const,
    };

    function subscribeWith(deviceInfo?: Parameters<DefaultPushRepository['sendDeviceToken']>[3]) {
      const seen: any[] = [];
      const repo = new DefaultPushRepository(
        fakeTransport((_method, request) => {
          seen.push(request);
          return undefined;
        }),
      );
      return repo.sendDeviceToken('tok', 'jwt-1', CONFIG_ID, deviceInfo).then(() => seen[0]);
    }

    it('sends all six fields next to token and config', async () => {
      const request = await subscribeWith(toSubscribeDeviceInfo(info));

      expect(request.token).toBe('tok');
      expect(request.config).toBe(CONFIG_ID);
      expect(request.installationId).toBe(info.installationId);
      expect(request.platform).toBe(4); // resources.Platform.ANDROID, NOT ws Platform
      expect(request.osVersion).toBe('14');
      expect(request.sdkVersion).toBe('rn-sinch-push/1.1.0');
      expect(request.bundleId).toBe('com.example.app');
      expect(request.backgroundService).toBe(3); // ENABLED_RUNNING
    });

    it('maps ios to resources.Platform.IOS (3)', async () => {
      const request = await subscribeWith(toSubscribeDeviceInfo({ ...info, platform: 'ios' }));
      expect(request.platform).toBe(3);
    });

    it.each([
      ['UNSUPPORTED', 1],
      ['DISABLED', 2],
      ['ENABLED_RUNNING', 3],
      ['ENABLED_NOT_RUNNING', 4],
    ] as const)('maps background_service %s to %i', async (name, number) => {
      const request = await subscribeWith(toSubscribeDeviceInfo({ ...info, backgroundService: name }));
      expect(request.backgroundService).toBe(number);
    });

    it('puts the fields on the wire under field numbers 5-10', () => {
      const bytes = toBinary(
        SubscribeRequestSchema,
        create(SubscribeRequestSchema, {
          token: 'tok',
          config: CONFIG_ID,
          ...toSubscribeDeviceInfo(info),
        }),
      );
      // tag = (field << 3) | wire type; platform (6) and background_service (10)
      // are varints, so each is its tag byte followed by the enum number.
      const hex = Buffer.from(bytes).toString('hex');
      expect(hex).toContain('3004'); // field 6 = 4 (ANDROID)
      expect(hex).toContain('5003'); // field 10 = 3 (ENABLED_RUNNING)
      expect(hex).toContain('2a24' + Buffer.from(info.installationId).toString('hex')); // field 5, 36 bytes
    });

    it('omits the fields entirely without device info (old behaviour)', async () => {
      const request = await subscribeWith();
      expect(request).toEqual(create(SubscribeRequestSchema, { token: 'tok', config: CONFIG_ID }));
      expect(request.installationId).toBeUndefined();
      expect(request.platform).toBeUndefined();
      expect(request.backgroundService).toBeUndefined();
    });

    it('leaves out empty strings and unknown names rather than sending zero values', () => {
      expect(
        toSubscribeDeviceInfo({
          ...info,
          osVersion: '',
          bundleId: '',
          backgroundService: 'SOMETHING_NEW' as any,
        }),
      ).toEqual({
        installationId: info.installationId,
        platform: 4,
        sdkVersion: 'rn-sinch-push/1.1.0',
      });
    });
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

  describe('reportEvents', () => {
    const events = [
      { messageId: 'm1', subscriberId: 's1' },
      { messageId: 'm2', subscriberId: 's2' },
    ];

    function report(accessToken: string) {
      const seen: Array<{ method: string; request: any; authorization: string | null | undefined }> =
        [];
      const repo = new DefaultPushRepository(
        fakeTransport((method, request, header) => {
          seen.push({ method, request, authorization: new Headers(header).get('authorization') });
          return undefined;
        }),
      );
      return repo.reportEvents(events, accessToken).then(() => seen);
    }

    it('calls ReportEvents once with every event', async () => {
      const seen = await report('jwt-1');

      expect(seen).toHaveLength(1);
      expect(seen[0]?.method).toBe('ReportEvents');
      expect(seen[0]?.request.events.map((e: any) => [e.messageId, e.subscriberId])).toEqual([
        ['m1', 's1'],
        ['m2', 's2'],
      ]);
    });

    it('reports every event as DELIVERED and nothing else', async () => {
      const [call] = await report('jwt-1');

      expect(call?.request).toEqual(
        create(ReportEventsRequestSchema, {
          events: events.map((e) => ({ ...e, eventType: PushEventType.DELIVERED })),
        }),
      );
      expect(call?.request.events.map((e: any) => e.eventType)).toEqual([300, 300]);
    });

    it('sends the JWT as the authorization header', async () => {
      const [call] = await report('jwt-1');

      expect(call?.authorization).toBe('jwt-1');
    });

    it('lets a transport error reach the caller', async () => {
      const repo = new DefaultPushRepository(
        fakeTransport(() => {
          throw new Error('boom');
        }),
      );

      await expect(repo.reportEvents(events, 'jwt-1')).rejects.toThrow('boom');
    });
  });
});
