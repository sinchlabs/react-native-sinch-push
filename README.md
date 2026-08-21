# @sinch/react-native-sinch-push

> **Getting credentials:** to obtain your Sinch Push credentials
> (`projectID`, `clientID`, `configID`), sign in to the Sinch Build Dashboard at
> **https://dashboard.sinch.com/** and create/configure a Push configuration.

React Native SDK for Sinch Push. Registers identities and receives pushes using
Connect-RPC, with native APNs (iOS) and Firebase Cloud Messaging (Android)
device-token capture. Supports both the old (bridge) and new (TurboModule)
architectures.

## Features

- `initialize(config)` — initialize the SDK (creates the Connect transport, sets up Keychain)
- `setIdentity(signedIdentity)` — register a signed identity (issues a JWT over `IssueTokenWithSignedUuid`, then `Subscribe` with the device token)
- `removeIdentity(signedIdentity)` — unregister an identity (`Unsubscribe` + clear Keychain)
- `setDeviceToken(token)` — provide a device token from any push service
- `onPushReceiveHandler(handler)` — subscribe to raw incoming pushes
- `onInAppMessageHandler(handler)` — subscribe to typed in-app messages (text / media / location / choice / card / carousel)
- `onTokenReceiveHandler(handler)` — subscribe to device token issue/refresh
- `getDeviceToken()` — read the latest device token
- `registerForToken()` — explicitly request a device token (iOS only)

## Installation

```sh
npm install @sinch/react-native-sinch-push react-native-keychain
# or
yarn add @sinch/react-native-sinch-push react-native-keychain
```

`react-native-keychain` is a peer dependency, required at runtime for token
storage. The JWT issued by `IssueTokenWithSignedUuid` is persisted in the iOS
Keychain / Android Keystore so it survives app restarts.

## Setup

### iOS

```sh
cd ios && pod install
```

Push requires the **Push Notifications** capability and (for background pushes)
the **Remote notifications** Background Mode in Xcode.

React Native does not own your `UIApplicationDelegate`, so forward the APNs
callbacks to the SDK. In `AppDelegate.swift`:

```swift
import react_native_sinch_push

// MARK: - APNs registration
func application(
  _ application: UIApplication,
  didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
  SinchPush.didRegisterForRemoteNotificationsWithDeviceToken(deviceToken)
}

func application(
  _ application: UIApplication,
  didFailToRegisterForRemoteNotificationsWithError error: Error
) {
  SinchPush.didFailToRegisterForRemoteNotificationsWithError(error)
}

func application(
  _ application: UIApplication,
  didReceiveRemoteNotification userInfo: [AnyHashable: Any],
  fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
) {
  SinchPush.didReceiveRemoteNotification(userInfo as NSDictionary)
  completionHandler(.newData)
}
```

### Android

The library ships with an **auto-detected** Firebase Cloud Messaging (FCM)
integration. If your app already uses FCM, no `FirebaseMessagingService`,
`MainApplication` edits, or manual `setDeviceToken()` calls are required — the
SDK detects FCM at runtime, captures the device token, refreshes it on
rotation, and delivers background / terminated pushes to your JavaScript.

#### Required one-time Firebase setup (cannot be automated)

These two steps remain the host app's responsibility because a library AAR
cannot apply the Google Services Gradle plugin or ship `google-services.json`:

1. Place `google-services.json` in `android/app/`.
2. Apply the Google Services plugin in `android/app/build.gradle`:

   ```gradle
   apply plugin: 'com.android.application'
   apply plugin: 'org.jetbrains.kotlin.android'
   apply plugin: 'com.google.gms.google-services'  // <-- add this
   ```

   And add the classpath in `android/build.gradle`:

   ```gradle
   buildscript {
     dependencies {
       classpath 'com.google.gms:google-services:4.4.2'
     }
   }
   ```

#### FCM integration mode

The library reads `SinchPush_firebaseMessaging` from the host's root project
`ext` (or its own `android/gradle.properties` as fallback). Default: `optional`.

| Mode      | Dependency on `firebase-messaging` | Manifest service | Behaviour |
| --------- | ---------------------------------- | ---------------- | --------- |
| `optional` (default) | `compileOnly` — only resolves if host already includes FCM | Registered (gated by placeholder) | Auto-activates when host has FCM; silent no-op when it doesn't |
| `required` | `implementation` (library pulls FCM in) | Registered | For hosts that want the library to bring FCM |
| `none`     | Omitted | Disabled | Use `SinchPush.setDeviceToken()` yourself; the library will not touch FCM |

Set the mode in your `android/build.gradle`:

```gradle
ext {
  // pick one
  SinchPush_firebaseMessaging = 'optional'  // default
  // SinchPush_firebaseMessaging = 'required'
  // SinchPush_firebaseMessaging = 'none'
}
```

