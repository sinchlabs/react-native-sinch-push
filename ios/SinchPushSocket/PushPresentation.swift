//  PushPresentation.swift — what the push path does with an APNs notification,
//  decided without UserNotifications (RN-045, SB-64).
//
//  `SinchPush.mm`'s `willPresentNotification:` and
//  `+didReceiveRemoteNotification:` are ObjC++ and cannot be unit-tested, so the
//  decision lives here and they only act on it.

import Foundation

/// How a Sinch push names its message.
enum PushMessageIdentity {
  /// The key sinch-push puts in the push metadata (so in the APNs custom
  /// payload and the FCM `data`). Its value is the trackingId, which is the
  /// relay's `PooledMessage.message_id`.
  static let metadataKey = "sinch.push.message_id"
  /// The subscriber the push was addressed to.
  static let subscriberIdKey = "sinch.push.subscriber_id"
  /// Every key sinch-push adds to the metadata starts with this.
  static let metadataKeyPrefix = "sinch.push."

  /// The id to dedupe on, or `nil` — and `nil` means *no dedupe*: a sinch-push
  /// payload with no id is handled as it always was.
  ///
  /// `sinch.push.message_id` wins. When it is absent the fallback is the
  /// request identifier, which for a remote notification is the
  /// `apns-collapse-id` (= message_id for new SDKs) — but only when the payload
  /// is recognisably a Sinch push (it carries some `sinch.push.*` key) **and**
  /// the identifier is not a UUID. A host's own APNs push has a system-assigned
  /// or app-chosen identifier that means nothing to us, and treating it as a
  /// message id could swallow an unrelated notification; the UUID check covers
  /// the system-assigned form. Deliberately narrow: a missed dedupe costs a
  /// duplicate banner, a wrong one costs a lost message.
  static func messageId(
    userInfo: [AnyHashable: Any], requestIdentifier: String?
  ) -> String? {
    if let id = userInfo[metadataKey] as? String, !id.isEmpty { return id }
    guard let identifier = requestIdentifier, !identifier.isEmpty,
      UUID(uuidString: identifier) == nil,
      userInfo.keys.contains(where: { ($0 as? String)?.hasPrefix(metadataKeyPrefix) == true })
    else { return nil }
    return identifier
  }

  /// A local notification the socket posted itself (`userInfo["source"]`).
  static func isSocketOriginated(userInfo: [AnyHashable: Any]) -> Bool {
    (userInfo["source"] as? String) == "socket"
  }
}

/// The `UNNotificationRequest` identifier of a socket notification: the message
/// id itself (SB-65). sinch-push sets `apns-collapse-id` to the same value, so
/// an APNs copy and the socket's local copy replace each other in the
/// notification centre. That a notification is the socket's is
/// `userInfo["source"]`, never a prefix of this.
func socketNotificationIdentifier(messageId: String) -> String { messageId }

enum PushPresentationDecision: Equatable {
  /// Emit the JS event and show the banner.
  case present
  /// A copy of a message another channel already delivered: no JS event, and
  /// the notification presents nothing.
  case suppress
}

/// The `willPresent` / `didReceiveRemoteNotification` rules over the shared
/// registry.
struct PushPresentationDecider {
  let registry: SeenMessageRegistry
  let outbox: ReportOutbox?
  /// Called once per queued report.
  let onQueued: (() -> Void)?

  init(
    registry: SeenMessageRegistry,
    outbox: ReportOutbox? = nil,
    onQueued: (() -> Void)? = nil
  ) {
    self.registry = registry
    self.outbox = outbox
    self.onQueued = onQueued
  }

  /// An APNs notification arriving while the app is in the foreground.
  ///
  /// - Socket-originated local notifications pass through untouched: the socket
  ///   marked the id *before* presenting, so consulting the registry would call
  ///   its own banner a duplicate.
  /// - No id ⇒ present, no dedupe.
  /// - Id already seen ⇒ suppress. Unseen ⇒ mark it, present.
  func decide(
    userInfo: [AnyHashable: Any], requestIdentifier: String?
  ) -> PushPresentationDecision {
    if PushMessageIdentity.isSocketOriginated(userInfo: userInfo) { return .present }
    guard
      let id = PushMessageIdentity.messageId(
        userInfo: userInfo, requestIdentifier: requestIdentifier)
    else { return .present }
    guard registry.markSeen(id) else { return .suppress }
    queueProviderPushReport(userInfo: userInfo)
    return .present
  }

  /// An APNs notification handed to the app by
  /// `application:didReceiveRemoteNotification:` (background, silent, or a
  /// foreground push on the content-available path). Marks the id so the socket,
  /// once it reconnects, treats its copy as a duplicate, and says whether the
  /// push is a copy (`.suppress`: no JS event).
  ///
  /// One case is not *marked* here: **the app is active and the push has an
  /// alert**. iOS then also calls `willPresent`, which is where that push is
  /// decided — marking it here first would make `willPresent` see it as already
  /// seen and swallow the only copy. It is still *looked up*, without marking: an
  /// id the socket already delivered is a copy, and this path must not emit a JS
  /// event for it (`willPresent` suppresses the banner). An id not seen yet is
  /// `.present`, and `willPresent` marks it. A silent push in the foreground
  /// never reaches `willPresent`, so it is marked here like any other.
  ///
  /// There is no request identifier on this path, so only the metadata key
  /// counts.
  func decideRemoteNotification(
    userInfo: [AnyHashable: Any], appIsActive: Bool
  ) -> PushPresentationDecision {
    guard let id = PushMessageIdentity.messageId(userInfo: userInfo, requestIdentifier: nil)
    else { return .present }
    if appIsActive && Self.hasAlert(userInfo: userInfo) {
      return registry.contains(id) ? .suppress : .present
    }
    guard registry.markSeen(id) else { return .suppress }
    queueProviderPushReport(userInfo: userInfo)
    return .present
  }

  /// Needs both `sinch.push.message_id` (never the request-identifier fallback) and `sinch.push.subscriber_id`.
  private func queueProviderPushReport(userInfo: [AnyHashable: Any]) {
    guard let outbox else { return }
    guard let messageId = userInfo[PushMessageIdentity.metadataKey] as? String, !messageId.isEmpty,
      let subscriberId = userInfo[PushMessageIdentity.subscriberIdKey] as? String,
      !subscriberId.isEmpty
    else { return }
    guard outbox.enqueue(messageId: messageId, subscriberId: subscriberId) else { return }
    onQueued?()
  }

  /// `aps.alert` present as a string or a dictionary: the push is user-visible,
  /// so `willPresent` will be asked about it while the app is active.
  static func hasAlert(userInfo: [AnyHashable: Any]) -> Bool {
    guard let aps = userInfo["aps"] as? [AnyHashable: Any] else { return false }
    return aps["alert"] is String || aps["alert"] is [AnyHashable: Any]
  }
}
