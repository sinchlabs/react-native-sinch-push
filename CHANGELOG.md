# Changelog

All notable changes to `@sinch/react-native-sinch-push` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-10-30

### Added

- **Device-side `DELIVERED` reports.** Every Sinch push that reaches the device is reported through `SdkService.ReportEvents` (gRPC-web (Connect) over HTTPS), including from the background and from a killed app:
  - iOS: reports from the `content-available` background wake (uploaded by a background `URLSession`, with a JS fallback) and from the Notification Service Extension. Forward `application:handleEventsForBackgroundURLSession:completionHandler:` to `SinchPush`.
  - Android: the messaging service queues the report and uploads it natively with a mirrored session; JS flushes what is left on the next foreground.
  - Durable outbox, batches of 100, retry with backoff, 72 h TTL.
- **`SinchPushNotificationExtension` pod** (iOS): a React-free Notification Service Extension library, to be added to the extension target only. Configure it with `ios: { appGroup }` in `initialize`.
- **Android notification+data messages in background/killed state.** `SinchPushFirebaseMessagingService` overrides `handleIntent`, so a message that FCM displays itself is still recorded and reported.
- `getInstallationId()`: stable per-install UUID.
- `getDeviceInfo()`: installation id, platform, OS and SDK version, bundle id and background-service state, as sent with `Subscribe`.
- `setRelayEnabled(enabled)` / `isRelayEnabled()`: persisted relay switch.
- **Opt-in relay socket APIs**: `startPushSocket`, `stopPushSocket`, `getPushSocketState`, `getPendingPushMessages`, `clearPendingPushMessages`, `displayNotification`, `reportPushMessageStatus`, `onSocketMessageHandler`, `onSocketStateHandler`, `sendPushSocketPoll`.
- Config: `ios.appGroup`, `socket.enabled`, `socket.customWsUrl`, `socket.allowInsecureWs`. Display and polling options (`displayNotifications`, `pollIntervalMs`) are `startPushSocket` options.
- `Subscribe` now carries the install's device info and is re-sent when it changes.

### Changed

- **The relay is off by default.** It opens only with `socket.enabled: true` or `setRelayEnabled(true)`; on Android it also needs the gradle property `SinchPush_relay=true`. While off, `startPushSocket` rejects with `E_RELAY_DISABLED` and `getDeviceInfo().backgroundService` is `'RELAY_DISABLED'`. APNs/FCM delivery is unaffected.
- **Android manifest.** `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC` and the `dataSync` foreground service are merged only with `SinchPush_relay=true`. A default build declares no foreground service, so the Play Console foreground-service declaration does not apply.
- The library manifest declares `com.google.firebase.messaging.default_notification_channel_id = com.sinch.push.default`, and the SDK creates that channel, so notifications FCM displays in the background no longer land in "Miscellaneous". Override it with `tools:replace="android:value"`, or set the gradle property `SinchPush_defaultNotificationChannel=false` to omit the library's entry.
- The npm tarball no longer contains the Android unit tests (`android/src/test`).

### Notes

- **Most apps need no migration from 1.0.x** (two cases are listed under Migration below). The relay was never part of a published release, so its default being off is not a behaviour change for existing installs.
- iOS: add the `handleEventsForBackgroundURLSession` forward and the *Remote notifications* background mode to get background reports (see the README). Without them pushes are still received; reports for background pushes are sent on the next foreground.
- Android: Android delivers `MESSAGING_EVENT` to one service only, so if your app has its own `FirebaseMessagingService`, set `SinchPush_firebaseMessaging=none` (host `gradle.properties`, `rootProject.ext.SinchPush_firebaseMessaging` / `ext.firebaseMessaging`, or `-PSinchPush_firebaseMessaging=none`) and forward to `SinchPushEmitter` from your service (see the README); messages your service handles are not reported by the SDK.
- iOS, backend dependency: the Notification Service Extension runs only for APNs payloads with `mutable-content: 1`, which the released Sinch Push backend does not set yet. Until it does, a force-quit iOS app reports nothing until it is opened; background and killed (not force-quit) apps still report through the `content-available` wake, which Conversation API messages trigger.
- Android, known limitation: `@react-native-firebase/messaging` ships its own `FirebaseMessagingService`; with it there is no public SDK entry point yet that also queues `DELIVERED` reports, so those apps get no device-side delivery reports.
- Android: a push to a backgrounded or killed app is reported natively from the FCM service (one attempt of at most 8 s); a report that fails stays queued for the next push or the next foreground.
- Android: native report uploads pause once the mirrored JWT expires, until the next `setIdentity`. The mirrored JWT is kept in no-backup storage.
- Android: if you used the relay in a pre-release build, add `SinchPush_relay=true` to `android/gradle.properties` and `socket: { enabled: true }` to `initialize`.

### Migration

- **Hosts that declare their own `com.google.firebase.messaging.default_notification_channel_id`** in the app manifest: the library now declares it too, which fails the manifest merge. Set `SinchPush_defaultNotificationChannel=false` (default `true`) so the library omits its entry, or use `tools:replace="android:value"` on yours.
- **An app that enabled the relay in a pre-release build** (persisted) stays on after the upgrade until `initialize` is given `socket: { enabled: false }` or `setRelayEnabled(false)` is called. On Android without `SinchPush_relay=true`, `isRelayEnabled()` reads `false` even after `setRelayEnabled(true)`.

## [1.0.1] - 2026-08-24

### Added

- Android: reflection-based FCM detection, a library-owned `FirebaseMessagingService`, the `POST_NOTIFICATIONS` runtime request and foreground notification posting (`SinchPush_firebaseMessaging` = `optional` / `required` / `none`).
- iOS: `UNUserNotificationCenter` delegate that shows foreground pushes as banners.
- Automatic re-subscribe when the device token rotates and an identity exists.

### Changed

- Removed verbose request logging; improved demo screens in the example apps.

## [1.0.0] - 2026-08-12

### Added

- First public release as `@sinch/react-native-sinch-push`.
- `initialize`, `setIdentity`, `removeIdentity`, `setDeviceToken`, `getDeviceToken`, `registerForToken`, `onPushReceiveHandler`, `onTokenReceiveHandler`, `onInAppMessageHandler`.
- APNs (iOS) and FCM (Android) device-token capture; Connect-RPC `IssueTokenWithSignedUuid` and `Subscribe`.
- Old and new (TurboModule) architecture support; the iOS module is an Objective-C TurboModule.
