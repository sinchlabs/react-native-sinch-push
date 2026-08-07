import { create } from '@bufbuild/protobuf';
import { createClient } from '@connectrpc/connect';
import type { Transport } from '@connectrpc/connect';
import {
  IssueAnonymousTokenRequestSchema,
  IssueTokenWithSignedUuidRequestSchema,
  SdkService,
} from '../generated/sinch/chat/sdk/v1alpha2/sdk_pb';

export type Region = 'eu1' | 'us1' | 'custom';

export type SinchIdentity =
  | { kind: 'anonymous' }
  | { kind: 'selfSigned'; userId: string; signedUserId: string }
  | { kind: 'selfSignedWithAppSecret'; userId: string; appSecret: string };

export interface AppConfig {
  clientID: string;
  projectID: string;
  configID: string;
  region: Region;
}

export class AuthModel {
  accessToken: string;
  sinchIdentity: SinchIdentity;
  clientID: string;
  projectID: string;
  configID: string;
  region: Region;

  constructor(opts: {
    accessToken: string;
    sinchIdentity: SinchIdentity;
    clientID: string;
    projectID: string;
    configID: string;
    region: Region;
  }) {
    this.accessToken = opts.accessToken;
    this.sinchIdentity = opts.sinchIdentity;
    this.clientID = opts.clientID;
    this.projectID = opts.projectID;
    this.configID = opts.configID;
    this.region = opts.region;
  }

  get identityHash(): string {
    // Match the formula in DefaultAuthDataSource.identityHashOf so the
    // cache check compares apples to apples. The hash is a stable,
    // human-readable string keyed by the identity form and values.
    if (this.sinchIdentity.kind === 'selfSignedWithAppSecret') {
      return `selfSigned.${this.sinchIdentity.userId}`;
    }
    if (this.sinchIdentity.kind === 'selfSigned') {
      return `selfSigned.${this.sinchIdentity.userId}.${this.sinchIdentity.signedUserId}`;
    }
    return 'anonymous';
  }

  getUserID(): string | null {
    try {
      const parts = this.accessToken.split('.');
      if (parts.length !== 3 || !parts[1]) return null;
      const padded = parts[1].padEnd(
        parts[1].length + ((4 - (parts[1].length % 4)) % 4),
        '='
      );
      const json = atob(padded.replace(/-/g, '+').replace(/_/g, '/'));
      const payload: unknown = JSON.parse(json);
      if (typeof payload !== 'object' || payload === null || !('uuid' in payload)) {
        return null;
      }
      const uuid = payload.uuid;
      return typeof uuid === 'string' ? uuid : null;
    } catch {
      return null;
    }
  }
}

export interface AuthRepository {
  createAnonymousToken(config: AppConfig): Promise<AuthModel>;
  createSignedToken(config: AppConfig, userId: string, secret: string): Promise<AuthModel>;
}

export class DefaultAuthRepository implements AuthRepository {
  constructor(private transport: Transport) {}

  async createAnonymousToken(config: AppConfig): Promise<AuthModel> {
    const client = createClient(SdkService, this.transport);
    const res = await client.issueAnonymousToken(
      create(IssueAnonymousTokenRequestSchema, {
        projectId: config.projectID,
        clientId: config.clientID,
      })
    );
    return new AuthModel({
      accessToken: res.accessToken,
      sinchIdentity: { kind: 'anonymous' },
      clientID: config.clientID,
      projectID: config.projectID,
      configID: config.configID,
      region: config.region,
    });
  }

  async createSignedToken(config: AppConfig, userId: string, secret: string): Promise<AuthModel> {
    const client = createClient(SdkService, this.transport);
    const res = await client.issueTokenWithSignedUuid(
      create(IssueTokenWithSignedUuidRequestSchema, {
        projectId: config.projectID,
        clientId: config.clientID,
        uuid: userId,
        uuidHash: secret,
      })
    );
    return new AuthModel({
      accessToken: res.accessToken,
      sinchIdentity: { kind: 'selfSigned', userId, signedUserId: secret },
      clientID: config.clientID,
      projectID: config.projectID,
      configID: config.configID,
      region: config.region,
    });
  }
}
