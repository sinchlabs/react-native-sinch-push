// Copy this file to `src/config.ts` (git-ignored) and fill in the values:
//
//   cp src/config.example.ts src/config.ts
//
// `npm install` / `npm start` / `npm run ios|android` do the copy for you when
// `src/config.ts` is missing, so the app always compiles; until the
// placeholders below are replaced the app shows a "Configuration missing" screen.
import type {ExampleConfig} from './configTypes';

export const config: ExampleConfig = {
  // Sinch Build dashboard (https://dashboard.sinch.com) → "Sinch Push" in the
  // sidebar. Create a project and a client there; the page lists the ids.
  projectID: 'YOUR_PROJECT_ID',
  clientID: 'YOUR_CLIENT_ID',

  // One push config per platform, created under the same page:
  //  - iOS:     upload your APNs auth key (.p8) with its Key ID and Team ID;
  //             the bundle id is APP_BUNDLE_ID from ios/Config.xcconfig.
  //  - Android: upload the Firebase service-account JSON (Firebase console →
  //             Project settings → Service accounts → Generate new private key);
  //             the package name is `sinchExample.applicationId` in
  //             android/gradle.properties.
  configID: {
    ios: 'YOUR_IOS_CONFIG_ID',
    android: 'YOUR_ANDROID_CONFIG_ID',
  },

  // 'eu1' | 'us1' | 'custom'. 'custom' also needs the two URLs below (ask Sinch
  // for them); they are ignored for eu1 / us1.
  env: 'eu1',
  // customPushApiUrl: 'https://…',
  // customChatApiUrl: 'https://…',

  // Must be the same as APP_GROUP in ios/Config.xcconfig (shared by the app and
  // the NotificationService extension). iOS only.
  iosAppGroup: 'group.com.example.sinchpush',

  // --- Identity signing -----------------------------------------------------
  // setIdentity needs a signed user id: hex(HMAC-SHA512(userId, secret)), where
  // the secret is the client secret of your Sinch Push client. Sign on YOUR
  // backend and have the app fetch the result:
  //
  //   POST <signedUserIdUrl>
  //   Content-Type: application/json
  //   {"userId": "<user id>"}
  //   → 200 {"signedUserId": "<hex HMAC-SHA512>"}
  //
  // signedUserIdUrl: 'https://your-backend.example.com/sinch/sign',

  // DEMO ONLY - NEVER SHIP THE SECRET IN AN APP. Anyone who unpacks the app can
  // impersonate every user. Used only when signedUserIdUrl is not set; the app
  // shows a warning banner while it is in use.
  // demoOnlyIdentitySecret: 'YOUR_CLIENT_SECRET',

  enableLogging: false,
};
