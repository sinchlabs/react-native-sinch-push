//  ExtensionReportHandler.swift — what the Notification Service Extension does with a push.
//
//  Pure logic over a directory and an uploader, so `swift test` covers it; the
//  public entry point (SinchPushNotificationExtension.swift) only resolves the App
//  Group and the URLSession.

import Foundation

enum ExtensionReportHandler {
  /// `true` when the push is a Sinch provider push whose report is on its way (or already was).
  /// `false` for any other push, and when no upload could be started - in which case the report
  /// is left as a retry for the app to send.
  static func handle(
    userInfo: [AnyHashable: Any],
    directory: URL?,
    uploader: @autoclosure () -> ReportScheduling?,
    now: @escaping () -> Int64 = currentTimeMs
  ) -> Bool {
    guard let entry = ProviderPush.entry(from: userInfo, nowMs: now()) else { return false }
    guard let directory else { return false }
    let markers = ReportMarkerStore(directory: directory, now: now)

    guard let session = SharedReportSessionStore(directory: directory).load(),
      session.isUsable(nowMs: now()), let uploader = uploader()
    else {
      // No credential to upload with (the user never signed in, or the token expired): the app
      // reports it when it next runs.
      markers.markRetryIfUnknown(entry)
      return false
    }
    let claimed = markers.claim([entry])
    guard !claimed.isEmpty else { return true }  // already sent, or another upload has it
    if uploader.upload(entries: claimed, session: session) { return true }
    markers.markRetry(claimed.map(\.key), entries: claimed)
    return false
  }
}

extension ReportMarkerStore {
  /// Records a report to retry unless something already knows it (sent, in flight, retry).
  func markRetryIfUnknown(_ entry: ReportEntry) {
    guard !excludedKeys().contains(entry.key), !retryEntries().contains(entry) else { return }
    markRetry([entry.key], entries: [entry])
  }
}
