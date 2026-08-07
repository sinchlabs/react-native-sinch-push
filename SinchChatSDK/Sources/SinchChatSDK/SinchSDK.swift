import UIKit
import Combine

public final class SinchChatSDK: @unchecked Sendable {
    
    /// Contains all methods regarding push notifications. To be able to use push notifications you need to call `setIdentity` method.
    private var _push: SinchPush?
    public var push: SinchPush {
        if let existing = _push { return existing }
        let new = MainActor.assumeIsolated { DefaultSinchPush(pushNotificationHandler: pushNotificationHandler) }
        _push = new
        return new
    }
    
    /// Contains all methods connected with Chat. Before using the chat you should use method `setIdentity`.
    public var chat: SinchChat { _chat }
    
    public static let shared = SinchChatSDK()
    
    let pushNotificationHandler: PushNotificationHandler = DefaultPushNotificationHandler()
    lazy var _chat = DefaultSinchChat(pushPermissionHandler: pushNotificationHandler)

    public var disabledFeatures: Set<SinchEnabledFeatures> = []
    
    var options: SinchInitializeOptions?
    
    private(set) var config: SinchSDKConfig.AppConfig? {
        didSet {
            _chat.region = config?.region
        }
    }
    var authDataSource: AuthDataSource? {
        didSet {
            pushNotificationHandler.authDataSource = authDataSource
            _chat.authDataSource = authDataSource
        }
    }
    var apiClient: APIClient? {
        didSet {
            pushNotificationHandler.apiClient = apiClient
            _chat.apiClient = apiClient
        }
    }
    
    public var additionalMetadata: SinchMetadataArray = []
    public lazy var eventListenerSubject = PassthroughSubject<SinchPluginEvent, Never>()
    public lazy var customMessageTypeHandlers: [(_ model: Message) -> Message?] = []
    public lazy var customMessageTypeHandlersAsync: [(Message, @escaping (Message?) -> Void) -> Void] = []
    
    private init() {}
    
    /// Initialization of SinchSDK
    /// - Parameters:
    ///   - Parameter options: Run sdk with options f.e: using sandbox push notification environment.
    public func initialize(_ options: SinchInitializeOptions = SinchInitializeOptions.standard) {
        if options.pushNotificationsMode != .off {
            registerForRemoteNotificationIfNeeded()
            setPushRepositoryIfPossible()
        }
        if options.plugins.isEmpty == false {
            options.plugins.forEach({ $0.initialize(methods: self) })
        }
        self.options = options
        
    }
    
    /// Sets identity of the user.
    /// This method must be called `as soon as` we can authorize the user.
    /// Calling this method once again causes the token will be `regenerated`.
    /// If the type of token is different than current one. Example: anonymous vs signed -> token `will be` regenerated.
    /// - Parameters:
    ///   - Parameter config: Configuration of sdk.
    ///   - identity: The way of user authorization.
    ///   - completion: Callback with result of user authorization.
    public func setIdentity(with config: SinchSDKConfig.AppConfig, identity: SinchSDKIdentity,
                            completion: (@Sendable (Result<Void, SinchSDKIdentityError>) -> Void)? = nil) {
        self.config = config
        let newApiClient = Default2APIClient(region: config.region)!
        apiClient = newApiClient
        let keychainStorage = KeychainAuthStorage(config: config)
        _ = AuthStorageMigrator(keychainStorage: keychainStorage)
        authDataSource = DefaultAuthDataSource(
            authRepository: DefaultAuthRepository(
                config: config,
                client: newApiClient
            ),
            authStorage: keychainStorage
        )

        let capturedCompletion = completion
        authDataSource?.generateToken(config: config, identity: identity, completion: { result in
            self.setPushRepositoryIfPossible()

            switch result {
            case .failure(let error):
                switch error {
                case .internalError(tracingID: let tracingID):
                    capturedCompletion?(.failure(.internalError(tracingID: tracingID)))
                default:
                    capturedCompletion?(.failure(.internalError(tracingID: "unknown")))
                }
            case .success(let token):
                SinchChatSDK.shared.eventListenerSubject.send(.didSetIdentity(token))
                self.reinitializeChat()

                capturedCompletion?(.success(()))

            }
        })
    }
    
    /// Removes identity of the user.
    /// This method is logging out user. It removes token and other user data from the app.
    public func removeIdentity(_ completion: (@Sendable (Result<Void, Error>) -> Void)?) {
        
        guard let authDataSource = authDataSource else {
            completion?(.success(()))
            return
        }
        let currentAuthDataSource = authDataSource
        let tempPushNottifications = DefaultPushNotificationHandler()
        tempPushNottifications.authDataSource = authDataSource
        tempPushNottifications.pushRepository = DefaultPushRepository(region: config?.region ?? .EU1,
                                                                      authDataSource: authDataSource)
        tempPushNottifications.unsubscribe { result in
            switch result {
            case .success:
                currentAuthDataSource.deleteToken()
                SinchChatSDK.shared.eventListenerSubject.send(.didRemoveIdentity)

                completion?(.success(()))
            case .failure(let error):
                completion?(.failure(error))
            }
        }
    }
    // MARK: - Private
    
    private func registerForRemoteNotificationIfNeeded() {
        if !UIApplication.shared.isRegisteredForRemoteNotifications {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
    
    private func setPushRepositoryIfPossible() {
        guard let authDataSource = authDataSource, authDataSource.isLoggedIn, let config = config else {
            return
        }
        Logger.verbose("--------- SET PUSH REPOSITORY")
        pushNotificationHandler.pushRepository = DefaultPushRepository(region: config.region,
                                                                       authDataSource: authDataSource)
    }
    
    private func reinitializeChat() {
             
        _chat.initilize()

    }
    
    static var version: String {
        "0.1.18" + (SinchChatSDK.shared.options?.pushNotificationsMode == .prod ? "-prod" : "-dev")
    }
}

public enum SinchSDKIdentity: Codable, Equatable, Sendable {
    /// Creates anonymous session with random user identifier.
    case anonymous
    /// Creates session with a specific user identifier using a pre-computed
    /// HMAC-SHA512(uuid, appSecret) digest as `secret`. Retained for
    /// backwards compatibility with existing integrations.
    case selfSigned(userId: String, secret: String)
    /// Creates session with a specific user identifier. The SDK computes
    /// HMAC-SHA512(uuid, appSecret) internally so host apps never handle
    /// the hash directly. The raw `appSecret` is held in memory only for
    /// the duration of `setIdentity` and is not persisted.
    case selfSignedWithAppSecret(userId: String, appSecret: String)
}

public enum SinchSDKIdentityError: Error {
    /// Our internal issue.
    case internalError(tracingID: String)
    /// Secret is invalid. Make sure it is generated correctly.
    case invalidSecret
}

public struct SinchInitializeOptions: Sendable {
    public var pushNotificationsMode: SinchPushNotificationsMode = .prod
    public var plugins: [SinchPlugin] = []

    public static let standard = SinchInitializeOptions(pushNotificationMode: .prod)

    public init(pushNotificationMode: SinchPushNotificationsMode, plugins: [SinchPlugin] = []) {
        self.pushNotificationsMode = pushNotificationMode
        self.plugins = plugins
    }
}

public enum SinchPushNotificationsMode: Sendable {
    case prod
    case sandbox
    case off
    
}
public enum SinchEnabledFeatures {
    case sendImageMessageFromGallery
    case sendVideoMessageFromGallery
    case sendVoiceMessage
    case sendLocationSharingMessage
    case sendImageFromCamera
    case sendVideoMessageFromCamera
    case sendDocuments

}
