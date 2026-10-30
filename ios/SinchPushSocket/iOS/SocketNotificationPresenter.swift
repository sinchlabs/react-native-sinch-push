//  SocketNotificationPresenter.swift — the local notification for a socket
//  message, and the category that turns a dismissal into DISMISSED
//  (RN-019, SB-30).
//
//  Two things happen here that the client cannot do for itself:
//
//    * Posting reports DISPLAYED (SB-30). The completion handler is what makes
//      that honest: a request the notification centre refuses is not a
//      notification the user saw, so nothing is reported.
//    * `sinchpush.socket` is registered with
//      `UNNotificationCategoryOptionCustomDismissAction`, which is what delivers
//      `UNNotificationDismissActionIdentifier` when the user swipes the banner
//      away. That is the iOS equivalent of Android's `deleteIntent` (RN-013) and
//      it is the only way DISMISSED can be reported for a notification the app
//      never saw again.
//
//  The category is *merged* with whatever the host already registered rather
//  than replacing the set, and `willPresent` is answered for socket messages
//  only, so this does not change how a host's own APNs notifications behave.
//
//  `#if os(iOS)` throughout. `UserNotifications` *does* exist on macOS, with a
//  different (synchronous) category API, so `canImport` is not the right guard —
//  the file is iOS-only and its rules are exercised in the conformance suite
//  through the ``NotificationPresenting`` seam instead.

import Foundation

#if os(iOS)
import UserNotifications

/// The category id for socket notifications. `SinchPush.mm` and the Swift
/// presenter must agree on it, and it is part of the notification's
/// `userInfo`, so a dismiss action can be traced back to a pooled message.
let kSinchPushSocketNotificationCategory = "sinchpush.socket"

/// The `userInfo` keys a socket notification carries (RN-019).
enum SocketNotificationUserInfoKey {
  static let messageId = "messageId"
  static let sinchMessageId = "sinchMessageId"
  static let source = "source"
  static let socketSource = "socket"
}

/// Posts socket notifications and turns dismissal into DISMISSED.
final class SocketNotificationPresenter: NSObject, NotificationPresenting {
  var handlerRegistered: Bool = false

  /// Called for a dismissed socket notification (RN-019).
  var onDismissed: ((String) -> Void)?
  /// Called when a socket notification is opened (RN-019). The default action is
  /// the host's business — this only routes it, because only the dismiss action
  /// produces a report.
  var onOpened: ((String) -> Void)?

  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
    super.init()
  }

  // MARK: - Posting

  func post(
    _ message: SocketMessageEvent, alerting: Bool, completion: @escaping (Bool) -> Void
  ) {
    registerCategory()

    let content = UNMutableNotificationContent()
    // SB-36: an absent title is not an empty title. iOS renders the app name in
    // that case, which is what the Android background service does with the same
    // message, so the two transports agree.
    if let title = message.title { content.title = title }
    if let body = message.body { content.body = body }
    // SB-63: the pure mapping (thread, sound, passive) lives in
    // `SocketNotificationStyle`; this only applies it.
    let style = SocketNotificationStyle(alerting: alerting, trigger: message.trigger)
    content.threadIdentifier = style.threadIdentifier
    if style.playsSound {
      content.sound = .default
    } else {
      content.sound = nil
    }
    if style.passive, #available(iOS 15.0, *) {
      // `.passive` where the system has it, so it does not light the screen.
      content.interruptionLevel = .passive
    }
    // The category is what gives the notification a dismiss action at all.
    content.categoryIdentifier = kSinchPushSocketNotificationCategory
    var userInfo: [String: Any] = message.metadata
    userInfo[SocketNotificationUserInfoKey.messageId] = message.id
    userInfo[SocketNotificationUserInfoKey.sinchMessageId] = message.sinchMessageId
    userInfo[SocketNotificationUserInfoKey.source] = SocketNotificationUserInfoKey.socketSource
    content.userInfo = userInfo

    // SB-65: the identifier *is* the message id — the same string sinch-push
    // sets as `apns-collapse-id` — so an APNs copy and this local copy replace
    // each other in the notification centre instead of stacking. That the
    // notification is the socket's is `userInfo["source"]`, never a prefix of
    // the identifier.
    let request = UNNotificationRequest(
      identifier: socketNotificationIdentifier(messageId: message.id),
      content: content, trigger: nil)
    center.add(request) { error in
      // Only an accepted request counts as shown: DISPLAYED claims the user saw
      // something (SB-30), and a refused request shows nothing.
      completion(error == nil)
    }
  }

  // MARK: - Category

  /// Register `sinchpush.socket`, keeping every category the host already has.
  ///
  /// `getNotificationCategoriesWithCompletionHandler:` then `setNotificationCategories:`
  /// rather than a bare set, because a host that registered its own categories
  /// before this ran would otherwise find them all gone — a silent, app-wide
  /// regression from a push SDK.
  func registerCategory() {
    center.getNotificationCategories { [weak self] existing in
      guard let self else { return }
      let category = UNNotificationCategory(
        identifier: kSinchPushSocketNotificationCategory,
        actions: [],
        intentIdentifiers: [],
        // The whole point of the category: without this the system never calls
        // the response delegate for a swipe, and DISMISSED is unreportable.
        options: [.customDismissAction])
      var merged = existing.filter { $0.identifier != kSinchPushSocketNotificationCategory }
      merged.insert(category)
      self.center.setNotificationCategories(merged)
    }
  }

  // MARK: - Response handling

  /// RN-019: a dismiss action becomes DISMISSED (queued in the outbox when the
  /// socket is suspended), and the default action becomes an open.
  func handle(response: UNNotificationResponse) {
    let info = response.notification.request.content.userInfo
    let messageId = info[SocketNotificationUserInfoKey.messageId] as? String
    let source = info[SocketNotificationUserInfoKey.source] as? String
    guard source == SocketNotificationUserInfoKey.socketSource else {
      // Not ours: the host's own notification. Left alone on purpose — this
      // presenter is not the notification centre's delegate.
      return
    }
    switch response.actionIdentifier {
    case UNNotificationDismissActionIdentifier:
      guard let messageId else { return }
      onDismissed?(messageId)
    case UNNotificationDefaultActionIdentifier:
      guard let messageId else { return }
      onOpened?(messageId)
    default:
      break
    }
  }

  /// RN-031: show the banner for a socket notification while the app is in the
  /// foreground. Everything else is `[]`, so the host's own behaviour for its
  /// own notifications is untouched.
  func willPresent(options: UNNotificationPresentationOptions) -> UNNotificationPresentationOptions {
    if #available(iOS 14.0, *) {
      return [.banner, .list, .sound]
    }
    return [.alert, .sound]
  }
}

/// Answers "is this id already in the notification centre" from
/// `getDeliveredNotifications` (SB-65).
final class SystemDeliveredNotificationLookup: DeliveredNotificationLookup {
  private let center: UNUserNotificationCenter

  init(center: UNUserNotificationCenter = .current()) {
    self.center = center
  }

  func isDelivered(identifier: String, completion: @escaping (Bool) -> Void) {
    center.getDeliveredNotifications { delivered in
      completion(delivered.contains { $0.request.identifier == identifier })
    }
  }
}
#endif