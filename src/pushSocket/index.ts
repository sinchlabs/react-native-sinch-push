// Public facade for the persistent WebSocket delivery channel.
//
// The socket itself is native on both platforms; this module is only the JS
// side of it:
//   * Android -> SinchPushSocketService owns the socket in a foreground
//     service, so it keeps polling while the app is backgrounded/terminated.
//   * iOS     -> the Swift client, foreground-only: it closes the
//     socket on `didEnterBackground` and reconnects on resume, so nothing
//     connects while the app is away.
// Native events feed the same handlers and the same pending-message store on
// both platforms, so the public API does not depend on the transport.

import { NativeEventEmitter, NativeModules } from 'react-native';
import type { Spec } from '../NativeSinchPush';
import { decodeJwtClaims } from '../api/jwtClaims';
import { resolveWsUrl } from '../api/transport';
import type { SinchPushConfig } from '../types';
import type {
  PushSocketConfig,
  PushSocketMessage,
  PushSocketState,
  SocketDisplayRule,
  SocketMessageHandler,
  SocketStateHandler,
} from './types';

export type {
  PushSocketConfig,
  PushSocketMessage,
  PushSocketState,
  PushSocketStatus,
  SocketDisplayRule,
  SocketMessageHandler,
  SocketStateHandler,
} from './types';

export const EVENT_SOCKET_MESSAGE = 'SinchPush:onSocketMessage';
export const EVENT_SOCKET_STATE = 'SinchPush:onSocketState';

const isTurboModuleEnabled = (global as any).__turboModuleProxy != null;
const resolvedModule: Spec | undefined = isTurboModuleEnabled
  ? require('../NativeSinchPush').default
  : NativeModules.SinchPush;

const native: Spec | undefined = resolvedModule;
const emitter = native
  ? new NativeEventEmitter(
      native as unknown as ConstructorParameters<typeof NativeEventEmitter>[0]
    )
  : null;

const messageHandlers = new Set<SocketMessageHandler>();
const stateHandlers = new Set<SocketStateHandler>();
const store = new Map<string, PushSocketMessage>();

// What the native client was last started with (credentials resolved).
let activeConfig: PushSocketConfig | null = null;
// What the host asked for, kept so a new JWT can restart the socket with the
// credentials derived again. Null once the socket was stopped on purpose.
let requestedConfig: PushSocketConfig | null = null;
let storedTokenProvider: (() => Promise<string | null>) | null = null;
let initializedConfig: SinchPushConfig | null = null;
let nativeListenersInstalled = false;
let nativePollTimer: ReturnType<typeof setInterval> | null = null;
let lastNativeStateKey = '';
// Tail of the queue every start / stop / refresh goes through (never rejects).
let socketLock: Promise<unknown> = Promise.resolve();

/**
 * Runs `fn` after every earlier start / stop / refresh has settled. Without it a
 * restart that is mid-flight (it read the old JWT, then awaited native) can
 * resume after a stop or a newer restart and start the socket with stale
 * credentials. A failure goes to the caller and does not poison the queue.
 */
function runSocketExclusive<T>(fn: () => Promise<T>): Promise<T> {
  const result = socketLock.then(fn);
  socketLock = result.catch(() => {});
  return result;
}

// The Android foreground service owns the socket in a separate thread and its
// events can be missed while JS is detached (backgrounded) or under the
// bridgeless runtime. Polling the native store is the reliable path and also
// recovers notifications received while the app was away.
async function pollNativeOnce(): Promise<void> {
  if (!native) {
    return;
  }
  try {
    const raw = (await native.getPushSocketState()) as unknown as PushSocketState;
    if (raw) {
      const next: PushSocketState = { ...raw, transport: 'native' };
      const key = JSON.stringify(next);
      if (key !== lastNativeStateKey) {
        lastNativeStateKey = key;
        dispatchState(next);
      }
    }
  } catch {
    // ignore
  }
  try {
    const list = (await native.getPendingPushMessages()) as unknown as PushSocketMessage[];
    if (Array.isArray(list)) {
      for (const m of list) {
        if (m && m.id && !store.has(m.id)) {
          dispatchMessage(m);
        }
      }
    }
  } catch {
    // ignore
  }
}