Hosts that already declare their own `FirebaseMessagingService` (for analytics,
notification posting, etc.) should set the mode to `none` to prevent double
handling — both services would otherwise receive every `MESSAGING_EVENT`.

#### Notification permission & display

On Android 13+ (`POST_NOTIFICATIONS`) and iOS, the SDK requests the relevant
runtime permission the first time `registerForToken()` is called. You don't
need to call anything else.

Once granted, pushes received while the app is in the foreground are still
posted to the system tray:

- **Android** — `SinchPushFirebaseMessagingService.onMessageReceived` builds a
  `NotificationCompat` notification on the `com.sinch.push.default` channel
  and posts it via `NotificationManagerCompat`. The title / body are sourced
  from the FCM `notification` payload first, falling back to common
  data-payload keys (`title`, `body`, `text`, `message`) and finally the app
  label.
- **iOS** — the SDK installs itself as the `UNUserNotificationCenter` delegate
  and returns `.banner | .list | .sound` from
  `willPresentNotification:withCompletionHandler:`. No extra code is required
  in your `AppDelegate`.

To use a different notification channel, icon, or tap behaviour, replace
`SinchPush_firebaseMessaging = 'none'` and provide your own
`FirebaseMessagingService` that calls `SinchPushEmitter.onMessage(...)`
directly.

#### What the library does automatically

- Detects FCM at runtime via reflection. No-op if absent.
- Captures the device token via `FirebaseMessaging.getInstance().token`,
  forwarding every value to `SinchPushEmitter`.
- Receives pushes in the background / terminated state via a manifest-declared
  `SinchPushFirebaseMessagingService` that calls `SinchPushEmitter.onMessage(...)`.
- Posts a system notification for every received push so the message is
  visible in the tray even while the app is in the foreground. When the app
  is backgrounded or terminated and the server payload includes a
  `notification` field, the system displays the push itself; calling
  `show` again from the service is harmless (same id + tag).
- Requests the `POST_NOTIFICATIONS` runtime permission on Android 13+ when
  `registerForToken()` runs.
- On `initialize()`, if a stored identity already exists in Keychain, watches
  the device-token stream and re-issues `Subscribe` whenever the token changes
  (FCM tokens rotate). Re-sending is skipped when the token hasn't changed.

If your app does not use FCM (e.g. HMS Push Kit), call
`SinchPush.setDeviceToken(token)` once the host obtains a token from your
provider, and forward inbound messages to `SinchPushEmitter.onMessage(...)`
yourself. Set `SinchPush_firebaseMessaging = 'none'` to disable the
manifest-merged FCM service.

Autolinking registers the native package; no manual `MainApplication` changes
are needed on RN 0.60+.

## Quick start

```ts
import SinchPush from '@sinch/react-native-sinch-push';

async function bootstrap() {
  // 1. Initialize the SDK — sets up the Connect transport and Keychain.
  await SinchPush.initialize({
    projectID: 'your-sinch-project-id',
    clientID: 'your-sinch-client-id',
    configID: 'your-sinch-config-id',
    env: 'eu1',                  // 'eu1' | 'us1' | 'custom'
    enableLogging: __DEV__,
  });

  // 2. (Optional) The device token is captured automatically:
  //    - iOS: APNs token via the AppDelegate forwarding hooks.
  //    - Android: FCM token via reflection-based auto-detection
  //      (requires google-services.json + Google Services plugin; see Android
  //      setup above).
  //    If you use a different provider (HMS, OneSignal, etc.) obtain the
  //    token yourself and call SinchPush.setDeviceToken(token).

  // 3. Device token events (auto-captured on both platforms)
  const tokenSub = SinchPush.onTokenReceiveHandler((t) => {
    console.log(`${t.type} token:`, t.token);
  });

  // 4. Incoming pushes
  const pushSub = SinchPush.onPushReceiveHandler((message) => {
    console.log('push received', message.title, message.body, message.data);
  });

  // 5. Typed in-app messages. The SDK base64-decodes the
  //    `protobufPayload` from the push and decodes the AppMessage
  //    into the discriminated union below.
  const inAppSub = SinchPush.onInAppMessageHandler((msg) => {
    switch (msg.kind) {
      case 'text': console.log('text:', msg.text); break;
      case 'media': console.log('media url:', msg.url); break;
      case 'location': console.log('at', msg.latitude, msg.longitude); break;
      case 'choice': console.log('text:', msg.text, 'choices:', msg.choices); break;
      case 'card': console.log('card:', msg.title, msg.url); break;
      case 'carousel': console.log('cards:', msg.cards.length); break;
    }
  });

  // 6. Register the identity. The SDK calls
  //    IssueTokenWithSignedUuid({ uuid, uuid_hash }) to mint a JWT,
  //    then Subscribe({ config, token }) with the device token.
  //    The JWT is persisted to Keychain and used as the bearer
  //    token on subsequent calls. The device token is also persisted;
  //    on subsequent app starts, if the token rotates, Subscribe is
  //    re-issued automatically.
  await SinchPush.setIdentity({
    userID: 'user-1234',
    signedUserID: '<hmac-sha512-hex-signature>',
  });

  // later, on logout:
  // await SinchPush.removeIdentity({
  //   userID: 'user-1234',
  //   signedUserID: '<hmac-sha512-hex-signature>',
  // });
  // tokenSub.remove();
  // pushSub.remove();
  // inAppSub.remove();
}
```

