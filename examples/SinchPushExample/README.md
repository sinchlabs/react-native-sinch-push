# Sinch Push example (React Native 0.76, New Architecture)

A small app for `@sinch/react-native-sinch-push`: set an identity, register for a push token, receive pushes
and see what was received. The Sinch Push relay (socket) is **off**; pushes come through APNs (iOS) and FCM
(Android).

The UI follows the native Sinch iOS DemoApp. The start screen has three cards, one per step: **Config → Identity →
Push token**. Below them a **PUSH LOG** badge (SDK state plus message and event counts) opens the **Message log**
screen with the received messages and the delivery-event log; **Clear** on that screen empties both lists and
**‹ Back** (or the Android back button) returns to the start screen. If `src/config.ts` still holds placeholders
the app shows a "Configuration missing" screen that lists the fields to fill in.

The SDK is consumed from the repo root (`"@sinch/react-native-sinch-push": "file:../.."`, autolinked; Metro
watches the repo root, see `metro.config.js`).

## Prerequisites

- Node 18+, Xcode 16+ with CocoaPods (iOS), Android Studio / JDK 17 (Android).
- A Sinch account with a **Sinch Push** project: Sinch Build dashboard → **Sinch Push** in the sidebar. There
  you create a client and one push config per platform, and find the project, client and config ids:
  - iOS config: upload your APNs auth key (`.p8`) with its Key ID and Team ID, and the app's bundle id.
  - Android config: upload the Firebase service-account JSON (Firebase console → Project settings → Service
    accounts → Generate new private key).
- iOS: an Apple Developer account (push needs a real device and a team; the simulator can build but gets no
  APNs token), the app id + `…NotificationService` app id with Push Notifications, and an App Group enabled for
  both.
- Android: a Firebase project with an Android app whose package name matches `sinchExample.applicationId`.

## Setup

1. **Install and create the local config files.** The SDK's generated protobuf code is committed to the
   repository, so there is no generation step (regenerating it needs Sinch's internal proto sources and is not
   part of running the example). From the repo root run `npm install`, then:

   ```sh
   cd examples/SinchPushExample
   npm install --legacy-peer-deps
   ```

   `postinstall` (and `npm start` / `npm run ios|android`) copy the examples below when the target is missing,
   and never overwrite an existing file. To do it by hand: `npm run setup`.

   | Example (committed)           | Local copy (git-ignored) |
   | ----------------------------- | ------------------------ |
   | `src/config.example.ts`       | `src/config.ts`          |
   | `ios/Config.example.xcconfig` | `ios/Config.xcconfig`    |

2. **Fill in `src/config.ts`**: `projectID`, `clientID`, `configID.ios` / `configID.android`, `env`
   (`eu1` / `us1` / `custom`; `custom` also needs `customPushApiUrl` and `customChatApiUrl`), `iosAppGroup` (iOS only; the
   `group.com.example.*` placeholder is flagged on the "Configuration missing" screen on iOS), and
   how identities are signed:

   - **Recommended: `signedUserIdUrl`**, an endpoint on your backend that signs with the client secret of
     your Sinch Push client:

     ```text
     POST <signedUserIdUrl>
     {"userId": "<user id>"}
     → 200 {"signedUserId": "<hex HMAC-SHA512(userId, secret)>"}
     ```

   - **Demo only: `demoOnlyIdentitySecret`.** Signs on the device when `signedUserIdUrl` is not set. **Never ship
     the secret in an app**: anyone can extract it and impersonate any user. The app shows a warning banner
     while this is in use.

3. **iOS: fill in `ios/Config.xcconfig`**: `DEVELOPMENT_TEAM`, `APP_BUNDLE_ID` (the extension becomes
   `$(APP_BUNDLE_ID).NotificationService`) and `APP_GROUP`. `APP_GROUP` must equal `iosAppGroup` in
   `src/config.ts`. It reaches the entitlements of both targets and `Info.plist` (`SinchAppGroup`), which the
   Notification Service Extension reads. The Xcode project loads this file at project level, so `pod install`
   does not undo it.

4. **Firebase / APNs files.**
   - Android: put `google-services.json` for your package into `android/app/` (git-ignored). Set the package in
     `android/gradle.properties` (`sinchExample.applicationId`, default `com.example.sinchpush`). Without the
     file the app builds with a Gradle warning, but there is no FCM token.
   - iOS: the APNs key lives in the Sinch dashboard (step "Prerequisites"); nothing to add to the app. Xcode
     signs it with the team above.

5. **Install pods and run.**

   ```sh
   cd ios && pod install && cd ..   # Xcode 16.3+/27: the Podfile patches fmt and the pod deployment targets
   npm start
   npm run ios        # or open ios/Bare076.xcworkspace and run on a device
   npm run android
   ```

   (The Xcode project, the `Bare076` scheme and the `com.bare076` Kotlin namespace keep their template names;
   they are not user-visible.)

