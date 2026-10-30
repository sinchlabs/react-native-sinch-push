//  SocketTypes.swift — the vocabulary the socket client speaks (RN-032).
//
//  Pure Swift + Foundation, like FrameCodec.swift, and for the same reason: this
//  file is compiled by CocoaPods inside a host app and by
//  ios/SinchPushSocketTests under `swift test`, so it may not import React,
//  UIKit or anything else the test host does not have. The iOS-only glue
//  (UIApplication lifecycle, UNUserNotificationCenter, Keychain) lives beside it
//  in `iOS/`, guarded, so the rules in docs/socket-behaviour-spec.md can be
//  exercised without a device.
//
//  Behaviour, not this file, is normative: docs/socket-behaviour-spec.md
//  (RN-035), rules SB-18 … SB-58. Each type below names the rules that shape it
//  so a reader can check one claim in two places rather than three.

import Foundation

// MARK: - Configuration

/// When a socket message should also be surfaced as a local notification.
///
/// Mirrors the three values RN-008 puts on `socket.displayNotifications`, and
/// implements the display rule of RN-031 (`whenUnhandled` is the default).
enum SocketDisplayRule: String, Sendable, Equatable, CaseIterable {
  /// Post only when the host app has not registered an in-app handler.
  case whenUnhandled
  /// Always post.
  case always
  /// Never post; the message is only an event.
  case never
}

/// Everything the client needs for one connection (SB-18).
///
/// The defaults here are the iOS values of SB-19 / SB-57 and are deliberately
/// not configurable from `background`:
///
///   * `platform` is `.ios` because this *is* the iOS client — it is not
///     derived from the `background` flag, which would make one flag control
///     two independent things.
///   * `background` is not a field at all. SB-57 requires `false` on the iOS
///     path and there is no surface on which that could be anything else, so
///     ``SocketClient`` writes `false` into `Hello` unconditionally.
///
/// The token is the only secret here and it never reaches the persisted store
/// (``SocketStateStore``); ``AuthTokenStore`` keeps it.
struct SocketConfiguration: Sendable, Equatable {
  /// Full WebSocket URL. `ws://` for local development, `wss://` in production.
  var url: String

  /// The sinch-chat JWT the relay verifies. Non-empty; SB-18 requires it.
  var authToken: String

  /// JWT-derived, with the config value as the fallback.
  var projectID: String

  /// JWT-derived.
  var appID: String

  /// JWT `uuid`.
  var userID: String

  /// Debug override for the poll cadence; `<= 0` means "let the server decide"
  /// (SB-22). Never read as a floor — the *result* is raised to 1000 ms.
  var pollIntervalMs: Int

  /// RN-031 display rule.
  var displayNotifications: SocketDisplayRule

  /// `Hello.sdk_version` (SB-19), passed in from the JS config map. `nil` falls
  /// back to ``defaultSDKVersion``.
  var sdkVersion: String?

  init(
    url: String,
    authToken: String,
    projectID: String,
    appID: String,
    userID: String,
    pollIntervalMs: Int = 0,
    displayNotifications: SocketDisplayRule = .whenUnhandled,
    sdkVersion: String? = nil
  ) {
    self.url = url
    self.authToken = authToken
    self.projectID = projectID
    self.appID = appID
    self.userID = userID
    self.pollIntervalMs = pollIntervalMs
    self.displayNotifications = displayNotifications
    self.sdkVersion = sdkVersion
  }

  /// `Hello.sdk_version` (SB-19): `"rn-sinch-push/<version>"`.
  ///
  /// The version is **passed in from the JS config map** (`sdkVersion`), which
  /// is where a build-time injected version belongs. This constant is the
  /// fallback for a config that omits it, and `SocketSDKVersionTests` pins it
  /// against `package.json`, so it cannot drift silently.
  static let defaultSDKVersion = "rn-sinch-push/1.1.0"

  /// SB-19: the OS, not the `background` flag. See the type comment.
  static let platform = Sinch_Push_Delivery_V1beta1_Ws_Platform.ios

  /// The `sdk_version` actually put on the wire.
  var resolvedSDKVersion: String {
    SocketConfiguration.resolveSDKVersion(sdkVersion)
  }

  /// The override if it is non-empty, otherwise ``defaultSDKVersion`` — the one
  /// place that decision is made (SB-59).
  static func resolveSDKVersion(_ override: String?) -> String {
    guard let override, !override.isEmpty else { return defaultSDKVersion }
    return override
  }