## Signing the identity (HMAC-SHA-512)

`signedUserID` is the **HMAC-SHA-512 hex digest** of `userID` keyed by the app
secret from the Sinch Build Dashboard. It is **not** the bearer token — it is
the `uuid_hash` input to `IssueTokenWithSignedUuid`. The SDK mints the actual
JWT from the chat SDK service and uses it as the bearer token on `Subscribe` /
`Unsubscribe` calls.

Sign on your **backend** (never on the device) using HMAC-SHA-512 with the
secret token from the Sinch Build Dashboard.

### Node.js

```ts
import { createHmac } from 'crypto';

function signUserID(userID: string, secret: string): string {
  return createHmac('sha512', secret)
    .update(userID)
    .digest('hex');
}

// Usage
const signedUserID = signUserID('user-1234', 'your-sinch-token-secret');
```

### Java

```java
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;

public class SinchSigner {
  public static String signUserID(String userID, String secret) throws Exception {
    Mac mac = Mac.getInstance("HmacSHA512");
    mac.init(new SecretKeySpec(
      secret.getBytes(StandardCharsets.UTF_8), "HmacSHA512"
    ));
    byte[] hash = mac.doFinal(userID.getBytes(StandardCharsets.UTF_8));
    StringBuilder hex = new StringBuilder();
    for (byte b : hash) {
      hex.append(String.format("%02x", b));
    }
    return hex.toString();
  }
}
```

## In-app messages

When a push arrives carrying a `protobufPayload` (a base64-encoded
`Sinch_Conversationapi_Type_AppMessage`), the SDK decodes it and dispatches
the result to any handler registered with `onInAppMessageHandler`. The
handler receives a discriminated union — switch on `kind` to narrow.

```ts
import SinchPush from '@sinch/react-native-sinch-push';

SinchPush.onInAppMessageHandler((msg) => {
  switch (msg.kind) {
    case 'text': {
      // { kind: 'text'; text: string }
      console.log(msg.text);
      break;
    }
    case 'media': {
      // { kind: 'media'; url: string }
      console.log('image at', msg.url);
      break;
    }
    case 'location': {
      // { kind: 'location'; latitude: number; longitude: number; title?: string; label?: string }
      console.log('open map at', msg.latitude, msg.longitude);
      break;
    }
    case 'choice': {
      // { kind: 'choice'; text: string; choices: InAppMessageChoice[] }
      console.log('choose:', msg.choices.map((c) => c.title));
      break;
    }
    case 'card': {
      // { kind: 'card'; title: string; description?: string;
      //         choices: InAppMessageChoice[]; url: string }
      console.log('card', msg.title, '→', msg.url);
      break;
    }
    case 'carousel': {
      // { kind: 'carousel'; cards: InAppMessageCard[]; choices: InAppMessageChoice[] }
      console.log('carousel with', msg.cards.length, 'cards');
      break;
    }
  }
});
```

Pushes that do **not** carry a `protobufPayload` are not delivered here —
they're only delivered via `onPushReceiveHandler` (which always sees every
push).

## API reference

### Methods

