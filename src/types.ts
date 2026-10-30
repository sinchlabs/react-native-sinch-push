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
  /**
   * iOS only. Setting `appGroup` turns on the Notification Service Extension
   * support: native mirrors the minimal report credential
   * (`{ accessToken, reportBaseURL, userId, appId }`, never the HMAC secret) into
   * the App Group container so the extension can report a push as delivered
   * before the app runs. The group must be the one on both the app and the
   * extension target. Without it the SDK still uploads reports from a
   * background wake with a background URLSession, using app-private storage.
   * Ignored on Android.
   */
  ios?: {
    /** e.g. `group.com.example.app`. */
    appGroup?: string;
  };
  socket?: {
    /**
     * Persisted relay switch; the relay is off by default, so pass `true` to
     * opt in (on Android also set the gradle property `SinchPush_relay=true`).
     * Omitted preserves the stored value (default false), so an app that
     * enabled the relay before upgrading to 1.1.0 stays on until it passes
     * `false`. While off, socket starts reject with E_RELAY_DISABLED.
     *
     * On Android without `SinchPush_relay=true` the relay is not built in:
     * `isRelayEnabled()` reads `false` even after `true` is passed here.
     */
    enabled?: boolean;
    /**
     * Relay URL; overrides the region. Without it, env 'custom' derives the relay from
     * `customPushApiUrl` when that is a known Sinch push host, and has the relay disabled otherwise.
     */
    customWsUrl?: string;
    allowInsecureWs?: boolean;
  };
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

/** `Subscribe.background_service` / `Hello.background_service` (SB-60), by name. */
export type BackgroundServiceName =
  | 'UNSUPPORTED'
  | 'DISABLED'
  | 'ENABLED_RUNNING'
  | 'ENABLED_NOT_RUNNING'
  | 'RELAY_DISABLED'; // the relay is off in the SDK (SB-66)

/**
 * What native reports about this install: the same facts the relay is told in
 * `Hello` (SB-59) and the push API in `Subscribe`.
 */
export interface DeviceInfo {
  /** The per-install id. */
  installationId: string;
  platform: 'ios' | 'android';
  osVersion: string;
  /** `"<sdk-name>/<version>"`. */
  sdkVersion: string;
  /** iOS bundle identifier / Android applicationId. */
  bundleId: string;
  backgroundService: BackgroundServiceName;
}
