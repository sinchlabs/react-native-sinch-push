import './textEncoding';
import { NativeModules, Platform } from 'react-native';
import type { Spec } from './NativeSinchPush';
import {
  KeychainTokenStorage,
  accountKeyFor,
  DefaultAuthDataSource,
  DefaultAuthRepository,
  DefaultPushRepository,
  buildTransport,
  resolveRegion,
  setAuthToken,
  defaultDeviceTokenStorage,
} from './api';
import type {
  AuthDataSource,
  AuthRepository,
  DeviceTokenStorage,
  PushRepository,
  Transport,
} from './api';
import type { AppConfig, SinchIdentity } from './api/authRepository';
import { onInAppMessageHandler } from './api/inAppMessage';
import { subscribeToPush, subscribeToToken } from './api/eventBus';
import type {
  DeviceToken,
  DeviceTokenType,
  PushReceiveHandler,
  SinchPushConfig,
  SignedIdentity,
  Subscription,
  TokenReceiveHandler,
} from './types';

export type {
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

let _config: SinchPushConfig | null = null;
let _authTransport: Transport | null = null;
let _pushTransport: Transport | null = null;
let _authDataSource: AuthDataSource | null = null;
let _authRepository: AuthRepository | null = null;
let _pushRepository: PushRepository | null = null;
let _deviceTokenStorage: DeviceTokenStorage = defaultDeviceTokenStorage;
let _tokenResendSub: Subscription | null = null;

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
  if (options.deviceTokenStorage) {
    _deviceTokenStorage = options.deviceTokenStorage;
  }
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

  // Install the persistent token-event watcher BEFORE we trigger native token
  // capture so the very first emission (which may be the FCM token fetched
  // synchronously-enough after init) routes through the resend-on-change path.
  installTokenResendWatcher();

  _authDataSource
    .currentAccessToken()
    .then((t) => {
      if (t) {
        setAuthToken(t);
      }
    })
    .catch(() => {});

  const autoRegister = config.autoRegisterForToken !== false;
  if (autoRegister) {
    return SinchPushNativeModule.registerForToken().then(() => undefined);
  }
  return Promise.resolve();
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
  const token = await _authDataSource.generateToken(appConfig, identity);

  const dt = await getDeviceToken();
  if (dt?.token) {
    await _pushRepository.sendDeviceToken(dt.token, token.accessToken, appConfig.configID);
    await _deviceTokenStorage.writeLastSent(dt.token);
  }
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

  const dt = _deviceToken ?? (await getDeviceToken())?.token ?? null;
  const stored = await _authDataSource.currentAccessToken();
  if (dt && stored && _pushRepository) {
    try {
      await _pushRepository.unsubscribe(dt, stored, _config.configID);
    } catch {
    }
  }
  await _authDataSource.deleteToken();
  await _deviceTokenStorage.clearLastSent();
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

const SinchPush = {
  initialize,
  setIdentity,
  removeIdentity,
  setDeviceToken,
  getDeviceToken,
  registerForToken,
  onPushReceiveHandler,
  onTokenReceiveHandler,
  onInAppMessageHandler,
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

async function maybeResendDeviceToken(
  token: string,
  type: DeviceTokenType,
): Promise<void> {
  if (!_config || !_pushRepository) return;
  if (type !== defaultTokenType()) return;

  // We can only Subscribe on behalf of an authenticated identity. If the user
  // is not logged in, do nothing — setIdentity() will resend.
  const auth = _authDataSource ? await _authDataSource.currentAuthorization() : null;
  if (!auth) return;

  const lastSent = await _deviceTokenStorage.readLastSent();
  if (lastSent === token) return;

  try {
    await _pushRepository.sendDeviceToken(
      token,
      auth.accessToken,
      _config.configID,
    );
    await _deviceTokenStorage.writeLastSent(token);
  } catch (e) {
    // Don't persist the new token on failure — we want to retry on the next
    // token event or next app start.
    // eslint-disable-next-line no-console
    console.warn('[sinch] auto resend device token failed', e);
  }
}
