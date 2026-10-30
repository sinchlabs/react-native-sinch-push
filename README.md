# @sinch/react-native-sinch-push

React Native SDK for **Sinch Push**: register a user identity, capture the APNs (iOS) or FCM (Android) device token, receive pushes in JavaScript, and report each delivery back to Sinch. Supports the old (bridge) and new (TurboModule) architectures.

## Contents

- [Features](#features) · [Install](#install) · [Dashboard setup](#dashboard-setup)
- [iOS setup](#ios-setup) · [Android setup](#android-setup)
- [Quick start](#quick-start) · [Identity signing](#identity-signing)
- [Delivery events](#delivery-events) · [API reference](#api-reference)
- [Advanced: the relay](#advanced-the-relay-persistent-websocket) · [Running the example](#running-the-example)
- [Troubleshooting](#troubleshooting) · [Development](#development) · [License](#license)

## Features

- **Identity registration**: `setIdentity` exchanges your backend-signed user id for a JWT (`IssueTokenWithSignedUuid`) and subscribes the device token (`Subscribe`); `removeIdentity` unsubscribes.
- **Token capture**: APNs token on iOS, FCM token on Android, refreshed automatically; the SDK re-subscribes when the token or device info changes.
- **Push receive handling**: foreground, background and killed state, with a notification shown on both platforms.
- **Delivery reports from the device**: each push is reported as `DELIVERED` through `SdkService.ReportEvents` (gRPC-web (Connect) over HTTPS), including from the background and from a killed app (iOS wake and Notification Service Extension, Android messaging service). See [Delivery events](#delivery-events).
- **Notification Service Extension (iOS)**: an optional, React-free pod that reports a push from the extension process.
- **In-app messages**: pushes carrying a `protobufPayload` are decoded into typed messages (`onInAppMessageHandler`).
- **Optional relay**: a persistent WebSocket delivery channel, **off by default** ([Advanced](#advanced-the-relay-persistent-websocket)).

## Install

```sh
npm install @sinch/react-native-sinch-push react-native-keychain
# or
yarn add @sinch/react-native-sinch-push react-native-keychain
cd ios && pod install
```

| | Requirement |
| --- | --- |
| React Native | peer range `*`. Developed against 0.74; the example app runs 0.76 with the New Architecture. Autolinking (0.60+). Not usable in Expo Go. |
| `react-native-keychain` | `^9.0.0` (peer). Stores the JWT in the iOS Keychain / Android Keystore. |
| iOS | 13.0+ (both pods), Swift 5. |
| Android | `minSdk` 21 by default (your `rootProject.ext.minSdkVersion` wins), compile/target SDK 34 by default, Java 17, Kotlin 1.9+. |

## Dashboard setup

In the **Sinch Build dashboard** ([dashboard.sinch.com](https://dashboard.sinch.com)) open **Sinch Push** in the sidebar, create a project and a client, then add one push config per platform:

- **iOS (APNs)**: token-based auth. Upload the `.p8` key and enter its **Key ID**, your **Team ID** and the app's **Bundle ID**. Sandbox and production are separate configs: create both if you ship debug builds and TestFlight/App Store builds.
- **Android (FCM)**: upload the Firebase **HTTP v1 service-account JSON** (Firebase console → Project settings → Service accounts → Generate new private key). The legacy FCM server key is not supported.

The dashboard shows the **`projectID`**, **`clientID`** and a **`configID`** per config; they go into `initialize`. The client also has a **secret**, used only on your backend to [sign identities](#identity-signing).

Invalid APNs/FCM tokens are deleted server-side, so a token that no longer works needs no cleanup in the app.

## iOS setup

### 1. Capabilities

In Xcode, on the app target:

- **Push Notifications**
- **Background Modes → Remote notifications** (needed for [background wake](#delivery-events))
- **App Groups**, only if you add the [Notification Service Extension](#notification-service-extension-optional-recommended)

### 2. AppDelegate forwards

React Native does not own your `UIApplicationDelegate`; forward these callbacks to the SDK. The SDK calls the fetch and background-session completion handlers itself.

**Swift** (`AppDelegate.swift`):

```swift
import react_native_sinch_push   // or `#import <SinchPush.h>` in the bridging header

func application(_ application: UIApplication,
                 didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
  SinchPush.didRegisterForRemoteNotifications(withDeviceToken: deviceToken)
}

func application(_ application: UIApplication,
                 didFailToRegisterForRemoteNotificationsWithError error: Error) {
  SinchPush.didFailToRegisterForRemoteNotificationsWithError(error)
}

func application(_ application: UIApplication,
                 didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                 fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
  // The SDK calls completionHandler exactly once; do not call it yourself.
  SinchPush.didReceiveRemoteNotification(userInfo, fetchCompletionHandler: completionHandler)
}

func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
  // Returns false for sessions that are not the SDK's: handle yours, or finish.
  if !SinchPush.handleEvents(forBackgroundURLSession: identifier, completionHandler: completionHandler) {
    completionHandler()
  }
}
```

**Objective-C** (`AppDelegate.mm`):

```objc
#import <SinchPush.h>

- (void)application:(UIApplication *)application
    didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
  [SinchPush didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
}

- (void)application:(UIApplication *)application
    didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
  [SinchPush didFailToRegisterForRemoteNotificationsWithError:error];
}

- (void)application:(UIApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
          fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
  [SinchPush didReceiveRemoteNotification:userInfo fetchCompletionHandler:completionHandler];
}

- (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(NSString *)identifier
                      completionHandler:(void (^)(void))completionHandler {
  if (![SinchPush handleEventsForBackgroundURLSession:identifier
                                    completionHandler:completionHandler]) {
    completionHandler();
  }
}
```

`+didReceiveRemoteNotification:` (without the handler) also exists, but then the app is not kept awake for the delivery report.

**Notification center.** The module installs itself as the `UNUserNotificationCenter` delegate when it loads, shows foreground pushes as banner + list + sound, and **chains the previous delegate**: whatever delegate your app set earlier still gets its callbacks. If you assign `UNUserNotificationCenter.current().delegate` yourself *after* the SDK loaded, you replace the SDK's delegate: set yours in `didFinishLaunching` before React Native starts so the SDK chains to it.

`registerForToken()` (called by `initialize` unless `autoRegisterForToken: false`) asks for notification authorization (alert, badge, sound) and registers for remote notifications.

### Notification Service Extension (optional, recommended)

An NSE runs for every **alert** push with `mutable-content: 1`, including when the app was **force-quit**, and lets the SDK report `DELIVERED` from the extension process. Without it, a force-quit app reports nothing until the user opens it again.

> **Backend requirement.** The NSE runs only when the APNs payload carries `mutable-content: 1`. The released Sinch Push backend does not set it yet (it is on an unreleased backend change), so until that ships the extension is installed but never invoked. See [Backend requirements](#backend-requirements).

1. **Add the target**: Xcode → File → New → Target → *Notification Service Extension*, named `NotificationService` (Swift). Match the app's deployment target; its bundle id must be prefixed by the app's (`com.example.app.NotificationService`) and its version numbers must equal the app's.
2. **Add the pod to the extension target only** (the main pod already contains the shared code):

   ```ruby
   target 'NotificationService' do
     pod 'SinchPushNotificationExtension', :path => '../node_modules/@sinch/react-native-sinch-push'
   end
   ```

   Then `pod install`.
3. **App Group**: create one in the Apple Developer portal (e.g. `group.com.example.app`) and enable the **App Groups** capability with it on **both** the app and the extension target (and in both provisioning profiles).
4. **Tell the SDK the group**:

   ```ts
   await SinchPush.initialize({ /* … */ ios: { appGroup: 'group.com.example.app' } });
   ```

   With `ios.appGroup` set, native mirrors a minimal report credential (`{ accessToken, reportBaseURL, userId, appId }`, never the signing secret) into the group container whenever `setIdentity` stores a JWT, and clears it on `removeIdentity`.
5. **`NotificationService.swift`**:

   ```swift
   import SinchPushNotificationExtension
   import UserNotifications

   class NotificationService: UNNotificationServiceExtension {
     private var contentHandler: ((UNNotificationContent) -> Void)?
     private var bestAttemptContent: UNMutableNotificationContent?

     override func didReceive(_ request: UNNotificationRequest,
                              withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
       self.contentHandler = contentHandler
       bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

       // Queues the DELIVERED report and hands it to a background URLSession, then returns.
       // false: not a Sinch push, or nothing could be uploaded (the app retries later).
       SinchPushNotificationExtension.didReceive(request, appGroup: "group.com.example.app")

       if let content = bestAttemptContent { contentHandler(content) }
     }

     override func serviceExtensionTimeWillExpire() {
       if let contentHandler, let content = bestAttemptContent { contentHandler(content) }
     }
   }
   ```

   The call never alters the notification.
6. **Forward `handleEventsForBackgroundURLSession`** in the AppDelegate (above). A force-quit app is not relaunched for it; the SDK collects the result on the next launch.
7. **The server must send `mutable-content: 1`**. The released Sinch Push backend does not set it yet; see [Backend requirements](#backend-requirements). The payload also carries `sinch.push.message_id` and `sinch.push.subscriber_id`; the extension reports only pushes that have both.

Silent pushes (no `alert`) do not start the extension; they rely on `content-available`.

## Android setup

### 1. Firebase

Place `google-services.json` in `android/app/` and apply the Google Services plugin (a library cannot do either for you):

```gradle
// android/build.gradle
buildscript { dependencies { classpath 'com.google.gms:google-services:4.4.2' } }

// android/app/build.gradle
apply plugin: 'com.google.gms.google-services'
```

Autolinking registers the native package; no `MainApplication` change is needed.

### 2. FCM integration mode

The library ships a `FirebaseMessagingService` (`SinchPushFirebaseMessagingService`). The mode is `SinchPush_firebaseMessaging`:

| Value | `firebase-messaging` dependency | Service |
| --- | --- | --- |
| `optional` (default) | `compileOnly`: uses the copy your app already has | registered; a no-op if your app has no FCM |
| `required` | `implementation`: the library brings it (version `SinchPush_firebaseMessagingVersion`, default 24.1.0) | registered |
| `none` | none | disabled and not compiled; you obtain the token yourself ([below](#already-have-a-firebasemessagingservice)) |

Every `SinchPush_*` setting in this section and below can be set from the host's `gradle.properties`, as `rootProject.ext.SinchPush_x` (or the unprefixed `rootProject.ext.x`), or with `-P` on the command line; the library's own defaults apply otherwise. Any of these works:

```properties
# android/gradle.properties
SinchPush_firebaseMessaging=none     # or 'required'
```

```gradle
// android/build.gradle
ext { SinchPush_firebaseMessaging = 'none' }   // or the unprefixed: ext { firebaseMessaging = 'none' }
```

or `./gradlew … -PSinchPush_firebaseMessaging=none`.

### 3. What the SDK service does

- **Data-only and notification+data payloads.** `onMessageReceived` handles data messages and foreground messages: dedupes by `sinch.push.message_id`, emits `onPushReceiveHandler` to JS, and posts a notification (title/body from the FCM `notification`, else the `title`/`body`/`text`/`message` data keys).
- **Background and killed state.** FCM displays `notification`+`data` messages itself and does **not** call `onMessageReceived`. The service overrides `handleIntent`, which sees every message first, so it still queues the `DELIVERED` report and uploads it natively (see [Delivery events](#delivery-events)).
- **Token.** The FCM token is captured and refreshed (`onNewToken`) and emitted to `onTokenReceiveHandler`.

### 4. Notification permission and channel

- Android 13+ (API 33) needs the **`POST_NOTIFICATIONS`** runtime permission, which the library declares in its manifest. The SDK requests it when the module loads and again on `registerForToken()` (when an activity is attached). Request it yourself at a better moment if you prefer (`PermissionsAndroid.request('android.permission.POST_NOTIFICATIONS')`). Without it nothing is displayed.
- The default channel is **`com.sinch.push.default`** ("Default", importance default), created by the SDK. The library's manifest declares
  `com.google.firebase.messaging.default_notification_channel_id = com.sinch.push.default` so notifications FCM displays itself while the app is backgrounded use it instead of FCM's "Miscellaneous" channel. To use your own channel, either declare the same `<meta-data>` in your app manifest with `tools:replace`:

  ```xml
  <manifest xmlns:android="http://schemas.android.com/apk/res/android"
            xmlns:tools="http://schemas.android.com/tools">
    <application>
      <meta-data
          android:name="com.google.firebase.messaging.default_notification_channel_id"
          android:value="my_channel"
          tools:replace="android:value" />
    </application>
  </manifest>
  ```

  or, if your app manifest declares that `<meta-data>` itself, set the gradle property `SinchPush_defaultNotificationChannel=false` (default `true`). The library then omits its own entry, so there is nothing to merge or replace.

### Already have a FirebaseMessagingService?

Android delivers `com.google.firebase.MESSAGING_EVENT` to **one** service only. If your app and the SDK both declare a `FirebaseMessagingService`, whichever the system resolves first receives every message and the other never runs, so either your code or the SDK's (token capture, notifications, `DELIVERED` reports) silently stops working. Do not run two.

Set `SinchPush_firebaseMessaging=none` (see [FCM integration mode](#2-fcm-integration-mode); the SDK's service is then disabled and not compiled) and forward from yours:

```kotlin
class MyMessagingService : FirebaseMessagingService() {
  override fun onNewToken(token: String) {
    SinchPushEmitter.onNewToken(token)                     // com.sinchpush.SinchPushEmitter
  }
  override fun onMessageReceived(message: RemoteMessage) {
    SinchPushEmitter.onMessage(message.data, message.notification?.title, message.notification?.body)
  }
}
```

`SinchPushEmitter.onMessage` hands the push to `onPushReceiveHandler` in JS only. With `none` the SDK does not request `POST_NOTIFICATIONS`, does not create the channel and does not show a notification for you (show it yourself, or call `SinchPush.displayNotification` from JS). It does not call FCM for the token either: fetch it (`FirebaseMessaging.getInstance().token`) and pass it to `SinchPushEmitter.onNewToken`, or call `SinchPush.setDeviceToken(token)` from JS. It also **does not queue `DELIVERED` reports or dedupe** messages your service handles: only pushes handled by the SDK's own service are reported. More limits of this mode:

- `onMessage` only reaches JS while a React context is attached; in background or killed state the push is dropped, not buffered (tokens are buffered and replayed).
- Background notification+data messages never reach your `onMessageReceived` (Android displays them itself), so the SDK sees nothing for them.
- The library's `default_notification_channel_id` meta-data is not merged, so FCM-displayed notifications land in the "Miscellaneous" channel unless you declare a channel.
- From Java call `SinchPushEmitter.INSTANCE.onNewToken(token, "fcm")`.

**Known limitation: `@react-native-firebase/messaging`.** RNFirebase ships its own `FirebaseMessagingService`, so it conflicts with the SDK's service and there is no public SDK entry point yet for forwarding from it that also queues `DELIVERED` reports. Apps using RNFirebase messaging get token and foreground handling through forwarding only, without device-side delivery reports.

## Quick start

```ts
import { Platform } from 'react-native';
import SinchPush from '@sinch/react-native-sinch-push';

// Call at app start, outside any screen or login gate: iOS may launch the app in the
// background for a push, and reports can only be flushed once initialize has run.
await SinchPush.initialize({
  projectID: 'YOUR_PROJECT_ID',
  clientID: 'YOUR_CLIENT_ID',
  configID: Platform.OS === 'ios' ? 'YOUR_IOS_CONFIG_ID' : 'YOUR_ANDROID_CONFIG_ID',
  env: 'eu1', // 'eu1' | 'us1' | 'custom'
  ios: { appGroup: 'group.com.example.app' }, // only with the Notification Service Extension
});

const tokenSub = SinchPush.onTokenReceiveHandler((t) => console.log(t.type, t.token));
const pushSub = SinchPush.onPushReceiveHandler((m) => console.log(m.title, m.body, m.data));
const inAppSub = SinchPush.onInAppMessageHandler((msg) => {
  if (msg.kind === 'text') console.log(msg.text); // also: media, location, choice, card, carousel
});

// After login. signedUserID comes from YOUR backend (next section).
await SinchPush.setIdentity({ userID: 'user-1234', signedUserID });

// On logout:
await SinchPush.removeIdentity({ userID: 'user-1234', signedUserID });
tokenSub.remove(); pushSub.remove(); inAppSub.remove();
```

`setIdentity` mints the JWT, stores it in the Keychain/Keystore and subscribes the current device token. If the token or device info changes later, the SDK re-subscribes on its own. Use a separate `configID` per platform (each dashboard config is for one provider).

## Identity signing

`signedUserID` is the **hex-encoded HMAC-SHA512 of `userID`, keyed with your Sinch Push client secret**. It is not a bearer token: the SDK sends it to `IssueTokenWithSignedUuid` and receives the JWT it uses for `Subscribe`, `Unsubscribe` and `ReportEvents`.

> **Sign on your backend. Never put the secret in the app.** Anyone who unpacks the app can extract it and impersonate every user. The example app has a demo-only on-device option, labelled as such; do not copy it.

**Node.js**

```ts
import { createHmac } from 'crypto';

export const signUserID = (userID: string, secret: string) =>
  createHmac('sha512', secret).update(userID).digest('hex');
```

**Kotlin**

```kotlin
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

fun signUserID(userID: String, secret: String): String {
  val mac = Mac.getInstance("HmacSHA512")
  mac.init(SecretKeySpec(secret.toByteArray(Charsets.UTF_8), "HmacSHA512"))
  return mac.doFinal(userID.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
}
```

**Java**

```java
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;

public static String signUserID(String userID, String secret) throws Exception {
  Mac mac = Mac.getInstance("HmacSHA512");
  mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA512"));
  StringBuilder hex = new StringBuilder();
  for (byte b : mac.doFinal(userID.getBytes(StandardCharsets.UTF_8))) hex.append(String.format("%02x", b));
  return hex.toString();
}
```

A typical endpoint: `POST /sinch/sign {"userId": "…"}` → `{"signedUserId": "<hex>"}`, behind your own authentication.

## Delivery events

Two different things are called "delivered":

| | Meaning | Reported by |
| --- | --- | --- |
| Conversation API `DELIVERED` | Sinch handed the message to **APNs / FCM** and the provider accepted it. | The Sinch backend. It says nothing about the device. |
| Device-side `DELIVERED` | The push **reached this device** (and the SDK saw it). | This SDK, via `SdkService.ReportEvents` (gRPC-web (Connect) over HTTPS). |

Only `DELIVERED` is reported for APNs/FCM pushes. The `ReportEvents` event types have no clicked/opened state.

Each report is `{ message_id, subscriber_id }`, taken from the `sinch.push.message_id` and `sinch.push.subscriber_id` entries the Sinch backend adds to the push. Pushes without both (not from Sinch) are ignored. A push is reported once even if it also reaches the device over another channel.

### Who reports what

| State | iOS | Android |
| --- | --- | --- |
| **Foreground** | `willPresentNotification` (the SDK is the notification center delegate): the push is emitted to JS and shown; the report is queued natively and flushed by JS immediately. | `onMessageReceived`: emitted to JS and shown; queued, then uploaded natively and flushed by JS if it is running. |
| **Background** | With `content-available: 1` and *Remote notifications*, iOS calls `didReceiveRemoteNotification:fetchCompletionHandler:`. If a JWT is stored, native hands the report to a **background URLSession** and finishes the wake immediately; otherwise it wakes JS to flush (≤ 20 s). With an NSE and `mutable-content: 1`, the extension also reports. | FCM runs the service (`handleIntent` for notification+data, `onMessageReceived` for data-only): the report is queued and uploaded **natively** with the mirrored session, one attempt of at most 8 s on the FCM thread. If it fails (offline, server error), the entry stays queued; the next push's upload or the JS flush on the next foreground sends it. |
| **Killed** (swiped away / evicted) | Same as background: the push relaunches the app for `content-available`; the NSE runs for alert pushes with `mutable-content: 1`. | FCM starts the process for the service: same as background. |
| **Force-quit** (iOS) / **Force stop** (Android) | Only the **NSE** runs (alert + `mutable-content: 1` + `ios.appGroup`). No wake. | FCM does not deliver to a force-stopped app until the user opens it again. |

### Backend requirements

What iOS can report depends on the APNs payload the Sinch Push backend builds:

| Payload flag | Needed for | Released backend |
| --- | --- | --- |
| `mutable-content: 1` | The NSE (the only path for a **force-quit** app). | **Not set.** Support exists on an unreleased backend change; until it ships, the NSE is never invoked. |
| `content-available: 1` | The background / killed wake (`didReceiveRemoteNotification:fetchCompletionHandler:`). | Set only when the message carries metadata. Conversation API messages do, so they wake the app. |

Android has no such dependency: FCM runs the SDK's service for both the `notification` + `data` and the data-only shape.

`ReportEvents` itself: the push host may answer as gRPC-web or as plain gRPC (`application/grpc+proto`, status in HTTP/2 trailers). iOS and the JS flusher cannot read HTTP/2 trailers, so they count a 2xx gRPC reply without a visible `grpc-status` as accepted. The server must therefore report a `ReportEvents` error trailers-only (`grpc-status` in the response headers, as standard gRPC servers do for an error raised before any reply).

If a native path cannot report (no stored JWT, expired token, offline), the entry stays in the **outbox** and the JS flusher sends it the next time the app is active, once `initialize` has run and an identity is set.

### Outbox, retry and TTL

- Queued reports are durable (native storage) and survive process death.
- Batches of **100** per `ReportEvents` call.
- Network errors and server errors are retried with exponential backoff and jitter (1 s base, 30 s cap), up to 5 failed attempts per flush; the rest wait for the next trigger.
- `Unauthenticated` re-reads the stored JWT once and retries; `InvalidArgument`, `NotFound` and `PermissionDenied` drop the batch.
- Entries older than **72 h** are dropped unsent by the JS flusher.
- `removeIdentity` clears the outbox and the mirrored credential; signing in as a different user clears the previous user's queued reports.
- Native uploads use the JWT mirrored at `setIdentity` (on Android in no-backup storage, so it is not restored to another device). When that JWT expires, native uploads pause until the next `setIdentity`; queued entries stay in the outbox until then (or until the 72 h TTL).

## API reference

All exports are available as named imports and, except the `EVENT_*` constants, on the default export `SinchPush`.

| Export | Description |
| --- | --- |
| `initialize(config: SinchPushConfig, options?: { deviceTokenStorage?: DeviceTokenStorage }): Promise<void>` | Set up transport, storage, report flushing and token capture. Rejects if `projectID`, `clientID`, `configID` (or the custom URLs for `env: 'custom'`) are missing. |
| `setIdentity(identity: SignedIdentity): Promise<void>` | Mint a JWT from `{ userID, signedUserID }`, mirror the report credential to native, subscribe the device token. |
| `removeIdentity(identity: SignedIdentity): Promise<void>` | Unsubscribe (best effort), clear the JWT, outbox, credential and subscribe state. |
| `setDeviceToken(token: string): void` | Provide a token from another push provider (overrides the captured one). |
| `getDeviceToken(): Promise<DeviceToken \| null>` | The latest token `{ token, type: 'apns' \| 'fcm' }`, or `null`. |
| `registerForToken(): Promise<void>` | iOS: ask for authorization and register with APNs. Android: re-run FCM token capture and the permission request. |
| `onTokenReceiveHandler(h: (t: DeviceToken) => void): Subscription` | Token issued or refreshed. |
| `onPushReceiveHandler(h: (m: SinchPushMessage) => void): Subscription` | Push received while JS is running (foreground, or background with JS alive). |
| `onInAppMessageHandler(h: (m: InAppMessage) => void): Subscription` | Decoded `protobufPayload`: `text`, `media`, `location`, `choice`, `card`, `carousel`. Ordinary pushes do not reach it. |
| `getInstallationId(): Promise<string>` | Lowercase UUID of this install, generated once; rejects with `E_INSTALLATION_ID_UNAVAILABLE` if the Keychain/Keystore cannot be used right now. |
| `getDeviceInfo(): Promise<DeviceInfo>` | `installationId`, `platform`, `osVersion`, `sdkVersion`, `bundleId`, `backgroundService`: what `Subscribe` carries. |
| `setRelayEnabled(enabled: boolean): Promise<void>` | Turn the [relay](#advanced-the-relay-persistent-websocket) on or off for this install (persisted). |
| `isRelayEnabled(): Promise<boolean>` | Current relay switch; `false` until turned on. |
| `startPushSocket(config: PushSocketConfig): Promise<void>` | Relay: open the socket. |
| `stopPushSocket(): Promise<void>` | Relay: close it. |
| `getPushSocketState(): Promise<PushSocketState>` | Relay: status (`idle`, `connecting`, `connected`, `reconnecting`, `error`, `auth_required`, `replaced`, `stopped`). |
| `onSocketMessageHandler(h): Subscription` | Relay: a message arrived. |
| `onSocketStateHandler(h): Subscription` | Relay: state changed. |
| `getPendingPushMessages(): Promise<PushSocketMessage[]>` / `clearPendingPushMessages(): Promise<void>` | Relay: buffered messages, including ones received while the app was away. |
| `displayNotification(title, body, data?): Promise<void>` | Post a local notification. |
| `reportPushMessageStatus(id, 'displayed' \| 'dismissed'): Promise<void>` | Relay: report a status for a message you surfaced yourself. |
| `sendPushSocketPoll(): void` | No-op, kept for compatibility. |
| `EVENT_PUSH_RECEIVED`, `EVENT_TOKEN_RECEIVED`, `EVENT_DEVICE_INFO_CHANGED` | Native event names. |

Types: `SinchPushConfig`, `SignedIdentity`, `DeviceToken`, `DeviceTokenType`, `SinchPushMessage`, `InAppMessage` (+ `InAppMessageCard`, `InAppMessageChoice`), `DeviceInfo`, `BackgroundServiceName`, `Subscription`, handler types, and `PushSocketConfig`, `PushSocketMessage`, `PushSocketState`, `PushSocketStatus`, `SocketDisplayRule`.

### `SinchPushConfig`

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `projectID` | `string` | required | Project id from the dashboard. |
| `clientID` | `string` | required | Client id. |
| `configID` | `string` | required | Push config id (one per platform/provider). |
| `env` | `'eu1' \| 'us1' \| 'custom'` | required | Region. |
| `customPushApiUrl` | `string` | required if `custom` | Push API base URL (gRPC-web (Connect) over HTTPS). |
| `customChatApiUrl` | `string` | required if `custom` | Chat API base URL. |
| `enableLogging` | `boolean` | `false` | Kept for compatibility; currently has no effect. |
| `autoRegisterForToken` | `boolean` | `true` | Call `registerForToken()` from `initialize`. Set `false` to delay the iOS permission prompt and call it yourself. |
| `ios.appGroup` | `string` | none | iOS only. App Group shared with the Notification Service Extension. Ignored on Android. |
| `socket.enabled` | `boolean` | `false` (off) | Persisted relay switch. Omitted keeps the stored value, so an app that enabled the relay in a pre-release build stays on until it passes `false`. On Android without the gradle property `SinchPush_relay=true` the relay is not built in and `isRelayEnabled()` reads `false` even after `true` is passed here. |
| `socket.customWsUrl` | `string` | region relay | Relay URL. For `env: 'custom'` it is required unless `customPushApiUrl` is a known Sinch push host (the relay is then derived from it). |
| `socket.allowInsecureWs` | `boolean` | `false` | Allow `ws://` outside `__DEV__`. |

`SinchPushConfig.socket` has only these three fields. Display and polling behaviour (`displayNotifications`, `pollIntervalMs`) are options of `startPushSocket`, not of `initialize`.

Hosts: `eu1` → push `https://grpc.sinch-push.prod.sinch.com`, chat `https://grpc-web.sinch-chat.prod.sinch.com`; `us1` → `https://grpc.sinch-push.us1.prod.sinch.com`, `https://grpc-web.sinch-chat.us1.prod.sinch.com`.

## Advanced: the relay (persistent WebSocket)

The relay is a persistent WebSocket delivery channel next to APNs/FCM: Android runs it in a foreground service, iOS only while the app is in the foreground. **It is off by default.** Most apps do not need it; APNs/FCM and the delivery reports above work without it.

To opt in:

1. **JS**: `initialize({ …, socket: { enabled: true } })`, or `await SinchPush.setRelayEnabled(true)`. The switch is persisted natively.
2. **Android only**: set the gradle property `SinchPush_relay=true` in `android/gradle.properties` (or `-PSinchPush_relay=true`, or `rootProject.ext.SinchPush_relay`). This merges the library's relay manifest, which adds the `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_DATA_SYNC` permissions and a `dataSync` foreground service. **Google Play requires a foreground-service declaration** (Play Console → App content) for apps that ship one. Without the property, the app declares neither.
3. Call `startPushSocket({})` after `setIdentity`. The URL, JWT, `appId`, `userId` and `projectId` are filled in from `initialize` and the stored JWT.

Relay hosts: `eu1` → `wss://relay.sinch-push.prod.sinch.com/ws`, `us1` → `wss://relay.sinch-push.us1.prod.sinch.com/ws`; `env: 'custom'` needs `socket.customWsUrl` unless `customPushApiUrl` is a known Sinch push host. `ws://` needs `socket.allowInsecureWs: true` outside `__DEV__`.

While the relay is off, `startPushSocket` rejects with **`E_RELAY_DISABLED`** (the message names the opt-in), `getDeviceInfo().backgroundService` is `'RELAY_DISABLED'`, and nothing opens a socket or starts a service. The same code is returned when a `custom` environment has no relay URL. `setRelayEnabled(false)` closes the socket and (Android) stops and disables the service; APNs/FCM are unaffected.

Other `startPushSocket` errors: `E_NOT_INITIALIZED`, `E_NOT_AUTHENTICATED` (no JWT or it expired), `E_WS_INSECURE`, `E_WS_NOT_CONFIGURED`, `E_FGS_START_REFUSED` (Android refused the foreground service, e.g. started from the background), `E_START_PUSH_SOCKET`. The socket speaks a protobuf frame protocol over a single WebSocket (`Hello` → `HelloAck`, then messages, acks and delivery reports).

**Upgrading with the relay already on.** The switch is persisted: an app that enabled the relay in a pre-release build stays on after the upgrade until `initialize` is given `socket: { enabled: false }` (or `setRelayEnabled(false)` is called). On Android without `SinchPush_relay=true`, `isRelayEnabled()` reads `false` even after `setRelayEnabled(true)`: the relay is not built into the app.

## Running the example

[`examples/SinchPushExample`](examples/SinchPushExample/README.md) is a one-screen React Native 0.76 (New Architecture) app: config → identity → token → received messages → event log. Its [README](examples/SinchPushExample/README.md) has the full steps. The four things to fill in:

| File | What |
| --- | --- |
| `src/config.ts` (copied from `config.example.ts`) | `projectID`, `clientID`, `configID.ios/android`, `env`, `iosAppGroup`, and `signedUserIdUrl` (your signing endpoint). `demoOnlyIdentitySecret` signs on the device and is for demos only. |
| `ios/Config.xcconfig` (from `Config.example.xcconfig`) | `DEVELOPMENT_TEAM`, `APP_BUNDLE_ID`, `APP_GROUP` (equal to `iosAppGroup`). |
| `android/app/google-services.json` and `sinchExample.applicationId` in `android/gradle.properties` | Your Firebase config; the package name must match. |
| `.env` (optional, from `.env.example`) | Conversation API credentials for `scripts/send-test-push.mjs`, which sends a test push to a user id. The Conversation API app needs the Sinch Push channel enabled (ask Sinch or check the dashboard), or the call fails with 400/403. |

These files are git-ignored; the example never commits ids or secrets.

## Troubleshooting

| Symptom | Likely cause and fix |
| --- | --- |
| No token on the **iOS simulator** | The simulator cannot get an APNs token on every setup. Test on a device. |
| iOS token arrives but pushes never do, or the provider reports `BadDeviceToken` | `aps-environment` mismatch: debug builds use the **sandbox** APNs environment, TestFlight/App Store use **production**. Use the dashboard config that matches the build. |
| NSE never runs | The push has no `mutable-content: 1` (the released Sinch Push backend does not set it yet; see [Backend requirements](#backend-requirements)), is silent (no `alert`), or the extension is not embedded / has a different bundle-id prefix or deployment target. |
| NSE runs but `didReceive` returns `false` | Not a Sinch push (no `sinch.push.message_id`/`subscriber_id`), the App Group differs between app and extension or is missing from a profile, `ios.appGroup` was not passed to `initialize`, or no JWT has been mirrored yet (no `setIdentity` since install, or it expired). The app reports on its next run. |
| Android: nothing is displayed | `POST_NOTIFICATIONS` not granted (API 33+), the channel was muted, or `google-services.json`/plugin is missing so there is no FCM token. |
| Android: tray notification uses "Miscellaneous", or a manifest merge error on `default_notification_channel_id` | Another library or your app declares `default_notification_channel_id`; use `tools:replace`, or `SinchPush_defaultNotificationChannel=false` (see [Android setup](#4-notification-permission-and-channel)). |
| Reports do not arrive | No identity set (`setIdentity` never succeeded), JWT expired (call `setIdentity` again), `initialize` not called at start, the push lacks the `sinch.push.*` keys, iOS app force-quit without an NSE, or Android app force-stopped. A queued report is sent on the next foreground. |
| `E_RELAY_DISABLED` | The relay is off (default). See [Advanced](#advanced-the-relay-persistent-websocket) to opt in, or ignore it if you do not use the relay. |
| Android: SDK service never runs / no reports / no token event | Your app has its own `FirebaseMessagingService` and it won the `MESSAGING_EVENT` resolution (only one service receives it). Set `SinchPush_firebaseMessaging=none` and [forward](#already-have-a-firebasemessagingservice) from yours. |
| `The package … doesn't seem to be linked` | Run `pod install`, rebuild the app, and do not use Expo Go. |
| Duplicate reports after a force-quit on iOS | iOS does not relaunch a force-quit app for the extension's upload result; if the app is not opened within ~30 min the report is retried. Harmless: the server keeps the first terminal status. |

## Development

```sh
npm test            # jest
npm run test:android   # JVM unit tests (cd android && ./gradlew testDebugUnitTest)
npm run test:ios       # SwiftPM harness in ios/SinchPushSocketTests
npm run typecheck
```

The protobuf code is generated from Sinch's internal proto sources and **committed**: `src/generated` (TypeScript), `ios/SinchPushSocket/Generated` (Swift) and `android/src/main/wire` (Kotlin, Square Wire). A checkout builds, tests and packs without any generation step; `prepack` only checks that these files are present. Regenerating them requires the internal proto sources, so outside contributors should not edit the generated files and should leave regeneration to the maintainers.

- `test:android` needs `npm install` first (`android/settings.gradle` reads React Native's gradle files from `node_modules`).
- `test:ios` needs Xcode 16.3 or later (swift-protobuf's package manifest uses Swift tools 6.2).
- The relay golden-vector suites (`RelayGoldenVectorsTest`, `RelayGoldenTests`) skip unless the relay test vectors are provided.

## License

MIT
