//  ReportModels.swift — the value types the report path shares between the app
//  and the Notification Service Extension.
//
//  This directory is compiled into BOTH pods (react-native-sinch-push and
//  SinchPushNotificationExtension), so it must stay Foundation-only: no React,
//  no UIKit, no UserNotifications, and only APIs that are extension-safe.

import Foundation

/// A provider push whose DELIVERED report has to reach the push API.
struct ReportEntry: Codable, Hashable, Sendable {
  var messageId: String
  var subscriberId: String
  /// Epoch milliseconds the push was seen at.
  var enqueuedAtMs: Int64

  var key: ReportKey { ReportKey(messageId: messageId, subscriberId: subscriberId) }

  static func == (lhs: ReportEntry, rhs: ReportEntry) -> Bool { lhs.key == rhs.key }
  func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

struct ReportKey: Codable, Hashable, Sendable {
  var messageId: String
  var subscriberId: String
}

/// How a Sinch push names its message (the same keys `PushMessageIdentity` reads in the app).
enum ProviderPush {
  static let messageIdKey = "sinch.push.message_id"
  static let subscriberIdKey = "sinch.push.subscriber_id"

  /// The report a push asks for: both keys, non-empty. Anything else is not a Sinch provider push.
  static func entry(from userInfo: [AnyHashable: Any], nowMs: Int64) -> ReportEntry? {
    guard let messageId = userInfo[messageIdKey] as? String, !messageId.isEmpty,
      let subscriberId = userInfo[subscriberIdKey] as? String, !subscriberId.isEmpty
    else { return nil }
    return ReportEntry(messageId: messageId, subscriberId: subscriberId, enqueuedAtMs: nowMs)
  }
}

/// The minimal credential the app mirrors for native / extension uploads.
/// Never carries the HMAC secret: only the JWT the push API already accepts.
struct SharedReportSession: Codable, Equatable, Sendable {
  var accessToken: String
  /// The push API base URL, e.g. `https://grpc.sinch-push.prod.sinch.com`.
  var reportBaseURL: String
  var userId: String
  var appId: String

  init(accessToken: String, reportBaseURL: String, userId: String = "", appId: String = "") {
    self.accessToken = accessToken
    self.reportBaseURL = reportBaseURL
    self.userId = userId
    self.appId = appId
  }

  /// `nil` unless both the token and the base URL are present strings.
  init?(dictionary: [AnyHashable: Any]) {
    guard let token = dictionary["accessToken"] as? String, !token.isEmpty,
      let base = dictionary["reportBaseURL"] as? String, !base.isEmpty
    else { return nil }
    self.init(
      accessToken: token, reportBaseURL: base,
      userId: dictionary["userId"] as? String ?? "",
      appId: dictionary["appId"] as? String ?? "")
  }

  /// A token whose `exp` has passed (or is about to) is not worth an upload: the
  /// push API would answer Unauthenticated. No `exp` claim: usable.
  func isUsable(nowMs: Int64, leewayMs: Int64 = 30_000) -> Bool {
    guard ReportWire.endpoint(baseURL: reportBaseURL) != nil else { return false }
    guard let expiresAtMs = JWTExpiry.expiresAtMs(accessToken) else { return true }
    return expiresAtMs - leewayMs > nowMs
  }
}

enum JWTExpiry {
  /// The `exp` claim in epoch milliseconds, or `nil` when the token has none / is not a JWT.
  static func expiresAtMs(_ token: String) -> Int64? {
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let exp = (object["exp"] as? NSNumber)?.doubleValue
    else { return nil }
    return Int64(exp * 1000)
  }
}

func currentTimeMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
