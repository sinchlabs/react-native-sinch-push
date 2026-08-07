
# Sinch Inbox Documentation

The Sinch Inbox provides functionality to manage and display chat conversations in your iOS application. This guide explains how to use the SinchInbox features effectively.

## Table of Contents
- [Setup](#setup)
- [Core Features](#core-features)
- [Event Handling](#event-handling)
- [Error Handling](#error-handling)
- [UI Customization](#ui-customization)

## Setup

Before using Sinch Inbox, ensure you have initialized the SinchChatSDK and completed user authentication. See the main SDK documentation for these prerequisites.

### SwiftUI

Display the inbox in SwiftUI:

```swift
import SwiftUI
import SinchChatSDK

struct MessageCenterView: View {
    @StateObject private var sinchState = SinchChatSDKState()

    var body: some View {
        SinchInboxView(
            options: GetChatViewControllerOptions(metadata: [], shouldInitializeConversation: true)
        )
        .ignoresSafeArea()
        .task {
            await sinchState.loadInboxChats(options: GetChatViewControllerOptions(metadata: [], shouldInitializeConversation: true))
            sinchState.subscribeToInboxUpdates(options: GetChatViewControllerOptions(metadata: [], shouldInitializeConversation: true))
        }
    }
}
```

Use `SinchChatSDKState` to observe inbox updates:

```swift
sinchState.$lastInboxEvent
    .compactMap { $0 }
    .sink { event in
        switch event {
        case .chatUpdated(let chat):
            print("Chat updated: \(chat.name)")
        case .subcriptionFailed:
            print("Subscription failed")
        }
    }
    .store(in: &cancellables)
```

## Core Features

### 1. Get Inbox View Controller

Display the main inbox interface with a list of conversations:

```swift
do {
    let inboxViewController = try SinchChatSDK.shared.chat.inbox.getInboxViewController(
        uiConfig: nil,                     // Optional UI configuration
        localizationConfig: nil,           // Optional localization
        options: nil                       // Optional chat options
    )

    // Present the inbox view controller
    present(inboxViewController, animated: true)
} catch {
    // Handle error
}
```

### 2. Fetch Inbox Chats

Retrieve a list of conversations:

```swift
SinchChatSDK.shared.chat.inbox.getInboxChats(options: nil) { chats in
    // Handle array of InboxChat objects
    chats.forEach { chat in
        print("Chat name: \(chat.name)")
        print("Last message: \(chat.text)")
        print("Date: \(chat.sendDate)")
    }
}
```

### 3. Subscribe to Inbox Updates

Monitor changes to conversations in real-time:

```swift
// Set up subscription
SinchChatSDK.shared.chat.inbox.subscribeToInboxChatUpdates(options: options)

// Handle updates through the event listener
sinchInbox.chatInboxEventListenerSubject
    .sink { event in
        switch event {
        case .chatUpdated(let chat):
            // Handle updated chat
            print("Chat updated: \(chat.name)")
        case .subcriptionFailed:
            // Handle subscription failure
            print("Subscription failed")
        }
    }
    .store(in: &cancellables)
```

### 4. Open Individual Chats

Open a specific conversation from the inbox:

```swift
do {
    let chatViewController = try SinchChatSDK.shared.chat.inbox.getChatViewController(
        inboxChat: chat,
        uiConfig: nil,                     // Optional UI configuration
        localizationConfig: nil            // Optional localization
    )

    // Present the chat view controller
    present(chatViewController, animated: true)
} catch {
    // Handle error
}
```

## Event Handling

The Sinch Inbox provides real-time updates through the `chatInboxEventListenerSubject`. Events include:

- `chatUpdated`: Triggered when a conversation is updated
- `subcriptionFailed`: Triggered when subscription to updates fails

Example of handling events:

```swift
import Combine

var cancellables = Set<AnyCancellable>()

sinchInbox.chatInboxEventListenerSubject
    .sink { event in
        switch event {
        case .chatUpdated(let chat):
            // Update UI with new chat information
        case .subcriptionFailed:
            // Handle subscription failure, possibly retry
        }
    }
    .store(in: &cancellables)
```

## Error Handling

The Sinch Inbox may throw `SinchInboxSDKError`:

```swift
enum SinchInboxSDKError: Error {
    case unavailable
}
```

Example of error handling:

```swift
do {
    let inboxViewController = try sinchInbox.getInboxViewController()
    // Present view controller
} catch SinchInboxSDKError.unavailable {
    // Handle SDK unavailability
} catch {
    // Handle other errors
}
```

## UI Customization

### Configuration Options

1. UI Configuration (`SinchSDKConfig.UIConfig`):
   - Customize colors, fonts, and layout
   - Modify navigation bar appearance
   - Adjust chat bubble styles

2. Localization (`SinchSDKConfig.LocalizationConfig`):
   - Customize text strings
   - Support multiple languages
   - Modify date formats

Example of customization:

```swift
let uiConfig = SinchSDKConfig.UIConfig(
    // Add UI customization parameters
)

let localizationConfig = SinchSDKConfig.LocalizationConfig(
    // Add localization parameters
)

do {
    let inboxViewController = try SinchChatSDK.shared.chat.inbox.getInboxViewController(
        uiConfig: uiConfig,
        localizationConfig: localizationConfig
    )
    // Present view controller
} catch {
    // Handle error
}
```

## Data Models

### InboxChat

The `InboxChat` model represents a conversation in the inbox:

```swift
public struct InboxChat: Codable {
    public var name: String           // Display name
    public var text: String           // Last message
    public var sendDate: Date         // Last message date
    public var avatarImage: String?   // Avatar image URL
    public var status: String         // Chat status
    public var chatOptions: GetChatViewControllerOptions?
}
```

## Best Practices

1. **Event Handling**:
   - Always maintain a strong reference to your Combine subscribers
   - Handle subscription failures appropriately
   - In SwiftUI, prefer `SinchChatSDKState.subscribeToInboxUpdates(options:)` over manual subject wiring

2. **Error Handling**:
   - Implement proper error handling for all SDK method calls
   - Provide appropriate user feedback for errors

3. **Memory Management**:
   - Cancel subscriptions when they're no longer needed
   - Properly clean up resources in view controller lifecycle methods

4. **UI Updates**:
   - Update UI on the main thread when handling events
   - Consider using loading indicators for async operations
