# react-native-sinch-push

React Native SDK for Sinch Push, using Connect-RPC for identity and device
management. Supports both the old (bridge) and new (TurboModule) architectures.

Device-token capture and push delivery are handled natively (**APNs** on iOS),
while identity management business logic runs in JavaScript.

> **Heads up**: `setIdentity` and `removeIdentity` now use Connect-RPC over
> HTTPS instead of REST. `signedUserID` is now consumed as the HMAC-SHA-512
> digest input to `IssueTokenWithSignedUuid` (the issued JWT is the bearer
> token). The public method shapes are unchanged; the wire semantics are.

## Features

- `SinchPush.initialize(config)` — initialize the SDK (creates Connect transport, sets up Keychain)
- `SinchPush.setIdentity(signedIdentity)` — register a signed identity (issues JWT over `IssueTokenWithSignedUuid`, then `Subscribe` with the device token)
- `SinchPush.removeIdentity(signedIdentity)` — unregister an identity (`Unsubscribe` + clear Keychain)
- `SinchPush.setDeviceToken(token)` — provide a device token from any push service
- `SinchPush.onPushReceiveHandler(handler)` — subscribe to raw incoming pushes
- `SinchPush.onInAppMessageHandler(handler)` — **NEW** — subscribe to typed in-app messages (text / media / location / choice / card / carousel)
- `SinchPush.onTokenReceiveHandler(handler)` — subscribe to device token issue/refresh
- `SinchPush.getDeviceToken()` — read the latest device token
- `SinchPush.registerForToken()` — explicitly request a device token (iOS only)

## Installation

```sh
npm install react-native-sinch-push react-native-keychain
# or
yarn add react-native-sinch-push react-native-keychain
```

`react-native-keychain` is required at runtime for token storage. The
issued JWT from `IssueTokenWithSignedUuid` is persisted in the iOS
Keychain / Android Keystore so that it survives app restarts.

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

The library does **not** ship with a built-in push service. You provide the
device token yourself via `SinchPush.setDeviceToken(token)`.

If you use Firebase Cloud Messaging:

1. Add Firebase to your app: place `google-services.json` in `android/app/` and
   apply the Google Services Gradle plugin (`com.google.gms.google-services`) in
   your app module.
2. Declare a `FirebaseMessagingService` in your app's `AndroidManifest.xml` that
   forwards the token and inbound messages to the SDK:

```kotlin
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.sinchpush.SinchPushEmitter

class MyFirebaseMessagingService : FirebaseMessagingService() {

  override fun onNewToken(token: String) {
    super.onNewToken(token)
    SinchPushEmitter.onNewToken(token)
  }

  override fun onMessageReceived(message: RemoteMessage) {
    super.onMessageReceived(message)
    val notification = message.notification
    SinchPushEmitter.onMessage(
      data = message.data,
      title = notification?.title,
      body = notification?.body,
    )
  }
}
```

Autolinking registers the native package; no manual `MainApplication` changes
are needed on RN 0.60+.

## Usage