## Using the app

**Notification permission.** The SDK itself requests the Android 13+ `POST_NOTIFICATIONS` permission when the
module loads and again from `registerForToken`, so on Android the prompt can appear at launch, before you press
anything. The example passes `autoRegisterForToken: false`, so the iOS prompt waits for the button on the Push token card.

1. Config and Identity cards: the user id is a random UUID kept in the Keychain/Keystore; edit it if you want a fixed one.
   **Set identity** signs it and calls `setIdentity`.
2. Push token card: **Request permission & register** asks for the notification permission (Android 13+ runtime
   permission, iOS prompt), calls `registerForToken` and shows the token. **Copy / share token** opens the share
   sheet.
3. Message log screen (tap the PUSH LOG badge), received messages: pushes delivered to JS (`onPushReceiveHandler`) with channel, event, time, title, body and message
   id. Newest first, in memory only (no storage dependency), so the list is gone after the app restarts.
4. Message log screen, delivery-event log: local events (initialize, setIdentity, token, foreground receive, app state changes). The SDK has
   no public JS event for report outcomes, so DELIVERED reports for background and killed pushes are not
   shown here; they are sent natively (see below).

## Send a test push

`scripts/send-test-push.mjs` posts a text message to the Conversation API
(`https://{region}.conversation.api.sinch.com/v1/projects/{projectId}/messages:send`) addressed to the
`SINCH_PUSH` channel identity of your user id.

```sh
cp .env.example .env      # git-ignored; region, project id, app id, access key id + secret (or access token)
npm run send-test-push -- <userId> "Hello"          # userId = the one shown in the app
npm run send-test-push -- <userId> "Hello" --dry-run   # prints the request, sends nothing
```

The Conversation API app (`SINCH_APP_ID`) must have the **Sinch Push channel enabled** (contact Sinch or check the
dashboard); otherwise the call fails with 400/403. `SINCH_KEY_ID` / `SINCH_KEY_SECRET` are an access key of your Sinch
project (Build dashboard → Access keys); the script exchanges them for an OAuth2 token
(`POST https://auth.sinch.com/oauth2/token`, client credentials) and sends it as a Bearer token. Alternatively set
`SINCH_ACCESS_TOKEN` to use a token you already have. These credentials are not the Sinch Push client secret and stay
out of the app.

## Testing foreground, background and killed delivery

Register a token (Push token card) first, then send a push for your user id with the script above.

| State | iOS | Android |
| ----- | --- | ------- |
| **Foreground** | The banner shows and a row appears in "Received messages" and the event log. | Same: `onPushReceiveHandler` fires and the row appears. |
| **Background** | The app is suspended; the Notification Service Extension hands the push to the SDK, which reports DELIVERED from the extension process (and from the background wake for `content-available` pushes). Tap the notification to bring the app forward. | The SDK's `FirebaseMessagingService` shows the notification and reports DELIVERED. |
| **Killed** | Swipe the app away, send a push: the extension still runs and reports. A force-quit app is not relaunched by a `content-available` push; one the system terminated may be. | The same service runs without the app. |

Background and killed deliveries do not reach the JS lists, because the app's JS is not running. To confirm they
were reported, look at the dashboard, or check the logs: Xcode → Debug → Attach to Process → `NotificationService`
(console lines starting with `[NSE]`), and `adb logcat | grep -i sinch` on Android. Test iOS on a physical device; the
simulator does not receive APNs pushes.

## Troubleshooting

- **"Configuration missing"**: edit `src/config.ts` (it lists the fields); Metro reloads on save.
- **`Cannot find module './config'`**: run `npm run setup` (the copy did not run, e.g. `npm install --ignore-scripts`).
- **No iOS token**: use a real device with a team set in `ios/Config.xcconfig`; the app id must have Push
  Notifications and the Sinch iOS config must hold a valid APNs key for that bundle id (and environment).
- **Signing for "Bare076" requires a development team**: set `DEVELOPMENT_TEAM` in `ios/Config.xcconfig`.
- **App Group errors / no report from the extension**: `APP_GROUP` (xcconfig) and `iosAppGroup` (config.ts) have to be
  identical, and the group has to be enabled for both app ids.
- **No Android token**: add `android/app/google-services.json` for the package in `sinchExample.applicationId`;
  on Android 13+ accept the notification permission.
- **`setIdentity` fails**: check the project / client / config ids and the signature. With `signedUserIdUrl`
  the endpoint must answer `{"signedUserId": "…"}`; with the demo secret it must be the client secret.
- **`send-test-push` answers 401/403**: the key or token is not for `SINCH_PROJECT_ID`, or the region is wrong. **400/403 with a valid key**: the Conversation API app does not have the Sinch Push channel enabled.
- **`npm install` peer-dependency errors**: use `--legacy-peer-deps`.
