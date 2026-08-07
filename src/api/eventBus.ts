// Event bus for the native `SinchPush` bridge. Extracted from `src/index.tsx`
// so that `src/api/inAppMessage.ts` can subscribe without forming a circular
// import through `src/index.tsx` (which imports `onInAppMessageHandler`).
//
// The native side emits:
//   'SinchPush:onTokenReceived'  -> { token: string, type: 'apns' | 'fcm' }
//   'SinchPush:onPushReceived'   -> { data: Record<string, string>, source, title?, body?, identity? }

import { NativeEventEmitter, NativeModules, Platform } from 'react-native';
import type { Spec } from '../NativeSinchPush';
import type { DeviceToken, SinchPushMessage, Subscription } from '../types';

const LINKING_ERROR =
  `The package 'react-native-sinch-push' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

const isTurboModuleEnabled = (global as any).__turboModuleProxy != null;

const resolvedModule: Spec | undefined = isTurboModuleEnabled
  ? require('../NativeSinchPush').default
  : NativeModules.SinchPush;

if (resolvedModule == null) {
  throw new Error(LINKING_ERROR);
}

const SinchPushNativeModule: Spec = resolvedModule;

export const EVENT_PUSH_RECEIVED = 'SinchPush:onPushReceived';
export const EVENT_TOKEN_RECEIVED = 'SinchPush:onTokenReceived';

const emitter = new NativeEventEmitter(
  SinchPushNativeModule as unknown as ConstructorParameters<typeof NativeEventEmitter>[0],
);

const defaultTokenType = (): DeviceToken['type'] =>
  Platform.OS === 'ios' ? 'apns' : 'fcm';

function normalizeMessage(message: any): SinchPushMessage {
  return {
    ...message,
    data: message.data ?? {},
    source: message.source ?? defaultTokenType(),
  };
}

export function subscribeToPush(handler: (m: SinchPushMessage) => void): Subscription {
  const sub = emitter.addListener(EVENT_PUSH_RECEIVED, (m: any) => handler(normalizeMessage(m)));
  return { remove: () => sub.remove() };
}

export function subscribeToToken(handler: (t: DeviceToken) => void): Subscription {
  const sub = emitter.addListener(EVENT_TOKEN_RECEIVED, (t: DeviceToken) => handler(t));
  return { remove: () => sub.remove() };
}