function startNativePolling(): void {
  stopNativePolling();
  nativePollTimer = setInterval(() => {
    void pollNativeOnce();
  }, 1500);
  void pollNativeOnce();
}

function stopNativePolling(): void {
  if (nativePollTimer != null) {
    clearInterval(nativePollTimer);
    nativePollTimer = null;
  }
  lastNativeStateKey = '';
}

function ensureNativeListeners(): void {
  if (nativeListenersInstalled || !emitter) {
    return;
  }
  nativeListenersInstalled = true;
  emitter.addListener(EVENT_SOCKET_MESSAGE, (m: PushSocketMessage) => {
    dispatchMessage(m);
  });
  emitter.addListener(EVENT_SOCKET_STATE, (s: PushSocketState) => {
    dispatchState(s);
  });
}

function dispatchMessage(message: PushSocketMessage): void {
  if (!message || !message.id) {
    return;
  }
  store.set(message.id, message);
  for (const handler of messageHandlers) {
    handler(message);
  }
}

function dispatchState(state: PushSocketState): void {
  for (const handler of stateHandlers) {
    handler(state);
  }
}

/** Called by `initialize` so `startPushSocket` can resolve the relay URL. */
export function setPushSocketInitConfig(config: SinchPushConfig | null): void {
  initializedConfig = config;
}

/**
 * Called by `initialize`: how to read the JWT `setIdentity` stored, which is the
 * `authToken` of a `startPushSocket` that passes none.
 */
export function setPushSocketTokenProvider(
  provider: (() => Promise<string | null>) | null
): void {
  storedTokenProvider = provider;
}

/**
 * `E_RELAY_DISABLED` has two sources that share one code: no relay URL for the
 * region and the relay off switch, which is the default (native owns the
 * persisted switch; both are rejected here, with the opt-in spelled out).
 */
export type PushSocketErrorCode =
  | 'E_RELAY_DISABLED'
  | 'E_NOT_INITIALIZED'
  | 'E_NOT_AUTHENTICATED';

function socketError(code: PushSocketErrorCode, message: string): Error {
  const err = new Error(`${code}: ${message}`);
  (err as Error & { code: string }).code = code;
  return err;
}

/**
 * What `E_RELAY_DISABLED` tells an integrator when the relay switch is off: the
 * relay is opt-in, and on Android the manifest side is opt-in too.
 */
const RELAY_OPT_IN_HINT =
  'the relay (push socket) is off by default; pass socket.enabled: true to initialize() ' +
  '(or call setRelayEnabled(true)) and, on Android, set the gradle property SinchPush_relay=true';

function isRelayDisabledError(e: unknown): boolean {
  return (e as { code?: unknown } | null)?.code === 'E_RELAY_DISABLED';
}

/** The url to connect to: the explicit one, else resolved from `initialize`'s config. */
function resolveSocketUrl(config: PushSocketConfig): string {
  if (config.url) {
    return config.url;
  }
  if (!initializedConfig) {
    throw socketError(
      'E_NOT_INITIALIZED',
      'startPushSocket without a url requires initialize() to have been called'
    );
  }
  const resolved = resolveWsUrl(initializedConfig);
  if ('disabled' in resolved) {
    throw socketError('E_RELAY_DISABLED', resolved.disabled);
  }
  return resolved.url;
}

/** The persisted relay switch, or `undefined` when native cannot say. */
async function relaySwitchState(): Promise<boolean | undefined> {
  try {
    const enabled = await native?.isRelayEnabled();
    return typeof enabled === 'boolean' ? enabled : undefined;
  } catch {
    return undefined;
  }
}

