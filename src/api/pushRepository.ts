import { createClient, type Transport } from '@connectrpc/connect';
import {
  GetPublicKeyRequestSchema,
  SdkService,
  SubscribeRequestSchema,
  UnsubscribeRequestSchema,
} from '../generated/sinch/push/sdk/v1beta1/sdk_pb';
import { create } from '@bufbuild/protobuf';

export interface PushRepository {
  sendDeviceToken(token: string, accessToken: string, configID: string): Promise<void>;
  unsubscribe(currentDeviceToken: string, accessToken: string, configID: string): Promise<void>;
  getPublicKey(configID: string, accessToken: string): Promise<string>;
}

export class DefaultPushRepository implements PushRepository {
  constructor(private transport: Transport) {}

  async sendDeviceToken(token: string, accessToken: string, configID: string): Promise<void> {
    const client = createClient(SdkService, this.transport);
    await client.subscribe(
      create(SubscribeRequestSchema, { token, config: configID }),
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
}