```ts
import SinchPush from 'react-native-sinch-push';

async function bootstrap() {
  // 1. Initialize the SDK — sets up the Connect transport and Keychain.
  await SinchPush.initialize({
    projectID: 'your-sinch-project-id',
    clientID: 'your-sinch-client-id',
    configID: 'your-sinch-config-id',
    env: 'eu1',                  // 'eu1' | 'us1' | 'custom'
    enableLogging: __DEV__,
  });

  // 2. Provide a device token (required on Android, optional on iOS)
  //    On iOS the APNs token is captured automatically; on Android you
  //    must obtain one from your push service (FCM, HMS, etc.).
  SinchPush.setDeviceToken('device-token-from-push-service');

  // 3. Device token events (APNs auto-capture on iOS)
  const tokenSub = SinchPush.onTokenReceiveHandler((t) => {
    console.log(`${t.type} token:`, t.token);
  });

  // 4. Incoming pushes
  const pushSub = SinchPush.onPushReceiveHandler((message) => {
    console.log('push received', message.title, message.body, message.data);
  });

  // 5. Typed in-app messages (NEW). The SDK base64-decodes the
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

  // 6. Register the identity. SDK calls
  //    IssueTokenWithSignedUuid({ uuid, uuid_hash }) to mint a JWT,
  //    then Subscribe({ config, token }) with the device token.
  //    The JWT is persisted to Keychain and used as the bearer
  //    token on subsequent calls.
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

`signedUserID` is the **HMAC-SHA-512 hex digest** of `userID` keyed by the
app secret from the Sinch Build Dashboard. It is **not** the bearer token —
it is the `uuid_hash` input to `IssueTokenWithSignedUuid`. The SDK mints the
actual JWT from the chat SDK service and uses it as the bearer token on
`Subscribe` / `Unsubscribe` calls.

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
import SinchPush from 'react-native-sinch-push';

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

## API

| Method | Description |
| --- | --- |
| `initialize(config: SinchPushConfig): Promise<void>` | Initialize the SDK with your Sinch project credentials. Sets up the Connect transport, wires the Keychain-backed token storage, and requests a device token on iOS unless `autoRegisterForToken` is `false`. |
| `setIdentity(signedIdentity: SignedIdentity): Promise<void>` | Register a signed identity for push delivery on this device. Calls `IssueTokenWithSignedUuid` to mint a JWT, persists it to Keychain, then calls `Subscribe` with the device token using the JWT as the bearer. |
| `removeIdentity(signedIdentity: SignedIdentity): Promise<void>` | Unregister an identity from this device. Calls `Unsubscribe` (best-effort) and clears the stored JWT from Keychain. |
| `setDeviceToken(token: string): void` | Provide a device token from any push service. Overrides any natively captured token. Call before `setIdentity()`. |
| `getDeviceToken(): Promise<DeviceToken \| null>` | Latest token (JS-provided or natively captured), or `null`. |
| `registerForToken(): Promise<void>` | Request a device token (iOS: triggers APNs registration; Android: no-op). |
| `onPushReceiveHandler(handler): Subscription` | Subscribe to incoming raw push messages. |
| `onInAppMessageHandler(handler): Subscription` | Subscribe to typed in-app messages decoded from `protobufPayload`. See the in-app messages section. |
| `onTokenReceiveHandler(handler): Subscription` | Subscribe to token issue/refresh events. |

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
```

### Base URLs by environment

| `env` | Push base URL                              | Chat base URL                              |
| ----- | ------------------------------------------ | ------------------------------------------ |
| `eu1` | `https://grpc.sinch-push.prod.sinch.com`   | `https://grpc.sinch-chat.prod.sinch.com`   |
| `us1` | `https://grpc.sinch-push.us1.prod.sinch.com` | `https://grpc.sinch-chat.us1.prod.sinch.com` |
| `custom` | `customPushApiUrl` value                | `customChatApiUrl` value                   |

Both services speak the Connect protocol over HTTPS on port 443.

## Architecture

- **JavaScript** owns all business logic: `initialize` (sets up transport +
  Keychain), `setIdentity` (Connect-RPC `IssueTokenWithSignedUuid` +
  `Subscribe`), `removeIdentity` (`Unsubscribe` + Keychain clear),
  `setDeviceToken` (token injection). Uses `@connectrpc/connect-web` over
  global `fetch` for HTTPS calls. Auth tokens persisted via
  `react-native-keychain`.
- **iOS** (`SinchPush.swift`) is a single `RCTEventEmitter` that captures APNs
  tokens and forwards push payloads. No Sinch-specific logic.
- **Android** (`SinchPushModuleImpl.kt`) exposes event emitter plumbing only. No
  push service dependency. Tokens are injected via JS or forwarded natively through
  `SinchPushEmitter`.

## Generating protos

The TypeScript bindings for the Sinch gRPC contracts in `proto/` are generated
from the `.proto` files into `src/generated/` and shipped inside the npm
tarball.

```sh
npm run proto:gen              # preferred — uses buf generate
npm run proto:gen:protoc       # fallback — raw protoc, supports --target=push|chat|app|all
npm run proto:clean            # wipe src/generated/
```

Both paths use `@bufbuild/protoc-gen-es` (Protobuf-ES v2), which emits one
`*_pb.ts` per input `.proto` file containing message schemas and service
descriptors.

## What's removed

> **Removed**: `POST /v1/identities` and `POST /v1/identities/remove` REST
> endpoints are no longer used. `setIdentity` and `removeIdentity` are the
> only public path — they talk to `IssueTokenWithSignedUuid`, `Subscribe`,
> and `Unsubscribe` over Connect-RPC.

## License

MIT