async function storedToken(): Promise<string | null> {
  if (!storedTokenProvider) {
    return null;
  }
  try {
    return (await storedTokenProvider()) || null;
  } catch {
    return null;
  }
}

/**
 * Fills in what the host left out so the `Hello` cannot disagree with the JWT
 * (the relay refuses a `Hello` whose `app_id` / `user_id` / `project_id` differ
 * from the JWT's `appId` / `uuid` / `projectId`): `authToken` is the JWT
 * `setIdentity` stored, `appId` and `userId` are that token's `appId` and
 * `uuid` claims, `projectId` is the token's `projectId` claim, else the
 * `projectID` given to `initialize` (a warning when the two differ: the relay
 * checks the token's).
 *
 * An expired token (`exp` in the past) is refused here rather than sent to a
 * relay that would refuse it: `E_NOT_AUTHENTICATED`.
 */
async function resolveCredentials(
  config: PushSocketConfig
): Promise<PushSocketConfig> {
  const authToken = config.authToken || (await storedToken());
  if (!authToken) {
    throw socketError(
      'E_NOT_AUTHENTICATED',
      'startPushSocket without an authToken requires setIdentity() to have stored a JWT'
    );
  }
  const claims = decodeJwtClaims(authToken);
  if (claims?.exp !== undefined && claims.exp * 1000 <= Date.now()) {
    throw socketError(
      'E_NOT_AUTHENTICATED',
      'the authToken has expired; call setIdentity() again to mint a new one'
    );
  }
  const initProjectId = initializedConfig?.projectID;
  if (
    !config.projectId &&
    claims?.projectId &&
    initProjectId &&
    claims.projectId !== initProjectId
  ) {
    // eslint-disable-next-line no-console
    console.warn(
      `[sinch] the JWT's projectId (${claims.projectId}) differs from initialize's projectID (${initProjectId}); using the JWT's`
    );
  }
  const resolved: PushSocketConfig = {
    ...config,
    authToken,
    projectId: config.projectId || claims?.projectId || initProjectId,
    appId: config.appId || claims?.appId,
    userId: config.userId || claims?.uuid,
  };
  if (!resolved.appId || !resolved.userId) {
    throw socketError(
      'E_NOT_AUTHENTICATED',
      'startPushSocket requires appId and userId (not found in the JWT claims either)'
    );
  }
  return resolved;
}

/**
 * Opens the native socket. `config.url` is optional: when omitted it is
 * resolved from the config passed to `initialize`.
 *
 * `authToken`, `appId`, `userId` and `projectId` are optional too: they default
 * to the JWT stored by `setIdentity` and its claims (see `PushSocketConfig`).
 * A later `setIdentity` that mints a new JWT restarts the socket with it.
 *
 * Rejects with:
 *   * `E_NOT_AUTHENTICATED` when no `authToken` was given and `setIdentity` has
 *     stored none, when the token has expired, or when it is not a JWT with
 *     `appId` and `uuid` claims and the config gives no `appId` / `userId`.
 *   * `E_RELAY_DISABLED` when the relay switch is off (SB-66) — the default:
 *     pass `socket.enabled: true` to `initialize` (on Android also set the
 *     gradle property `SinchPush_relay=true`) — or when there is no relay URL
 *     for the region (rejected here, before native is called).
 *   * `E_FGS_START_REFUSED` on Android when the platform refuses the
 *     foreground service that owns the socket; the socket state is then
 *     `error`.
 *   * `E_START_PUSH_SOCKET` for any other failure native reports.
 *
 * A refusal leaves nothing behind: no active config and no poll. A failure
 * after the start resolved is reported through the state only.
 */
export function startPushSocket(requested: PushSocketConfig): Promise<void> {
  return runSocketExclusive(() => startLocked(requested));
}

