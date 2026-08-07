#if canImport(SwiftUI)
import SwiftUI
import Combine

/// Observable state object for integrating SinchChatSDK with SwiftUI.
@MainActor
public final class SinchChatSDKState: ObservableObject {

    private let sdk: SinchChatSDK
    private var cancellables = Set<AnyCancellable>()

    @Published public private(set) var identityStatus: SinchIdentityStatus = .notSet
    @Published public private(set) var chatAvailability: SinchSDKChatAvailability = .uninitialized
    @Published public private(set) var isSettingIdentity = false
    @Published public private(set) var isRemovingIdentity = false
    @Published public private(set) var lastPluginEvent: SinchPluginEvent?
    @Published public private(set) var inboxChats: [InboxChat] = []
    @Published public private(set) var lastInboxEvent: SinchInboxEvent?
    @Published public private(set) var lastError: Error?

    public init(sdk: SinchChatSDK = .shared) {
        self.sdk = sdk
        refreshChatAvailability()
        subscribeToSDKEvents()
    }

    /// Sets the user identity using the SDK callback API bridged to async/await.
    public func setIdentity(
        with config: SinchSDKConfig.AppConfig,
        identity: SinchSDKIdentity
    ) async throws {
        isSettingIdentity = true
        identityStatus = .setting
        lastError = nil

        defer { isSettingIdentity = false }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sdk.setIdentity(with: config, identity: identity) { [weak self] result in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(throwing: SinchChatSDKError.unavailable)
                        return
                    }

                    switch result {
                    case .success:
                        self.identityStatus = .set
                        self.refreshChatAvailability()
                        continuation.resume()
                    case .failure(let error):
                        self.identityStatus = .failed
                        self.lastError = error
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Removes the current user identity using the SDK callback API bridged to async/await.
    public func removeIdentity() async throws {
        isRemovingIdentity = true
        identityStatus = .removing
        lastError = nil

        defer { isRemovingIdentity = false }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sdk.removeIdentity { [weak self] result in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(throwing: SinchChatSDKError.unavailable)
                        return
                    }

                    switch result {
                    case .success:
                        self.identityStatus = .notSet
                        self.inboxChats = []
                        self.refreshChatAvailability()
                        continuation.resume()
                    case .failure(let error):
                        self.lastError = error
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Refreshes chat availability from the underlying SDK.
    public func refreshChatAvailability() {
        chatAvailability = sdk.chat.isChatAvailable()
    }

    /// Loads inbox conversations into `inboxChats`.
    public func loadInboxChats(options: GetChatViewControllerOptions? = nil) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sdk.chat.inbox.getInboxChats(options: options) { [weak self] chats in
                Task { @MainActor in
                    self?.inboxChats = chats
                    continuation.resume()
                }
            }
        }
    }

    /// Subscribes to SDK plugin lifecycle events.
    public func subscribeToSDKEvents() {
        sdk.eventListenerSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }

                self.lastPluginEvent = event

                switch event {
                case .didSetIdentity:
                    self.identityStatus = .set
                    self.refreshChatAvailability()
                case .didRemoveIdentity:
                    self.identityStatus = .notSet
                    self.refreshChatAvailability()
                case .didStartChat, .didCloseChat:
                    self.refreshChatAvailability()
                case .didChangeInternetState:
                    break
                }
            }
            .store(in: &cancellables)
    }

    /// Subscribes to inbox update events and starts the SDK inbox subscription stream.
    public func subscribeToInboxUpdates(options: GetChatViewControllerOptions) {
        sdk.chat.inbox.chatInboxEventListenerSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }

                self.lastInboxEvent = event

                if case .chatUpdated(let chat) = event {
                    if let index = self.inboxChats.firstIndex(where: { $0.name == chat.name }) {
                        self.inboxChats[index] = chat
                    } else {
                        self.inboxChats.append(chat)
                    }
                }
            }
            .store(in: &cancellables)

        sdk.chat.inbox.subscribeToInboxChatUpdates(options: options)
    }
}

#endif
