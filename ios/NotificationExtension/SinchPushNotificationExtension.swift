//  SinchPushNotificationExtension.swift — the Notification Service Extension entry point.
//
//  Compiled into the `SinchPushNotificationExtension` pod only (the library pod
//  takes ``Core/`` and leaves this file out). No React, and only
//  extension-safe APIs: Foundation and UserNotifications.

import Foundation
import UserNotifications

@objc public final class SinchPushNotificationExtension: NSObject {
  /// The background session this extension process's uploads run in
  /// (`com.sinch.push.reports.nse.<uuid>`, one per process: a session identifier belongs to one
  /// process). The system hands its results to the containing app
  /// (`handleEventsForBackgroundURLSession`), and the app finds the session again from the App
  /// Group even when it was force-quit.
  @objc public static let sessionIdentifier = ReportUploader.makeExtensionIdentifier()

  /// Call from `UNNotificationServiceExtension.didReceive(_:withContentHandler:)`.
  ///
  /// Queues the push's DELIVERED report and hands it to a background URLSession
  /// (`com.sinch.push.reports.nse.<uuid>`, shared container `appGroup`), then returns at
  /// once: the upload is the system's, so it outlives the extension. Returns `false`
  /// for a push that is not from Sinch, and when no upload could be started (no
  /// credential mirrored by the app yet, or the App Group is unreachable) - the app
  /// then sends the report itself when it next runs.
  ///
  /// It never alters the notification; call the content handler as you would anyway.
  @discardableResult
  @objc public static func didReceive(_ request: UNNotificationRequest, appGroup: String) -> Bool {
    let directory = ReportDirectory.shared(appGroup: appGroup)
    return ExtensionReportHandler.handle(
      userInfo: request.content.userInfo,
      directory: directory,
      uploader: directory.map {
        ReportUploader.shared(identifier: sessionIdentifier, appGroup: appGroup, directory: $0)
      })
  }
}