| Method | Description |
| --- | --- |
| `initialize(config: SinchPushConfig, options?: { deviceTokenStorage?: DeviceTokenStorage }): Promise<void>` | Initialize the SDK with your Sinch project credentials. Sets up the Connect transport, wires the Keychain-backed token storage, and triggers device-token capture on iOS (APNs) and Android (FCM auto-detection) unless `autoRegisterForToken` is `false`. The optional `deviceTokenStorage` lets you replace the Keychain-backed "last sent" tracker with your own implementation (used by the auto-resend feature). |
| `setIdentity(signedIdentity: SignedIdentity): Promise<void>` | Register a signed identity for push delivery on this device. Calls `IssueTokenWithSignedUuid` to mint a JWT, persists it to Keychain, then calls `Subscribe` with the device token using the JWT as the bearer. Persists the sent device token so future token rotations can be detected. |
| `removeIdentity(signedIdentity: SignedIdentity): Promise<void>` | Unregister an identity from this device. Calls `Unsubscribe` (best-effort), clears the stored JWT from Keychain, and clears the persisted "last sent" device token. |
| `setDeviceToken(token: string): void` | Provide a device token from any push service. Overrides any natively captured token. Useful when the host uses a provider the SDK does not auto-detect (e.g. HMS, OneSignal). |
| `getDeviceToken(): Promise<DeviceToken \| null>` | Latest token (JS-provided or natively captured), or `null`. |
| `registerForToken(): Promise<void>` | Request a device token (iOS: triggers APNs registration; Android: re-runs FCM detection). |
| `onPushReceiveHandler(handler): Subscription` | Subscribe to incoming raw push messages. |
| `onInAppMessageHandler(handler): Subscription` | Subscribe to typed in-app messages decoded from `protobufPayload`. See the in-app messages section. |
| `onTokenReceiveHandler(handler): Subscription` | Subscribe to token issue/refresh events. |

### Automatic device-token refresh

Once `initialize()` has been called, the SDK subscribes to native device-token
events. If a stored identity exists in Keychain (i.e. `setIdentity()` was
called in a previous session) **and** the new device token differs from the
last one persisted to Keychain, the SDK automatically issues a fresh
`Subscribe` request. If the token hasn't changed, nothing is sent.

The last-sent token is cleared by `removeIdentity()` so a re-login on the same
device re-subscribes cleanly.

### Configuration

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `projectID` | `string` | Yes | Your Sinch project ID from the Build Dashboard. |
| `clientID` | `string` | Yes | Your Sinch push client ID. |
| `configID` | `string` | Yes | Your Sinch push configuration ID. Determines the push service type (APNs, FCM, etc.) on the Sinch backend. |
| `env` | `'eu1' \| 'us1' \| 'custom'` | Yes | Target environment. Use `'custom'` with `customPushApiUrl` and `customChatApiUrl` for a custom endpoint. |
| `customPushApiUrl` | `string` | Required when `env === 'custom'` | Custom push Connect base URL. |
| `customChatApiUrl` | `string` | Required when `env === 'custom'` | Custom chat Connect base URL. |
| `enableLogging` | `boolean` | No | When `true`, verbose native logging is enabled. Defaults to `false`. |
| `autoRegisterForToken` | `boolean` | No | When `true` (default), automatically requests a device token during `initialize` (iOS only). |

### Types

```ts
interface SinchPushConfig {
  projectID: string;
  clientID: string;
  configID: string;
  env: 'eu1' | 'us1' | 'custom';
  customPushApiUrl?: string;       // required when env === 'custom'
  customChatApiUrl?: string;       // required when env === 'custom'
  enableLogging?: boolean;
  autoRegisterForToken?: boolean;
}

interface SignedIdentity {
  userID: string;
  signedUserID: string;            // HMAC-SHA-512 hex of userID (uuid_hash input)
}

interface DeviceToken {
  token: string;
  type: 'apns' | 'fcm';
}

interface SinchPushMessage {
  identity?: string;
  data: Record<string, string>;
  title?: string;
  body?: string;
  source: 'apns' | 'fcm';
}

interface InAppMessageChoice {
  title: string;
  value?: string;
}

interface InAppMessageCard {
  title: string;
  description?: string;
  choices: InAppMessageChoice[];
  url: string;
}

type InAppMessage =
  | { kind: 'text'; text: string }
  | { kind: 'media'; url: string }
  | {
      kind: 'location';
      title?: string;
      label?: string;
      latitude: number;
      longitude: number;
    }
  | { kind: 'choice'; text: string; choices: InAppMessageChoice[] }
  | {
      kind: 'card';
      title: string;
      description?: string;
      choices: InAppMessageChoice[];
      url: string;
    }
  | {
      kind: 'carousel';
      cards: InAppMessageCard[];
      choices: InAppMessageChoice[];
    };

interface Subscription {
  remove(): void;
}

interface DeviceTokenStorage {
  readLastSent(): Promise<string | null>;
  writeLastSent(token: string): Promise<void>;
  clearLastSent(): Promise<void>;
}
```

### Base URLs by environment

| `env` | Push base URL | Chat base URL |
| ----- | ------------------------------------------ | ------------------------------------------ |
| `eu1` | `https://grpc.sinch-push.prod.sinch.com` | `https://grpc.sinch-chat.prod.sinch.com` |
| `us1` | `https://grpc.sinch-push.us1.prod.sinch.com` | `https://grpc.sinch-chat.us1.prod.sinch.com` |
| `custom` | `customPushApiUrl` value | `customChatApiUrl` value |

Both services speak the Connect protocol over HTTPS on port 443.

## License

MIT
