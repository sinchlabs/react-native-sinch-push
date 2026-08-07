# SinchChatSDK

Sinch Chat SDK for iOS. The SDK provides UIKit view controllers for chat and inbox, plus first-stage SwiftUI support through wrapper views and a state object.

## Requirements

- iOS 18+
- Swift 6+

## Setup

1. Add the `SinchChatSDK` package to your project.
2. Initialize the SDK early in app launch (typically from `AppDelegate` or `@UIApplicationDelegateAdaptor`):

```swift
SinchChatSDK.shared.initialize(.init(pushNotificationMode: .sandbox))
```

3. Set the user identity before opening chat or inbox UI:

```swift
SinchChatSDK.shared.setIdentity(
    with: .init(
        clientID: "your-client-id",
        projectID: "your-project-id",
        configID: "your-config-id",
        region: .EU1
    ),
    identity: .anonymous
) { result in
    // handle result
}
```

## UIKit Integration

Create chat UI:

```swift
let chatViewController = try SinchChatSDK.shared.chat.getChatViewController(
    uiConfig: .defaultValue,
    localizationConfig: .defaultValue,
    options: GetChatViewControllerOptions(metadata: [], shouldInitializeConversation: true)
)
navigationController.pushViewController(chatViewController, animated: true)
```

Create inbox UI:

```swift
let inboxViewController = try SinchChatSDK.shared.chat.inbox.getInboxViewController(
    uiConfig: .defaultValue,
    localizationConfig: .defaultValue,
    options: GetChatViewControllerOptions(metadata: [], shouldInitializeConversation: true)
)
navigationController.pushViewController(inboxViewController, animated: true)
```

## SwiftUI Integration

### Wrapper Views

Use `SinchChatView` and `SinchInboxView` to embed SDK UI in SwiftUI:

```swift
import SwiftUI
import SinchChatSDK

struct ChatScreen: View {
    var body: some View {
        SinchChatView(
            uiConfig: .defaultValue,
            localizationConfig: .defaultValue,
            options: GetChatViewControllerOptions(metadata: [], shouldInitializeConversation: true),
            onError: { error in
                print("Failed to open chat: \(error)")
            }
        )
        .ignoresSafeArea()
    }
}
```

```swift
struct InboxScreen: View {
    var body: some View {
        SinchInboxView(
            options: GetChatViewControllerOptions(metadata: [], shouldInitializeConversation: true)
        )
        .ignoresSafeArea()
    }
}
```

These views wrap the existing UIKit controllers in a `UINavigationController`, preserving SDK navigation behavior.

### State Management

Use `SinchChatSDKState` for SwiftUI-friendly identity and event handling:

```swift
import SwiftUI
import SinchChatSDK

struct ContentView: View {
    @StateObject private var sinchState = SinchChatSDKState()
    @State private var showChat = false

    var body: some View {
        VStack {
            Text("Chat status: \(String(describing: sinchState.chatAvailability))")

            Button("Sign In") {
                Task {
                    try await sinchState.setIdentity(
                        with: .init(
                            clientID: "your-client-id",
                            projectID: "your-project-id",
                            configID: "your-config-id",
                            region: .EU1
                        ),
                        identity: .anonymous
                    )
                    showChat = true
                }
            }
        }
        .fullScreenCover(isPresented: $showChat) {
            SinchChatView(options: GetChatViewControllerOptions(metadata: [], shouldInitializeConversation: true))
        }
    }
}
```

Available state:

- `identityStatus` — `.notSet`, `.setting`, `.set`, `.removing`, `.failed`
- `chatAvailability` — current chat availability from the SDK
- `isSettingIdentity` / `isRemovingIdentity` — loading flags
- `lastPluginEvent` — latest SDK lifecycle event
- `inboxChats` — inbox conversations loaded via `loadInboxChats(options:)`
- `lastInboxEvent` — latest inbox update event
- `lastError` — most recent error

Async methods:

```swift
try await sinchState.setIdentity(with: config, identity: .anonymous)
try await sinchState.removeIdentity()
sinchState.refreshChatAvailability()
await sinchState.loadInboxChats(options: nil)
sinchState.subscribeToSDKEvents()
sinchState.subscribeToInboxUpdates(options: GetChatViewControllerOptions(metadata: [], shouldInitializeConversation: true))
```

## Push Notifications

Keep push registration and notification delegate methods in `AppDelegate` or `@UIApplicationDelegateAdaptor`:

```swift
func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    SinchChatSDK.shared.push.sendDeviceToken(deviceToken)
}
```

## Migration Notes

- Existing UIKit integrations should continue using `getChatViewController` and `getInboxViewController`.
- SwiftUI apps should prefer `SinchChatView`, `SinchInboxView`, and `SinchChatSDKState` for first-stage support.
- A future SDK release may provide native SwiftUI chat/inbox views; the current SwiftUI API wraps UIKit internally.

## Security

### Identity signing

Prefer the new `selfSignedWithAppSecret` identity so the SDK computes the
HMAC-SHA512 digest internally — your app secret never has to leave the
caller and is not persisted:

```swift
SinchChatSDK.shared.setIdentity(
    with: config,
    identity: .selfSignedWithAppSecret(
        userId: userID,
        appSecret: appSecret
    )
)
```

`selfSigned(userId:secret:)` is still supported for backwards compatibility
but requires you to pre-compute the digest with the now-deprecated
`String.hmac(algorithm: .SHA512, key:)` helper.

### Token storage

Access tokens are stored in the iOS Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), scoped per SDK
configuration. On first contact with the SDK, any token previously stored in
`UserDefaults` is migrated automatically and the legacy key is removed.

### Production note

Do not embed your application secret in production code. The same warning
applies to the Sinch RTC JWT helpers in `SinchVideoRTCPluginSDK` — sign JWTs
on your backend and ship the resulting token to the client.
