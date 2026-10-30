import type {SinchPushConfig} from '@sinch/react-native-sinch-push';

/** Everything the example reads from `src/config.ts`. See `src/config.example.ts`. */
export interface ExampleConfig {
  /** Sinch Build dashboard → "Sinch Push": project id. */
  projectID: string;
  /** Sinch Build dashboard → "Sinch Push": client id. */
  clientID: string;
  /** One config per platform: the iOS one holds the APNs key, the Android one the FCM credentials. */
  configID: {ios: string; android: string};
  /** `eu1` / `us1` are the Sinch regions; `custom` needs the two URLs below. */
  env: SinchPushConfig['env'];
  customPushApiUrl?: string;
  customChatApiUrl?: string;
  /** iOS App Group; must equal `APP_GROUP` in `ios/Config.xcconfig`. */
  iosAppGroup: string;
  /** Your backend: POST {userId} → {signedUserId}. The recommended way to sign. */
  signedUserIdUrl?: string;
  /** DEMO ONLY: signs on the device. Never ship the secret in an app. */
  demoOnlyIdentitySecret?: string;
  enableLogging?: boolean;
}
