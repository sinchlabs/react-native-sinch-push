import SinchPushNotificationExtension
import UserNotifications

/// Notification Service Extension: hands the push to the Sinch SDK (which
/// uploads the delivery/display report from the extension process) and then
/// delivers the notification.
class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

    // The App Group comes from Config.xcconfig (APP_GROUP) through Info.plist.
    let appGroup = Bundle.main.object(forInfoDictionaryKey: "SinchAppGroup") as? String ?? ""
    let handedUpload = SinchPushNotificationExtension.didReceive(request, appGroup: appGroup)
    NSLog("[NSE] didReceive handed upload to the system: %@", handedUpload ? "true" : "false")

    if let content = bestAttemptContent {
      contentHandler(content)
    }
  }

  override func serviceExtensionTimeWillExpire() {
    if let contentHandler, let content = bestAttemptContent {
      contentHandler(content)
    }
  }
}
