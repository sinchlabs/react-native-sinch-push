// Public types for the persistent WebSocket delivery channel.
// See docs/push-socket-protocol.md.

export interface PushSocketConfig {
  /**
   * Full WebSocket URL, e.g. `ws://10.0.2.2:8080/ws`. Used as is (dev tooling,
   * contract tests). When omitted, it is resolved from the `SinchPushConfig`
   * passed to `initialize`: `socket.customWsUrl`, else the region's relay
   * URL. Rejects with `E_RELAY_DISABLED` when the relay is not available there,
   * or while the relay is off (the default; see `socket.enabled`).
   */
  url?: string;
  /**
   * The sinch-chat JWT sent in the `Hello` frame. The relay verifies it and
   * binds the connection to its claims. Omit it: it defaults to the JWT stored
   * by `setIdentity` (Keychain / Keystore), and a later `setIdentity` that mints
   * a new JWT restarts the socket with it. Passing it pins that token; nothing
   * refreshes it.
   */
  authToken?: string;
  /**
   * Project id the relay checks against the JWT's `projectId`. Defaults to the
   * `projectID` passed to `initialize`.
   */
  projectId?: string;
  /**
   * `Hello.app_id`; the relay requires it to equal the JWT's `appId` claim.
   * Defaults to that claim of the token in use.
   */
  appId?: string;
  /**
   * `Hello.user_id`; the relay requires it to equal the JWT's `uuid` claim.
   * Defaults to that claim of the token in use.
   */
  userId?: string;
  /**
   * Ignored. `Hello.background` is computed natively (SB-57): `false` on iOS
   * and in-process on Android, `!appVisible at connect` in the Android service.
   * Kept so existing configs keep compiling.
   */
  background?: boolean;
  /**
   * Development and tests only. Overrides the `sdk_version` the socket's `Hello`
   * carries; leave unset in an app. It is never reported on `Subscribe` or by
   * `getDeviceInfo()`, which always give the SDK's own version.
   */
  sdkVersion?: string;
  /** Override the server-recommended poll interval. */
  pollIntervalMs?: number;
  /**
   * Android only: run the socket inside a foreground service so it survives
   * backgrounding. Default `true`.
   *
   * Ignored since the socket became native on every platform; kept so existing
   * configs keep compiling.
   */
  useForegroundService?: boolean;
  /**
   * When a socket message should also be posted as a local system
   * notification. The three-value form is the current one; the boolean is
   * kept so existing configs keep compiling — `true` means `always`.
   *
   *   * `whenUnhandled` posts when the host registered no in-app handler, or the
   *     app is in the background (Android; a handler can't show it there)
   *   * `always` posts every message
   *   * `never` emits the event and posts nothing
   *
   * Posting a notification reports DISPLAYED.
   */
  displayNotifications?: boolean | SocketDisplayRule;
}

/** The display-rule values. See `PushSocketConfig.displayNotifications`. */
export type SocketDisplayRule = 'whenUnhandled' | 'always' | 'never';

export type PushSocketStatus =
  | 'idle'
  | 'connecting'
  | 'connected'
  | 'reconnecting'
  | 'error'
  /**
   * The relay closed with UNAUTHORIZED and the client will not retry
   * (SB-48). Distinct from `error` so a host can tell "our credential was
   * refused" apart from any other failure — the only fix is a token refresh.
   */
  | 'auth_required'
  /**
   * The relay closed with BG_RESUMED: another surface owns this session
   * (SB-49). Distinct from `stopped` for the same reason.
   */
  | 'replaced'
  | 'stopped';

export interface PushSocketState {
  status: PushSocketStatus;
  /**
   * Which side owns the socket. `'native'` on both platforms since the client
   * moved out of JS; `'js'` is kept so a config written against 1.0.x still
   * parses.
   */
  transport?: 'native' | 'js';
  connectionId?: string;
  pollIntervalMs?: number;
  reconnectAttempts?: number;
  lastError?: string;
}

export interface PushSocketMessage {
  /** Server-assigned message id (deduplication key). */
  id: string;
  sinchMessageId: string;
  ackToken: string;
  title?: string;
  body?: string;
  imageUrl?: string;
  metadata: Record<string, string>;
  importance: number;
  trigger?: string;
  enqueuedAt: number;
  receivedAt: number;
  /** True when surfaced by the Android background service. */
  background: boolean;
  /** True when a local system notification was posted. */
  shown: boolean;
}

export type SocketMessageHandler = (message: PushSocketMessage) => void;
export type SocketStateHandler = (state: PushSocketState) => void;