  /// The shape persisted across a client restart: everything but the token,
  /// which lives in ``AuthTokenStore``.
  var persistable: PersistedSocketConfiguration {
    PersistedSocketConfiguration(
      url: url,
      projectID: projectID,
      appID: appID,
      userID: userID,
      pollIntervalMs: pollIntervalMs,
      displayNotifications: displayNotifications,
      sdkVersion: sdkVersion)
  }
}

/// ``SocketConfiguration`` without the credential, so it can be written to
/// `UserDefaults` or a file without leaking a JWT into a plist.
struct PersistedSocketConfiguration: Sendable, Codable, Equatable {
  var url: String
  var projectID: String
  var appID: String
  var userID: String
  var pollIntervalMs: Int
  var displayNotifications: String
  var sdkVersion: String?

  init(
    url: String,
    projectID: String,
    appID: String,
    userID: String,
    pollIntervalMs: Int,
    displayNotifications: SocketDisplayRule,
    sdkVersion: String?
  ) {
    self.url = url
    self.projectID = projectID
    self.appID = appID
    self.userID = userID
    self.pollIntervalMs = pollIntervalMs
    self.displayNotifications = displayNotifications.rawValue
    self.sdkVersion = sdkVersion
  }

  /// Rebuild the config from persisted state plus a token from the Keychain.
  /// `nil` when the stored rule is no longer one this build understands, which
  /// is treated as "start from the default" rather than as a hard failure.
  func configuration(authToken: String) -> SocketConfiguration {
    SocketConfiguration(
      url: url,
      authToken: authToken,
      projectID: projectID,
      appID: appID,
      userID: userID,
      pollIntervalMs: pollIntervalMs,
      displayNotifications: SocketDisplayRule(rawValue: displayNotifications) ?? .whenUnhandled,
      sdkVersion: sdkVersion)
  }
}

// MARK: - State

/// `PushSocketState.status` (SB-24).
///
/// `authRequired` and `replaced` are the resolved OPEN-6 values: a single
/// `error` / `stopped` vocabulary cannot tell a host "the relay refused our
/// token" apart from "another surface took the session". Both are distinct
/// here.
enum SocketStatus: String, Sendable, Equatable, CaseIterable {
  case idle
  case connecting
  case connected
  case reconnecting
  case error
  case stopped
  /// SB-48: `Close(UNAUTHORIZED)`. Terminal until the credential is refreshed;
  /// one `onAuthRequired` attempt is made first.
  case authRequired = "auth_required"
  /// SB-49: `Close(BG_RESUMED)`. Another surface owns the session.
  case replaced
}

/// The published state surface (SB-24).
struct SocketState: Sendable, Equatable {
  var status: SocketStatus
  /// `native` on both platforms since the socket moved out of JS.
  var transport: String = "native"
  var connectionId: String = ""
  var pollIntervalMs: Int = SocketClient.defaultPollIntervalMs
  var reconnectAttempts: Int = 0
  /// Cleared on every new connection attempt (SB-24); carries a `Close`
  /// frame's detail, or a `server closed (reason=n)` form when it had none.
  var lastError: String?

  var dictionary: [String: Any] {
    var out: [String: Any] = [
      "status": status.rawValue,
      "transport": transport,
      "connectionId": connectionId,
      "pollIntervalMs": pollIntervalMs,
      "reconnectAttempts": reconnectAttempts,
    ]
    if let lastError {
      out["lastError"] = lastError
    }
    return out
  }
}

// MARK: - Messages

/// One delivered pooled message, as the JS facade's `PushSocketMessage`.
///
/// SB-36 is honoured in the optional text fields: a proto3 string carries no
/// presence, so an explicitly empty `title` is reported as absent rather than
/// as `""`, which is what the Android background service already does with the
/// same message (`title?.takeIf { it.isEmpty == false } ?: appLabel`).
struct SocketMessageEvent: Sendable, Codable, Equatable {
  /// `PooledMessage.message_id` — the dedupe key (SB-25).
  var id: String
  var sinchMessageId: String
  var ackToken: String
  var title: String?
  var body: String?
  var imageUrl: String?
  var metadata: [String: String]
  var importance: Int
  var trigger: String?
  var enqueuedAt: Int64
  var receivedAt: Int64
  /// Always `false` on iOS: the socket is foreground-only (SB-56).
  var background: Bool
  /// True once a local notification has been posted for this message, which is
  /// also the moment DISPLAYED is reported (SB-30).
  var shown: Bool

