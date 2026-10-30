//  SinchPushReports.swift — the @objc face of the report path for SinchPush.mm.
//
//  SinchPush.mm only translates promise blocks and dictionaries; what the shared
//  files and the background session do lives in Core/ReportCenter.swift.

import Foundation

/// What a background wake gets back from ``SinchPushReports/uploadInBackground(_:)``.
@objc public enum SinchPushBackgroundUpload: Int {
  /// Native could not upload (no mirrored credential): JS has to flush.
  case unavailable = 0
  /// A background URLSession has the reports; the wake can finish now.
  case handedOff = 1
  /// Nothing needs sending.
  case nothingToSend = 2
}

@objc(SinchPushReports)
public final class SinchPushReports: NSObject {
  private static var center: ReportCenter { .live }

  /// `configureSharedReports(appGroup)`.
  @objc public static func configure(appGroup: String?) {
    center.configure(appGroup: appGroup)
  }

  /// `setSharedReportSession(record)`: `nil` clears it.
  @objc public static func setSession(_ record: NSDictionary?) {
    guard let record else {
      center.setSession(nil)
      return
    }
    // An unusable record is no credential: drop the previous one rather than keep the old user's token.
    guard let session = SharedReportSession(dictionary: record as? [AnyHashable: Any] ?? [:]) else {
      center.setSession(nil)
      return
    }
    center.setSession(session)
  }

  /// Reconnects to the background sessions that may hold results (see ``ReportCenter/resumeSessions()``).
  /// Called when the module loads; a no-op once `configure(appGroup:)` ran, which resumes by itself.
  @objc public static func resumeSessions() {
    center.resumeSessionsAtLaunch()
  }

  /// The outbox JS sees: sent and in-flight reports left out, the extension's retries added.
  @objc public static func pendingReports(from outbox: [NSDictionary]) -> [NSDictionary] {
    center.pendingReports(outbox: entries(outbox)).map(dictionary)
  }

  /// Outbox entries that already went out; the caller drops them from the outbox.
  @objc public static func sentReports(from outbox: [NSDictionary]) -> [NSDictionary] {
    center.sentReports(outbox: entries(outbox)).map(dictionary)
  }

  /// JS reported these.
  @objc public static func markReported(_ entries: [NSDictionary]) {
    center.markReported(Self.entries(entries).map(\.key))
  }

  @objc public static func clearRetries() {
    center.clearRetries()
  }

  /// Uploads the outbox with a background URLSession.
  @objc public static func uploadInBackground(_ outbox: [NSDictionary]) -> SinchPushBackgroundUpload {
    SinchPushBackgroundUpload(rawValue: center.uploadInBackground(outbox: entries(outbox)).rawValue) ?? .unavailable
  }

  /// `application:handleEventsForBackgroundURLSession:completionHandler:`.
  @objc public static func handleEvents(
    forBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void
  ) -> Bool {
    center.handleEvents(identifier: identifier, completion: completionHandler)
  }

  private static func entries(_ outbox: [NSDictionary]) -> [ReportEntry] {
    outbox.compactMap { item in
      guard let messageId = item["messageId"] as? String, !messageId.isEmpty,
        let subscriberId = item["subscriberId"] as? String, !subscriberId.isEmpty
      else { return nil }
      let enqueued = (item["enqueuedAt"] as? NSNumber)?.int64Value ?? currentTimeMs()
      return ReportEntry(messageId: messageId, subscriberId: subscriberId, enqueuedAtMs: enqueued)
    }
  }

  private static func dictionary(_ entry: ReportEntry) -> NSDictionary {
    [
      "messageId": entry.messageId,
      "subscriberId": entry.subscriberId,
      "enqueuedAt": NSNumber(value: entry.enqueuedAtMs),
    ]
  }
}