async function startLocked(requested: PushSocketConfig): Promise<void> {
  // First, so that an integrator who never opted in is told so rather than that
  // they are not logged in. Only an explicit `false` refuses: a native module
  // that cannot answer leaves the decision to its own `startPushSocket`.
  if (native && (await relaySwitchState()) === false) {
    // Nothing is running natively (the switch off stopped it), so what JS
    // still holds from an earlier start - the config with its JWT, the poll -
    // must go too, or a later setIdentity would restart a socket the host
    // turned off.
    await stopLocked(false);
    throw socketError('E_RELAY_DISABLED', RELAY_OPT_IN_HINT);
  }
  const config: PushSocketConfig = {
    ...(await resolveCredentials(requested)),
    url: resolveSocketUrl(requested),
  };
  if (!native) {
    // No JS client to fall back on: the native module owns the socket on every
    // platform, so an unlinked module is a hard error rather than a silent
    // "started" that never connects.
    throw new Error('startPushSocket requires the native SinchPush module');
  }
  ensureNativeListeners();
  await stopLocked();
  activeConfig = config;
  try {
    await native.startPushSocket(nativeConfig(config) as unknown as Object);
  } catch (e) {
    // Native refused (the relay is off, the foreground service was refused), so
    // nothing is running: the config must not stay behind as the "current" one
    // for a socket that does not exist, and the poll must not start.
    activeConfig = null;
    // Native's message does not name the opt-in, and on Android it cannot know
    // about the gradle property: say it here - unless the switch reads `true`,
    // where the refusal is about something else (e.g. the Android build without
    // `SinchPush_relay=true`) and native's message is the accurate one.
    if (isRelayDisabledError(e) && (await relaySwitchState()) !== true) {
      throw socketError('E_RELAY_DISABLED', RELAY_OPT_IN_HINT);
    }
    throw e;
  }
  requestedConfig = requested;
  // The display rule runs natively, so it needs to know whether the host
  // registered an in-app handler *now*, not only at start time.
  await publishHandlerRegistration();
  startNativePolling();
}

/**
 * Called after `setIdentity` / `removeIdentity` changed the stored JWT: a socket
 * started without an explicit `authToken` is restarted with the new one (the
 * config is re-passed to `startPushSocket`, which native persists, so a restart
 * of the Android service loads the fresh token), or stopped when the identity
 * is gone. A pinned `authToken`, a stopped socket and an unchanged token are
 * left alone. Never rejects.
 */
export function refreshPushSocketAuth(): Promise<void> {
  // Queued behind any start / stop in flight and reading the requested config
  // and the token only when its turn comes, so it acts on the final state.
  return runSocketExclusive(async () => {
    try {
      const requested = requestedConfig;
      if (!requested || requested.authToken) {
        return;
      }
      const token = await storedToken();
      if (!token) {
        await stopLocked();
      } else if (token !== activeConfig?.authToken) {
        await startLocked(requested);
      }
    } catch (e) {
      // eslint-disable-next-line no-console
      console.warn('[sinch] restarting the push socket with the new JWT failed', e);
    }
  });
}

/**
 * The map the native module gets.
 *
 * Two normalisations happen here rather than natively, because they are about
 * what the *JS API* accepts rather than about what the protocol means:
 *
 *   * `displayNotifications` is the three-value rule, but 1.0.x configs pass a
 *     boolean. `true` becomes `always` and `false` becomes `never`, so an old
 *     config keeps its meaning instead of silently becoming `whenUnhandled`.
 *   * `background` is dropped: `Hello.background` is computed natively
 *     (SB-57) from the owner and the app's visibility at connect. Leaving it
 *     in the map would keep an invitation to set it that nothing honours.
 */
function nativeConfig(config: PushSocketConfig): Record<string, unknown> {
  const { displayNotifications, background: _background, ...rest } = config;
  const rule: SocketDisplayRule =
    typeof displayNotifications === 'boolean'
      ? displayNotifications
        ? 'always'
        : 'never'
      : displayNotifications ?? 'whenUnhandled';
  return { ...rest, displayNotifications: rule };
}

