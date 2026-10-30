import './textEncoding';
import { AppState, NativeModules, Platform } from 'react-native';
import type { Spec } from './NativeSinchPush';
import {
  KeychainTokenStorage,
  accountKeyFor,
  DefaultAuthDataSource,
  DefaultAuthRepository,
  DefaultPushRepository,
  ReportOutboxFlusher,
  buildSharedReportRecord,
  buildTransport,
  resolveRegion,
  setAuthToken,
  defaultDeviceTokenStorage,
  resolveFingerprintStore,
} from './api';
import type {
  AuthDataSource,
  AuthRepository,
  DeviceTokenStorage,
  FingerprintStore,
  PushRepository,
  Transport,
} from './api';
import type { AppConfig, SinchIdentity } from './api/authRepository';
import { onInAppMessageHandler } from './api/inAppMessage';
import {
  subscribeToDeviceInfoChanged,
  subscribeToPush,
  subscribeToBackgroundWake,
  subscribeToReportQueued,
  subscribeToToken,
} from './api/eventBus';
import { isDeviceInfo, subscribeFingerprint, toSubscribeDeviceInfo } from './api/deviceInfo';
import {
  clearPendingPushMessages,
  displayNotification,
  getPendingPushMessages,
  getPushSocketState,
  onSocketMessageHandler,
  onSocketStateHandler,
  refreshPushSocketAuth,
  reportPushMessageStatus,
  sendPushSocketPoll,
  setPushSocketInitConfig,
  setPushSocketTokenProvider,
  startPushSocket,
  stopPushSocket,
} from './pushSocket';
import type {
  DeviceInfo,
  DeviceToken,
  DeviceTokenType,
  PushReceiveHandler,
  SinchPushConfig,
  SignedIdentity,
  Subscription,
  TokenReceiveHandler,
} from './types';

export type {
  BackgroundServiceName,
  DeviceInfo,
  DeviceToken,
  DeviceTokenType,
  InAppMessage,
  InAppMessageCard,
  InAppMessageChoice,
  InAppMessageHandler,
  PushReceiveHandler,
  SinchPushConfig,
  SinchPushMessage,
  SignedIdentity,
  Subscription,
  TokenReceiveHandler,
} from './types';

export type {
  PushSocketConfig,
  PushSocketMessage,
  PushSocketState,
  PushSocketStatus,
  SocketDisplayRule,
  SocketMessageHandler,
  SocketStateHandler,
} from './pushSocket';

