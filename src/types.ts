export type DeviceTokenType = 'apns' | 'fcm';

export interface DeviceToken {
  token: string;
  type: DeviceTokenType;
}

export type SinchEnv = 'eu1' | 'us1' | 'custom';

export interface SinchPushConfig {
  projectID: string;
  clientID: string;
  configID: string;
  env: SinchEnv;
  customPushApiUrl?: string;
  customChatApiUrl?: string;
  enableLogging?: boolean;
  autoRegisterForToken?: boolean;
}

export interface SignedIdentity {
  userID: string;
  signedUserID: string;
}

export interface SinchPushMessage {
  identity?: string;
  data: Record<string, string>;
  title?: string;
  body?: string;
  source: DeviceTokenType;
}

export interface Subscription {
  remove(): void;
}

/**
 * A single choice/action attached to a choice, card or carousel message.
 *
 * The proto `Choice` is itself a `oneof` over text/url/call/location. We
 * flatten it the same way the Swift SDK's `createChoicesArray` does
 * (`MessageDataSource.swift:663`): `title` is the human-readable label and
 * `value` is the actionable payload (postback data, URL, or phone number).
 */
export interface InAppMessageChoice {
  title: string;
  value?: string;
}

export interface InAppMessageCard {
  title: string;
  description?: string;
  choices: InAppMessageChoice[];
  url: string;
}

/**
 * A decoded in-app message. Mirrors the six cases the Swift
 * `InAppMessageController.parseMessage` switch handles.
 */
export type InAppMessage =
  | { kind: 'text'; text: string }
  | { kind: 'media'; url: string }
  | {
      kind: 'location';
      title?: string;
      label?: string;
      latitude: number;
      longitude: number;
    }
  | { kind: 'choice'; text: string; choices: InAppMessageChoice[] }
  | {
      kind: 'card';
      title: string;
      description?: string;
      choices: InAppMessageChoice[];
      url: string;
    }
  | {
      kind: 'carousel';
      cards: InAppMessageCard[];
      choices: InAppMessageChoice[];
    };

export type PushReceiveHandler = (message: SinchPushMessage) => void;

export type InAppMessageHandler = (message: InAppMessage) => void;

export type TokenReceiveHandler = (token: DeviceToken) => void;