  /// SB-36: absent is `nil`, never `""`.
  init(pooled: Sinch_Push_Delivery_V1beta1_Ws_PooledMessage, ackToken: String, receivedAt: Int64) {
    let notification = pooled.hasPushNotification ? pooled.pushNotification : nil
    let alert = notification?.alert
    self.id = pooled.messageID
    self.sinchMessageId = pooled.sinchMessageID
    self.ackToken = ackToken
    self.title = SocketMessageEvent.absentIfEmpty(alert?.title ?? "")
    self.body = SocketMessageEvent.absentIfEmpty(alert?.message ?? "")
    self.imageUrl = SocketMessageEvent.absentIfEmpty(alert?.imageURL ?? "")
    self.metadata = notification?.metadata ?? [:]
    self.importance = notification?.importance.rawValue ?? 0
    self.trigger = SocketMessageEvent.absentIfEmpty(notification?.trigger ?? "")
    self.enqueuedAt = pooled.enqueuedAtUnixMillis
    self.receivedAt = receivedAt
    self.background = false
    self.shown = false
  }

  /// `""` means "nobody typed this", so it maps to absent (SB-36). A populated
  /// value — including astral-plane text — arrives intact.
  static func absentIfEmpty(_ value: String) -> String? {
    value.isEmpty ? nil : value
  }

  /// The `PushSocketMessage` shape `src/pushSocket/types.ts` expects.
  var dictionary: [String: Any] {
    var out: [String: Any] = [
      "id": id,
      "sinchMessageId": sinchMessageId,
      "ackToken": ackToken,
      "metadata": metadata,
      "importance": importance,
      "enqueuedAt": enqueuedAt,
      "receivedAt": receivedAt,
      "background": background,
      "shown": shown,
    ]
    if let title { out["title"] = title }
    if let body { out["body"] = body }
    if let imageUrl { out["imageUrl"] = imageUrl }
    if let trigger { out["trigger"] = trigger }
    return out
  }
}

// MARK: - Delivery status

/// The four statuses the SDK reports (SB-30).
enum SocketDeliveryStatus: String, Sendable, Codable, Equatable, CaseIterable {
  case delivered
  case displayed
  case dismissed
  case failed

  /// The proto enum, and — for the Ack token — its **numeric** value.
  /// `DELIVERED = 1`, `DISPLAYED = 2`, `FAILED = 3`, `DISMISSED = 4`.
  var proto: Sinch_Push_Delivery_V1beta1_Ws_DeliveryReport.Status {
    switch self {
    case .delivered: return .delivered
    case .displayed: return .displayed
    case .dismissed: return .dismissed
    case .failed: return .failed
    }
  }

  /// SB-32: `Ack.ack_token` is `"<message_id>:<number>"`, never the word.
  var tokenSuffix: String { String(proto.rawValue) }

  /// The two statuses a host may report on its own (RN-004's public API).
  static func hostReportable(_ rawValue: String) -> SocketDeliveryStatus? {
    switch rawValue.lowercased() {
    case "displayed": return .displayed
    case "dismissed": return .dismissed
    default: return nil
    }
  }
}

/// One queued or in-flight `DeliveryReport`.
///
/// `messageId` is the pooled id and never empty (SB-31): the relay refuses a
/// report without one as `missing_message_id`, so a failure that cannot name
/// its message is logged rather than sent.
struct PendingReport: Sendable, Codable, Equatable {
  var messageId: String
  var sinchMessageId: String
  var status: SocketDeliveryStatus
  var reason: String
  /// Bounded retry counter for `upstream_forward_failed` (SB-33).
  var attempts: Int
  /// Set by a `rate_limited` rejection: the earliest millisecond this entry may
  /// be sent again (SB-33). Not a poll tick — the poll tick is what the relay
  /// is throttling.
  var deferUntilMs: Int64?

  /// The token the relay will echo back (SB-32). Constructed, never parsed.
  var ackToken: String { "\(messageId):\(status.tokenSuffix)" }

  /// The idempotency key for "already reported" (SB-30).
  var sentKey: String { "\(messageId):\(status.tokenSuffix)" }

  func deliveryReport(reportedAtMs: Int64) -> Sinch_Push_Delivery_V1beta1_Ws_DeliveryReport {
    var report = Sinch_Push_Delivery_V1beta1_Ws_DeliveryReport()
    report.messageID = messageId
    report.sinchMessageID = sinchMessageId
    report.status = status.proto
    report.reason = reason
    report.reportedAtUnixMillis = reportedAtMs
    return report
  }
}

// MARK: - Report outbox

/// One queued provider-push report.
struct ReportOutboxEntry: Sendable, Codable, Equatable {
  /// `sinch.push.message_id`: the relay's message id.
  var messageId: String
  /// `sinch.push.subscriber_id`: the subscriber the push was addressed to.
  var subscriberId: String
  /// When the entry was queued, in epoch milliseconds.
  var enqueuedAtMs: Int64
}