const LINKING_ERROR =
  `The package 'react-native-sinch-push' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

const isTurboModuleEnabled =
  (global as any).__turboModuleProxy != null;

const resolvedModule: Spec | undefined = isTurboModuleEnabled
  ? require('./NativeSinchPush').default
  : NativeModules.SinchPush;

if (resolvedModule == null) {
  throw new Error(LINKING_ERROR);
}

const SinchPushNativeModule: Spec = resolvedModule;

export const EVENT_PUSH_RECEIVED = 'SinchPush:onPushReceived';
export const EVENT_TOKEN_RECEIVED = 'SinchPush:onTokenReceived';
export const EVENT_DEVICE_INFO_CHANGED = 'SinchPush:onDeviceInfoChanged';

/** Trailing debounce for `onDeviceInfoChanged` (a service start fires several). */
const DEVICE_INFO_DEBOUNCE_MS = 1000;

/** How long a background wake waits for the report flush before answering native `sent: false`. */
const BACKGROUND_WAKE_FLUSH_TIMEOUT_MS = 20_000;

let _config: SinchPushConfig | null = null;
let _authTransport: Transport | null = null;
let _pushTransport: Transport | null = null;
let _authDataSource: AuthDataSource | null = null;
let _authRepository: AuthRepository | null = null;
let _pushRepository: PushRepository | null = null;
let _deviceTokenStorage: DeviceTokenStorage = defaultDeviceTokenStorage;
let _fingerprintStore: FingerprintStore = resolveFingerprintStore(_deviceTokenStorage);
let _tokenResendSub: Subscription | null = null;
let _deviceInfoSub: Subscription | null = null;
let _deviceInfoTimer: ReturnType<typeof setTimeout> | null = null;
let _reportFlusher: ReportOutboxFlusher | null = null;
let _reportQueuedSub: Subscription | null = null;
let _appStateSub: { remove(): void } | null = null;
// Background wakes that arrived before `initialize` built the flusher.
let _flusherWaiters: Array<(flusher: ReportOutboxFlusher) => void> = [];
// iOS: the App Group is told to native before the first credential is mirrored.
let _sharedReportsConfigured: Promise<void> = Promise.resolve();
// Tail of the serialized Subscribe queue (never rejects). See `runExclusive`.
let _subscribeLock: Promise<unknown> = Promise.resolve();

export function initialize(
  config: SinchPushConfig,
  options: { deviceTokenStorage?: DeviceTokenStorage } = {},
): Promise<void> {
  if (!config.projectID) {
    return Promise.reject(new Error('initialize requires projectID'));
  }
  if (!config.clientID) {
    return Promise.reject(new Error('initialize requires clientID'));
  }
  if (!config.configID) {
    return Promise.reject(new Error('initialize requires configID'));
  }
  if (config.env === 'custom') {
    if (!config.customPushApiUrl) {
      return Promise.reject(new Error('customPushApiUrl is required when env is "custom"'));
    }
    if (!config.customChatApiUrl) {
      return Promise.reject(new Error('customChatApiUrl is required when env is "custom"'));
    }
  }

  _config = config;
  setPushSocketInitConfig(config);
  if (options.deviceTokenStorage) {
    _deviceTokenStorage = options.deviceTokenStorage;
  }
  _fingerprintStore = resolveFingerprintStore(_deviceTokenStorage);
  const { pushBaseUrl, chatBaseUrl } = resolveRegion(config);
  _authTransport = buildTransport({
    baseUrl: chatBaseUrl,
    useBinaryFormat: false,
    enableLogging: config.enableLogging,
  });
  _pushTransport = buildTransport({
    baseUrl: pushBaseUrl,
    enableLogging: config.enableLogging,
  });

  const account = accountKeyFor({
    clientID: config.clientID,
    projectID: config.projectID,
    configID: config.configID,
    region: config.env,
    customPushApiUrl: config.customPushApiUrl,
  });
  const storage = new KeychainTokenStorage(account);
  _authRepository = new DefaultAuthRepository(_authTransport);
  _authDataSource = new DefaultAuthDataSource(_authRepository, storage);
  _pushRepository = new DefaultPushRepository(_pushTransport);
  _reportFlusher = createReportFlusher(_pushRepository, _authDataSource);
  const waiting = _flusherWaiters;
  _flusherWaiters = [];
  for (const resolve of waiting) resolve(_reportFlusher);
  const authDataSource = _authDataSource;
  setPushSocketTokenProvider(() => authDataSource.currentAccessToken());
  _sharedReportsConfigured = configureSharedReports(config.ios?.appGroup);

  // Install the persistent token-event watcher BEFORE we trigger native token
  // capture so the very first emission (which may be the FCM token fetched
  // synchronously-enough after init) routes through the resend-on-change path.
  installTokenResendWatcher();
  installDeviceInfoWatcher();
  installReportOutboxWatchers();

  // The relay off switch (SB-66): an explicit `socket.enabled` is applied and
  // persisted natively *before* the start-up check below, so that check (and
  // any Subscribe it makes) sees `RELAY_DISABLED`; omitted, the persisted value
  // stands. Same queue as the check, so the two cannot interleave.
  const explicitRelay = config.socket?.enabled;
  const relayApplied =
    typeof explicitRelay === 'boolean'
      ? runExclusive(async () => {
          try {
            await applyRelaySwitch(explicitRelay);
          } catch (e) {
            // A switch native could not apply must not stop the SDK from
            // initializing: the host is warned here, and the start-up check
            // behind it still runs against whatever native holds.
            // eslint-disable-next-line no-console
            console.warn('[sinch] could not apply socket.enabled:', e);
          }
        })
      : null;

  // App start: the token is unchanged but the OS, the SDK or the background
  // service may not be what the last Subscribe carried. The check is
  // fire-and-forget: it is not part of the promise `initialize` returns.
  void runExclusive(() => resubscribeIfChanged()).catch((e) => {
    // eslint-disable-next-line no-console
    console.warn('[sinch] subscribe on start failed', e);
  });

  _authDataSource
    .currentAccessToken()
    .then((t) => {
      if (t) {
        setAuthToken(t);
        // A launch straight into the foreground emits no AppState change.
        if (AppState.currentState === 'active') flushReportOutbox();
        // Behind the queue, and reading the credential only once it is our turn: a
        // removeIdentity ahead of us has deleted it by then, so it cannot be mirrored back.
        void runExclusive(() => mirrorSharedReportSession());
      } else {
        // This account has no JWT, but native may still hold the session of a
        // previous initialize (another env or project: its reportBaseURL and
        // JWT). Re-checked on our turn, so a setIdentity queued ahead of us
        // that stored one is not wiped.
        void runExclusive(async () => {
          if (!(await authDataSource.currentAccessToken())) {
            await clearSharedReportSession();
          }
        });
      }
    })
    .catch(() => {});

  const autoRegister = config.autoRegisterForToken !== false;
  const registered: Promise<void> = autoRegister
    ? SinchPushNativeModule.registerForToken().then(() => undefined)
    : Promise.resolve();
  return relayApplied
    ? Promise.all([relayApplied, registered]).then(() => undefined)
    : registered;
}

/**
 * Persists the relay switch natively. Turning it off also drops the JS side of
 * a running socket (its config with the JWT, the state poll): native has
 * stopped, and a later `setIdentity` or `setRelayEnabled(true)` must not
 * restart it behind the host's back.
 */
async function applyRelaySwitch(enabled: boolean): Promise<void> {
  await SinchPushNativeModule.setRelayEnabled(enabled);
  if (!enabled) {
    await stopPushSocket(false);
  }
}

export async function setIdentity(signedIdentity: SignedIdentity): Promise<void> {
  if (!signedIdentity.userID) {
    throw new Error('setIdentity requires a non-empty userID');
  }
  if (!signedIdentity.signedUserID) {
    throw new Error('setIdentity requires a non-empty signedUserID');
  }
  if (!_config || !_authDataSource || !_pushRepository) {
    throw new Error('SinchPush not initialized. Call initialize() first.');
  }

  const identity: SinchIdentity = {
    kind: 'selfSigned',
    userId: signedIdentity.userID,
    signedUserId: signedIdentity.signedUserID,
  };
  const appConfig: AppConfig = {
    clientID: _config.clientID,
    projectID: _config.projectID,
    configID: _config.configID,
    region: _config.env,
  };
  const authDataSource = _authDataSource;
  const pushRepository = _pushRepository;

  // All of it behind the queue: minting the token stores it, and a non-awaited
  // removeIdentity(A) still ahead of us must finish - including its Unsubscribe
  // and deleting A's JWT - before B's token exists.
  await runExclusive(async () => {
    // Queued reports belong to the user their JWT was minted for; re-signing the
    // same user keeps them.
    const stored = await authDataSource.currentAuthorization();
    const previousOwner = stored?.sinchIdentity ? reportOwnerOf(stored.sinchIdentity) : null;
    if (previousOwner !== null && previousOwner !== reportOwnerOf(identity)) {
      await clearReportOutbox();
    }
    const token = await authDataSource.generateToken(appConfig, identity);
    await mirrorSharedReportSession(token);
    const dt = await getDeviceToken();
    if (dt?.token) {
      await subscribeWith(pushRepository, dt.token, token.accessToken);
    }
  });
  flushReportOutbox();
  // A new JWT restarts a socket that took the stored one. Not awaited: the
  // identity is set, and a native restart can take a while (it never rejects;
  // a failure is logged). It is queued behind any start / stop in flight.
  void refreshPushSocketAuth();
}

export async function removeIdentity(signedIdentity: SignedIdentity): Promise<void> {
  if (!signedIdentity.userID) {
    throw new Error('removeIdentity requires a non-empty userID');
  }
  if (!signedIdentity.signedUserID) {
    throw new Error('removeIdentity requires a non-empty signedUserID');
  }
  if (!_config || !_authDataSource) {
    return;
  }

  // A debounced re-subscribe must not outlive the identity it was for.
  cancelPendingDeviceInfoCheck();
  const config = _config;
  const authDataSource = _authDataSource;
  // Behind any Subscribe in flight, so that one cannot write the fingerprint
  // back after it has been cleared.
  await runExclusive(async () => {
    const dt = _deviceToken ?? (await getDeviceToken())?.token ?? null;
    const stored = await authDataSource.currentAccessToken();
    if (dt && stored && _pushRepository) {
      try {
        await _pushRepository.unsubscribe(dt, stored, config.configID);
      } catch {
      }
    }
    await clearReportOutbox();
    // Before the token goes: the mirrored credential must not outlive the identity even if the
    // deletion throws.
    await clearSharedReportSession();
    await authDataSource.deleteToken();
    await _deviceTokenStorage.clearLastSent();
    try {
      await _fingerprintStore.clearLastSubscribedFingerprint();
    } catch (e) {
      // eslint-disable-next-line no-console
      console.warn('[sinch] clearing the subscribe fingerprint failed', e);
    }
  });
  // The JWT is gone: a socket that took the stored one stops with it. Not
  // awaited, like in setIdentity.
  void refreshPushSocketAuth();
}

let _deviceToken: string | null = null;

export function setDeviceToken(token: string): void {
  if (!token) {
    throw new Error('setDeviceToken requires a non-empty token');
  }
  _deviceToken = token;
}

export async function getDeviceToken(): Promise<DeviceToken | null> {
  if (_deviceToken) {
    return { token: _deviceToken, type: defaultTokenType() };
  }

  const result = (await SinchPushNativeModule.getDeviceToken()) as
    | Partial<DeviceToken>
    | null
    | undefined;
  if (result == null || !result.token) {
    return null;
  }
  return { token: result.token, type: result.type ?? defaultTokenType() };
}

function defaultTokenType(): DeviceTokenType {
  return Platform.OS === 'ios' ? 'apns' : 'fcm';
}

export function registerForToken(): Promise<void> {
  return SinchPushNativeModule.registerForToken();
}

/**
 * The id that identifies this **install**: a lowercase canonical UUID
 * (`8-4-4-4-12`), generated on first use and then only read. It is stable for
 * the life of the install — not rotated by a token refresh, an identity change
 * or a socket restart — and is the value the relay receives in
 * `Hello.installation_id` and the push API in `Subscribe.installation_id`.
 *
 * @throws Rejects with `E_INSTALLATION_ID_UNAVAILABLE` when the id cannot be
 * produced right now, and with `E_UNAVAILABLE` on an iOS build without the
 * Swift socket target. If a stored ID cannot be read, reject without replacing
 * it. If creating or persisting a new ID fails, reject without returning or
 * caching the candidate. Retry when storage is available.
 *
 * ```ts
 * const installationId = await SinchPush.getInstallationId();
 * ```
 */
export async function getInstallationId(): Promise<string> {
  return SinchPushNativeModule.getInstallationId();
}

/**
 * The facts `Subscribe` and the socket's `Hello` both carry about this install:
 * installation id, platform, OS version, SDK version, bundle id and the Android
 * background-service state (`'UNSUPPORTED'` on iOS). The service state follows
 * the socket configuration and whether the foreground service is up, so it can
 * change while the app runs; the SDK re-subscribes when it does, and it is
 * `'RELAY_DISABLED'` while the relay is off.
 *
 * @throws Rejects like `getInstallationId` when the installation id cannot be
 * produced.
 */
export async function getDeviceInfo(): Promise<DeviceInfo> {
  return (await SinchPushNativeModule.getDeviceInfo()) as DeviceInfo;
}

/**
 * The relay switch (SB-66). The relay is **off by default**: nothing opens a
 * socket, posts a relay notification or starts the Android foreground service
 * until it is turned on here or with `initialize`'s `socket.enabled: true`
 * (on Android also the `SinchPush_relay=true` gradle property).
 *
 * `false` turns the relay channel off for this install: the socket is closed,
 * on Android the foreground service is stopped and its component disabled,
 * `startPushSocket` rejects with `E_RELAY_DISABLED`, and
 * `getDeviceInfo().backgroundService` becomes `'RELAY_DISABLED'`. FCM / APNs
 * delivery and cross-channel dedupe are unaffected.
 *
 * `true` turns it back on and starts no socket — call `startPushSocket` as
 * after any other stop. The value is persisted natively, so it survives
 * restarts and is the one `initialize`'s `socket.enabled` writes. An app that
 * enabled the relay before upgrading to 1.1.0 therefore stays on after the
 * upgrade, until it calls `setRelayEnabled(false)` (or passes
 * `socket.enabled: false`).
 *
 * On Android without the `SinchPush_relay=true` gradle property the relay is
 * not built in: `isRelayEnabled()` reads `false` even after
 * `setRelayEnabled(true)`.
 *
 * After the switch is applied the SDK re-subscribes **immediately** (not
 * debounced) when the device info changed: exactly one Subscribe if the value
 * changed, none if it did not. A failed Subscribe is logged, not thrown: the
 * switch itself is applied and the next start or device-info change retries.
 *
 * ```ts
 * await SinchPush.setRelayEnabled(false);
 * ```
 */
export async function setRelayEnabled(enabled: boolean): Promise<void> {
  if (typeof enabled !== 'boolean') {
    throw new Error('setRelayEnabled requires a boolean');
  }
  await runExclusive(async () => {
    await applyRelaySwitch(enabled);
    try {
      await resubscribeIfChanged();
    } catch (e) {
      // eslint-disable-next-line no-console
      console.warn('[sinch] re-subscribe after setRelayEnabled failed', e);
    }
  });
}

/**
 * Whether the relay is on for this install: the value `setRelayEnabled` or
 * `initialize`'s `socket.enabled` last persisted, `false` when nothing has ever
 * turned it on. On Android without `SinchPush_relay=true` it is always `false`.
 */
export async function isRelayEnabled(): Promise<boolean> {
  return SinchPushNativeModule.isRelayEnabled();
}

export function onPushReceiveHandler(
  handler: PushReceiveHandler
): Subscription {
  return subscribeToPush(handler);
}

export function onTokenReceiveHandler(
  handler: TokenReceiveHandler
): Subscription {
  return subscribeToToken(handler);
}

export { onInAppMessageHandler };

export {
  startPushSocket,
  stopPushSocket,
  getPushSocketState,
  sendPushSocketPoll,
  getPendingPushMessages,
  clearPendingPushMessages,
  displayNotification,
  reportPushMessageStatus,
  onSocketMessageHandler,
  onSocketStateHandler,
};

const SinchPush = {
  initialize,
  setIdentity,
  removeIdentity,
  setDeviceToken,
  getDeviceToken,
  registerForToken,
  getInstallationId,
  getDeviceInfo,
  setRelayEnabled,
  isRelayEnabled,
  onPushReceiveHandler,
  onTokenReceiveHandler,
  onInAppMessageHandler,
  startPushSocket,
  stopPushSocket,
  getPushSocketState,
  sendPushSocketPoll,
  getPendingPushMessages,
  clearPendingPushMessages,
  displayNotification,
  reportPushMessageStatus,
  onSocketMessageHandler,
  onSocketStateHandler,
};

export default SinchPush;

// --- internal --------------------------------------------------------------

function installTokenResendWatcher(): void {
  // Idempotent: replace any previous subscription so repeated initialize()
  // calls don't stack watchers.
  if (_tokenResendSub) {
    _tokenResendSub.remove();
    _tokenResendSub = null;
  }
  _tokenResendSub = subscribeToToken((deviceToken) => {
    void maybeResendDeviceToken(deviceToken.token, deviceToken.type);
  });
}

function installDeviceInfoWatcher(): void {
  if (_deviceInfoSub) {
    _deviceInfoSub.remove();
    _deviceInfoSub = null;
  }
  cancelPendingDeviceInfoCheck();
  // Only Android emits it (the foreground service changes the state).
  _deviceInfoSub =
    Platform.OS === 'android'
      ? subscribeToDeviceInfoChanged(scheduleDeviceInfoCheck)
      : null;
}

function installReportOutboxWatchers(): void {
  _reportQueuedSub?.remove();
  _appStateSub?.remove();
  _reportQueuedSub = subscribeToReportQueued(() => {
    // A push that queues while backgrounded is reported when the app is next active.
    if (AppState.currentState !== 'active') return;
    void _authDataSource?.currentAccessToken().then(
      (token) => {
        if (token) flushReportOutbox();
      },
      () => {},
    );
  });
  _appStateSub = AppState.addEventListener('change', (state) => {
    if (state === 'active') flushReportOutbox();
  });
}

// Subscribed at module load, not in `initialize`: iOS can launch the app in the
// background for a push, and the event may arrive before the host's JS has
// reached `initialize` (or before it can, e.g. behind a login gate).
subscribeToBackgroundWake((wakeId) => {
  void handleBackgroundWake(wakeId);
});

/** The flusher, once `initialize` has built it. */
function whenFlusherReady(): Promise<ReportOutboxFlusher> {
  if (_reportFlusher) return Promise.resolve(_reportFlusher);
  return new Promise((resolve) => {
    _flusherWaiters.push(resolve);
  });
}

/**
 * iOS woke the app for a push whose DELIVERED report it queued, and holds the
 * system completion handler until it hears back: flush the outbox once, then
 * say whether it got out. The whole of it - waiting for `initialize` when the
 * wake beat it, and the flush - is bounded by one deadline, which is shorter
 * than native's own 25 s. Never rejects.
 */
async function handleBackgroundWake(wakeId: string): Promise<void> {
  let sent = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<'timeout'>((resolve) => {
    timer = setTimeout(() => resolve('timeout'), BACKGROUND_WAKE_FLUSH_TIMEOUT_MS);
  });
  try {
    const flusher = await Promise.race([whenFlusherReady(), deadline]);
    if (flusher !== 'timeout') {
      await Promise.race([flusher.flush(), deadline]);
      // The flush never rejects and reports nothing itself: what it sent is gone
      // from the outbox, what it could not send is still in it. After a timeout
      // the flush is still running, so this reads the outbox as it is now.
      sent = (await SinchPushNativeModule.getReportOutbox()).length === 0;
    }
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[sinch] background wake flush failed', e);
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }
  try {
    await SinchPushNativeModule.completeBackgroundWake(wakeId, sent);
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[sinch] completing the background wake failed', e);
  }
}

function createReportFlusher(
  pushRepository: PushRepository,
  authDataSource: AuthDataSource,
): ReportOutboxFlusher {
  return new ReportOutboxFlusher({
    getOutbox: () => SinchPushNativeModule.getReportOutbox(),
    removeEntries: (entries) => SinchPushNativeModule.removeReportOutboxEntries(entries),
    reportEvents: (events, accessToken) => pushRepository.reportEvents(events, accessToken),
    currentToken: () => authDataSource.currentAccessToken(),
    now: () => Date.now(),
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    random: () => Math.random(),
  });
}

function reportOwnerOf(identity: SinchIdentity): string {
  return identity.kind === 'anonymous' ? 'anonymous' : identity.userId;
}

/** Fire-and-forget: the flusher logs what it cannot do and never rejects. */
function flushReportOutbox(): void {
  void _reportFlusher?.flush();
}

/**
 * iOS only. Tells native which App Group the Notification Service Extension
 * shares with the app. Never rejects.
 */
async function configureSharedReports(appGroup: string | undefined): Promise<void> {
  if (Platform.OS !== 'ios') return;
  try {
    await SinchPushNativeModule.configureSharedReports(appGroup || null);
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[sinch] configuring the shared report storage failed', e);
  }
}

/**
 * Mirrors the minimal report credential to native so the iOS extension, background
 * uploads and the Android messaging service can report with it while the app's JS is
 * not running; called whenever a JWT is stored. Without `token` the stored one is
 * mirrored, if any. Never rejects.
 *
 * The JWT is not renewed behind the host's back: once its `exp` has passed, native
 * uploads stop until the next `setIdentity` mints a new one (reports stay queued).
 */
async function mirrorSharedReportSession(
  token?: Parameters<typeof buildSharedReportRecord>[0],
): Promise<void> {
  if (!_config || !_authDataSource) return;
  try {
    await _sharedReportsConfigured;
    const auth = token ?? (await _authDataSource.currentAuthorization());
    if (!auth) return;
    await SinchPushNativeModule.setSharedReportSession(
      buildSharedReportRecord(auth, resolveRegion(_config).pushBaseUrl),
    );
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[sinch] mirroring the report credential failed', e);
  }
}

/** Removes the mirrored credential; never rejects. */
async function clearSharedReportSession(): Promise<void> {
  try {
    await _sharedReportsConfigured;
    await SinchPushNativeModule.setSharedReportSession(null);
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[sinch] clearing the report credential failed', e);
  }
}

/** Drops every queued report; a failure is logged, never thrown. */
async function clearReportOutbox(): Promise<void> {
  try {
    await SinchPushNativeModule.clearReportOutbox();
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[sinch] clearing the report outbox failed', e);
  }
}

function cancelPendingDeviceInfoCheck(): void {
  if (_deviceInfoTimer) {
    clearTimeout(_deviceInfoTimer);
    _deviceInfoTimer = null;
  }
}

/**
 * Trailing debounce: a burst of `onDeviceInfoChanged` collapses into one
 * check. The check goes through `runExclusive`, so it waits for a Subscribe in
 * flight and then compares against what that Subscribe recorded - a change
 * that landed mid-flight therefore costs exactly one more Subscribe, and none
 * otherwise.
 */
function scheduleDeviceInfoCheck(): void {
  cancelPendingDeviceInfoCheck();
  _deviceInfoTimer = setTimeout(() => {
    _deviceInfoTimer = null;
    runExclusive(() => resubscribeIfChanged()).catch((e) => {
      // eslint-disable-next-line no-console
      console.warn('[sinch] re-subscribe after device info change failed', e);
    });
  }, DEVICE_INFO_DEBOUNCE_MS);
}

/**
 * Runs `fn` after every earlier call has settled, so there is never more than
 * one Subscribe (or fingerprint write) in flight. A failure is returned to the
 * caller and does not poison the queue.
 */
function runExclusive<T>(fn: () => Promise<T>): Promise<T> {
  const result = _subscribeLock.then(fn);
  _subscribeLock = result.catch(() => {});
  return result;
}

/** Native device info, or `null` (logged) - it must never block a Subscribe. */
async function fetchDeviceInfo(): Promise<DeviceInfo | null> {
  try {
    const info = await SinchPushNativeModule.getDeviceInfo();
    if (isDeviceInfo(info)) return info;
    // eslint-disable-next-line no-console
    console.warn('[sinch] getDeviceInfo returned an unusable value; subscribing without device info');
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[sinch] getDeviceInfo failed; subscribing without device info', e);
  }
  return null;
}

/**
 * One Subscribe with whatever device info native can give right now, then the
 * fingerprint of what was sent. With `onlyIfChanged` it is skipped when the
 * fingerprint equals the one the last successful Subscribe recorded. Callers
 * hold the queue (`runExclusive`).
 */
async function subscribeWith(
  pushRepository: PushRepository,
  token: string,
  accessToken: string,
  onlyIfChanged = false,
): Promise<void> {
  if (!_config) return;
  const config = _config;
  const info = await fetchDeviceInfo();
  const fingerprint = subscribeFingerprint(token, config.configID, info);
  if (onlyIfChanged && (await readFingerprint()) === fingerprint) {
    return;
  }
  await pushRepository.sendDeviceToken(
    token,
    accessToken,
    config.configID,
    info ? toSubscribeDeviceInfo(info) : undefined,
  );
  await _deviceTokenStorage.writeLastSent(token);
  try {
    await _fingerprintStore.writeLastSubscribedFingerprint(fingerprint);
  } catch (e) {
    // The Subscribe succeeded; the worst a lost record costs is one more.
    // eslint-disable-next-line no-console
    console.warn('[sinch] recording the subscribe fingerprint failed', e);
  }
}

/** The recorded fingerprint, or `null` (logged) - an unreadable one reads as "changed". */
async function readFingerprint(): Promise<string | null> {
  try {
    return await _fingerprintStore.readLastSubscribedFingerprint();
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[sinch] reading the subscribe fingerprint failed; subscribing', e);
    return null;
  }
}

/**
 * Subscribes again if the token or any device fact differs from what the last
 * successful Subscribe carried. Needs an authenticated identity and a token;
 * with either missing there is nothing to subscribe on behalf of, and
 * `setIdentity` will. Callers hold the queue (`runExclusive`).
 */
async function resubscribeIfChanged(tokenOverride?: string): Promise<void> {
  if (!_config || !_pushRepository) return;
  const auth = _authDataSource ? await _authDataSource.currentAuthorization() : null;
  if (!auth) return;
  const token = tokenOverride ?? (await getDeviceToken())?.token;
  if (!token) return;
  await subscribeWith(_pushRepository, token, auth.accessToken, true);
}

async function maybeResendDeviceToken(
  token: string,
  type: DeviceTokenType,
): Promise<void> {
  if (type !== defaultTokenType()) return;
  try {
    await runExclusive(() => resubscribeIfChanged(token));
  } catch (e) {
    // Nothing is recorded on failure - we want to retry on the next token
    // event or next app start.
    // eslint-disable-next-line no-console
    console.warn('[sinch] auto resend device token failed', e);
  }
}
