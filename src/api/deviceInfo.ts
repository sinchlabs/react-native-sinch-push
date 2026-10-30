// Device info as `Subscribe` carries it (SB-61).
//
// Native answers `getDeviceInfo()` with plain strings; the push API wants the
// `resources` enums, which are *not* the websocket ones (CONTRACT §2.2:
// resources.Platform IOS=3 / ANDROID=4, ws.Platform has different numbers).
// The mapping lives here, once, against the generated enums.

import {
  BackgroundServiceState,
  Platform as ResourcesPlatform,
} from '../generated/sinch/push/v1beta1/resources_pb';
import type { BackgroundServiceName, DeviceInfo } from '../types';

const PLATFORMS: Record<DeviceInfo['platform'], ResourcesPlatform> = {
  ios: ResourcesPlatform.IOS,
  android: ResourcesPlatform.ANDROID,
};

const BACKGROUND_SERVICES: Record<BackgroundServiceName, BackgroundServiceState> = {
  UNSUPPORTED: BackgroundServiceState.UNSUPPORTED,
  DISABLED: BackgroundServiceState.DISABLED,
  ENABLED_RUNNING: BackgroundServiceState.ENABLED_RUNNING,
  ENABLED_NOT_RUNNING: BackgroundServiceState.ENABLED_NOT_RUNNING,
  RELAY_DISABLED: BackgroundServiceState.RELAY_DISABLED,
};

/** The optional `SubscribeRequest` fields 5-10, in generated (camelCase) form. */
export interface SubscribeDeviceInfo {
  installationId?: string;
  platform?: ResourcesPlatform;
  osVersion?: string;
  sdkVersion?: string;
  bundleId?: string;
  backgroundService?: BackgroundServiceState;
}

/**
 * Maps native device info onto `SubscribeRequest` fields. A value that is empty
 * or not one of the known names is left out (the fields are all optional, and
 * "absent" is how the relay reads "unknown"), never sent as a zero value.
 */
export function toSubscribeDeviceInfo(info: DeviceInfo): SubscribeDeviceInfo {
  const out: SubscribeDeviceInfo = {};
  if (info.installationId) out.installationId = info.installationId;
  const platform = PLATFORMS[info.platform];
  if (platform !== undefined) out.platform = platform;
  if (info.osVersion) out.osVersion = info.osVersion;
  if (info.sdkVersion) out.sdkVersion = info.sdkVersion;
  if (info.bundleId) out.bundleId = info.bundleId;
  const service = BACKGROUND_SERVICES[info.backgroundService];
  if (service !== undefined) out.backgroundService = service;
  return out;
}

/** Whether `value` has the shape `getDeviceInfo()` promises. */
export function isDeviceInfo(value: unknown): value is DeviceInfo {
  if (value == null || typeof value !== 'object') return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.installationId === 'string' &&
    v.installationId !== '' &&
    (v.platform === 'ios' || v.platform === 'android') &&
    typeof v.osVersion === 'string' &&
    typeof v.sdkVersion === 'string' &&
    typeof v.bundleId === 'string' &&
    typeof v.backgroundService === 'string'
  );
}

/**
 * What the last successful Subscribe was made with, as one comparable string:
 * the token, the config id it was made for, the installation id, the SDK and OS
 * versions, the bundle id and the background-service state. `platform` is left
 * out - it cannot change for an install. `info` is `null` for a Subscribe made
 * without device info, so that the first start on which native does answer
 * counts as a change.
 */
export function subscribeFingerprint(
  token: string,
  configID: string,
  info: DeviceInfo | null,
): string {
  return JSON.stringify({
    token,
    configID,
    installationId: info?.installationId ?? null,
    sdkVersion: info?.sdkVersion ?? null,
    osVersion: info?.osVersion ?? null,
    bundleId: info?.bundleId ?? null,
    backgroundService: info?.backgroundService ?? null,
  });
}
