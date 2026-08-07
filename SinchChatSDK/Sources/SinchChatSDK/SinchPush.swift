import Foundation
import UserNotifications
import Combine

public typealias IsHandled = Bool

@MainActor
public protocol SinchPush {
    
    /// Sends device token to specific identity.
    /// - Parameters:
    ///     - token: token which is coming from method: `application(_:, didRegisterForRemoteNotificationsWithDeviceToken:)`
    func sendDeviceToken(_ token: Data)

    /// Handles notification payload.
    /// - Returns: Information whenether the notification belongs to Sinch Chat SDK or not.
    func handleNotification(_ payload: [AnyHashable: Any]) -> IsHandled
    
    /// Handles notification response payload.
    /// - Returns: Information whenether the notification belongs to Sinch Chat SDK or not.
    func handleNotificationResponse(_ notificationResponse: UNNotificationResponse) -> IsHandled
    
    /// Handles notification will present payload.
    /// - Returns: Presentation options for specifig notification if notification belongs to us.
    func handleWillPresentNotification(_ notification: UNNotification) -> UNNotificationPresentationOptions?

    /// Asks user for notification permission.
    /// - Parameters:
    ///     - completion: Contains information about notification status.
    func askNotificationPermission(completion: @escaping (SinchSDKNotificationStatus) -> Void)

    /// Checks notification permission status.
    /// - Parameters:
    ///     - completion: Contains information about notification status.
    func checkPushPermission(completion: @escaping (SinchSDKNotificationStatus) -> Void)

    /// Asks user for notification permission.
    /// - Returns: Contains information about notification status.
    @available(iOS 13.0, *)
    func askNotificationPermission() -> AnyPublisher<SinchSDKNotificationStatus, Never>

    /// Checks notification permission status.
    /// - Returns: Contains information about notification status.
    @available(iOS 13.0, *)
    func checkPushPermission() -> AnyPublisher<SinchSDKNotificationStatus, Never>
    
}

@MainActor
final class DefaultSinchPush: SinchPush {
    private let pushNotificationhandler: PushNotificationHandler
    private lazy var inAppMessageController = DefaultInAppMessageController(pushNotificationHandler: pushNotificationhandler )

    init(pushNotificationHandler: PushNotificationHandler) {
        self.pushNotificationhandler = pushNotificationHandler
    }

    func sendDeviceToken(_ token: Data) {
        pushNotificationhandler.sendDeviceToken(token: token)
    }

    func handleNotification(_ payload: [AnyHashable : Any]) -> IsHandled {
        Logger.debug(payload)
        
        if inAppMessageController.showInAppMessage(messagePayload: payload) {
            return true
        }
        
        return pushNotificationhandler.handleNotification(payload: payload)
    }

    func handleWillPresentNotification(_ notification: UNNotification) -> UNNotificationPresentationOptions? {
        let payload = notification.request.content.userInfo
        Logger.debug(payload)
        return pushNotificationhandler.handleWillPresentNotification(payload)
    }

    func handleNotificationResponse(_ notificationResponse: UNNotificationResponse) -> IsHandled {
        let payload = notificationResponse.notification.request.content.userInfo
        Logger.debug(payload)
        return pushNotificationhandler.handleNotification(payload: payload)
    }

    func checkPushPermission(completion: @escaping (SinchSDKNotificationStatus) -> Void) {
        pushNotificationhandler.checkIfPermissionIsGranted(completion: completion)
    }

    @available(iOS 13.0, *)
    func checkPushPermission() -> AnyPublisher<SinchSDKNotificationStatus, Never> {

        let subject = PassthroughSubject<SinchSDKNotificationStatus, Never>()

        checkPushPermission { status in
            subject.send(status)
        }

        return subject.eraseToAnyPublisher()
    }

    @available(iOS 13.0, *)
    func askNotificationPermission() -> AnyPublisher<SinchSDKNotificationStatus, Never> {

        let subject = PassthroughSubject<SinchSDKNotificationStatus, Never>()

        askNotificationPermission { status in
            subject.send(status)
        }

        return subject.eraseToAnyPublisher()
    }

    func askNotificationPermission(completion: @escaping (SinchSDKNotificationStatus) -> Void) {
        pushNotificationhandler.askForPermissions { status in
            completion(status)
        }
    }
}

public enum SinchSDKNotificationStatus {
    /// Notification permission is already granted.
    case granted
    /// Notification permiossion was previously asked but now is denied, user must change it in settings.
    case denied
    /// Notification permission has not been asked yes.
    case notDetermined
}
