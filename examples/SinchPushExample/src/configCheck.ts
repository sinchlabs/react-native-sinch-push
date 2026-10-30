import {Platform} from 'react-native';
import {config} from './config';

const isSet = (v?: string) => !!v && !v.startsWith('YOUR_');

/** `group.com.example.*` is the placeholder shipped in `config.example.ts`. */
const isAppGroupSet = (v?: string) => isSet(v) && !(v ?? '').startsWith('group.com.example.');

/** True when the signing request goes to your backend, false for the on-device demo secret. */
export const usesBackendSigning = () => isSet(config.signedUserIdUrl);

/** The fields of `src/config.ts` that are still empty or placeholders. */
export function missingConfig(): string[] {
  const missing: string[] = [];
  if (!isSet(config.projectID)) {
    missing.push('projectID');
  }
  if (!isSet(config.clientID)) {
    missing.push('clientID');
  }
  const platform = Platform.OS === 'android' ? 'android' : 'ios';
  if (!isSet(config.configID?.[platform])) {
    missing.push(`configID.${platform}`);
  }
  if (config.env === 'custom') {
    if (!isSet(config.customPushApiUrl)) {
      missing.push('customPushApiUrl (required for env "custom")');
    }
    if (!isSet(config.customChatApiUrl)) {
      missing.push('customChatApiUrl (required for env "custom")');
    }
  }
  // iOS only: Android never reads iosAppGroup, so a placeholder must not block it.
  if (Platform.OS === 'ios' && !isAppGroupSet(config.iosAppGroup)) {
    missing.push('iosAppGroup');
  }
  if (!usesBackendSigning() && !isSet(config.demoOnlyIdentitySecret)) {
    missing.push('signedUserIdUrl (or, demo only, demoOnlyIdentitySecret)');
  }
  return missing;
}