/**
 * Tell native whether an in-app handler exists.
 *
 * Best effort by design: a rejection means the native side could not apply the
 * rule, not a failure the host should see — the socket keeps working, it just
 * also posts its notification.
 */
async function publishHandlerRegistration(): Promise<void> {
  if (!native) {
    return;
  }
  try {
    await native.setSocketHandlerRegistered(messageHandlers.size > 0);
  } catch {
    // ignore
  }
}

/**
 * Report DISPLAYED / DISMISSED for a message the host surfaced itself.
 *
 * The socket is native on both platforms, so this reaches the native client on
 * both: iOS queues it in the persisted outbox when the socket is suspended,
 * Android forwards it to whichever surface owns the socket.
 */
export async function reportPushMessageStatus(
  messageId: string,
  status: 'displayed' | 'dismissed'
): Promise<void> {
  if (!messageId) {
    throw new Error('reportPushMessageStatus requires a messageId');
  }
  if (status !== 'displayed' && status !== 'dismissed') {
    throw new Error(
      `reportPushMessageStatus status must be 'displayed' or 'dismissed', got '${status}'`
    );
  }
  if (!native) {
    return;
  }
  await native.reportPushMessageStatus(messageId, status);
}

export function stopPushSocket(callNative = true): Promise<void> {
  return runSocketExclusive(() => stopLocked(callNative));
}

async function stopLocked(callNative = true): Promise<void> {
  requestedConfig = null;
  activeConfig = null;
  stopNativePolling();
  if (callNative && native) {
    try {
      await native.stopPushSocket();
    } catch {
      // best effort
    }
  }
}

export async function getPushSocketState(): Promise<PushSocketState> {
  const base: PushSocketState = { status: 'idle', transport: 'native' };
  if (!native) {
    return base;
  }
  try {
    const s = (await native.getPushSocketState()) as unknown as PushSocketState;
    return s ? { ...base, ...s, transport: 'native' } : base;
  } catch {
    return base;
  }
}

export function sendPushSocketPoll(): void {
  // Kept for API compatibility. The native client owns the poll timer (and its
  // own server-negotiated interval) and the module exposes no way to trigger a
  // poll, so there is nothing for JS to poke.
}

export async function getPendingPushMessages(): Promise<PushSocketMessage[]> {
  if (native) {
    try {
      const nativeMessages = (await native.getPendingPushMessages()) as unknown as PushSocketMessage[];
      if (Array.isArray(nativeMessages)) {
        for (const m of nativeMessages) {
          if (m && m.id && !store.has(m.id)) {
            store.set(m.id, m);
          }
        }
      }
    } catch {
      // ignore — fall back to the store mirrored from native events
    }
  }
  return Array.from(store.values()).sort((a, b) => b.receivedAt - a.receivedAt);
}

export async function clearPendingPushMessages(): Promise<void> {
  store.clear();
  if (native) {
    try {
      await native.clearPendingPushMessages();
    } catch {
      // ignore
    }
  }
}

export async function displayNotification(
  title: string,
  body: string,
  data: Record<string, string> = {}
): Promise<void> {
  if (!native) {
    return;
  }
  await native.displayNotification(title, body, data as unknown as Object);
}

export function onSocketMessageHandler(handler: SocketMessageHandler): { remove(): void } {
  ensureNativeListeners();
  messageHandlers.add(handler);
  void publishHandlerRegistration();
  return {
    remove: () => {
      messageHandlers.delete(handler);
      void publishHandlerRegistration();
    },
  };
}

export function onSocketStateHandler(handler: SocketStateHandler): { remove(): void } {
  ensureNativeListeners();
  stateHandlers.add(handler);
  return {
    remove: () => {
      stateHandlers.delete(handler);
    },
  };
}

export function getActivePushSocketConfig(): PushSocketConfig | null {
  return activeConfig;
}
