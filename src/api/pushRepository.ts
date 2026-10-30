import { createClient, type Transport } from '@connectrpc/connect';
import {
  GetPublicKeyRequestSchema,
  ReportEventsRequestSchema,
  SdkService,
  SubscribeRequestSchema,
  UnsubscribeRequestSchema,
} from '../generated/sinch/push/sdk/v1beta1/sdk_pb';
import { create } from '@bufbuild/protobuf';
import { PushEventType } from '../generated/sinch/push/events/v1beta1/events_pb';
import type { SubscribeDeviceInfo } from './deviceInfo';

export interface PushRepository {
  sendDeviceToken(
    token: string,
    accessToken: string,
    configID: string,
    deviceInfo?: SubscribeDeviceInfo,
  ): Promise<void>;
  unsubscribe(currentDeviceToken: string, accessToken: string, configID: string): Promise<void>;
  getPublicKey(configID: string, accessToken: string): Promise<string>;
  /** Reports each message DELIVERED; rejects with the transport's error, unhandled. */
  reportEvents(
    events: ReadonlyArray<{ messageId: string; subscriberId: string }>,
    accessToken: string,
  ): Promise<void>;
}

export class DefaultPushRepository implements PushRepository {
  constructor(private transport: Transport) {}

  async sendDeviceToken(
    token: string,
    accessToken: string,
    configID: string,
    deviceInfo?: SubscribeDeviceInfo,
  ): Promise<void> {
    const client = createClient(SdkService, this.transport);
    await client.subscribe(
      create(SubscribeRequestSchema, { token, config: configID, ...deviceInfo }),
      accessToken ? { headers: { authorization: accessToken } } : undefined,
    );
  }

  async unsubscribe(
    currentDeviceToken: string,
    accessToken: string,
    configID: string,
  ): Promise<void> {
    try {
      const client = createClient(SdkService, this.transport);
      await client.unsubscribe(
        create(UnsubscribeRequestSchema, { token: currentDeviceToken, config: configID }),
        accessToken ? { headers: { authorization: accessToken } } : undefined,
      );
    } catch (e) {
      // mirrors Swift "log + return" semantics (PushRepository.swift:82-84)
      // eslint-disable-next-line no-console
      console.warn('[sinch] unsubscribe error', e);
    }
  }

  async getPublicKey(configID: string, accessToken: string): Promise<string> {
    const client = createClient(SdkService, this.transport);
    const res = await client.getPublicKey(
      create(GetPublicKeyRequestSchema, { config: configID }),
      accessToken ? { headers: { authorization: accessToken } } : undefined,
    );
    return res.publicKey;
  }

  async reportEvents(
    events: ReadonlyArray<{ messageId: string; subscriberId: string }>,
    accessToken: string,
  ): Promise<void> {
    const client = createClient(SdkService, this.transport);
    await client.reportEvents(
      create(ReportEventsRequestSchema, {
        events: events.map(({ messageId, subscriberId }) => ({
          messageId,
          subscriberId,
          eventType: PushEventType.DELIVERED,
        })),
      }),
      accessToken ? { headers: { authorization: accessToken } } : undefined,
    );
  }
}
