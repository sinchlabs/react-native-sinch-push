#import <React/RCTEventEmitter.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Public Objective-C interface for the SinchPush module. The implementation
 * lives in `SinchPush.mm`. Consumers (typically `AppDelegate.mm`) import
 * this header to forward APNs callbacks to the SDK without needing the
 * Swift-generated header.
 */
@interface SinchPush : RCTEventEmitter

+ (void)didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken;
+ (void)didFailToRegisterForRemoteNotificationsWithError:(NSError *)error;
+ (void)didReceiveRemoteNotification:(NSDictionary *)userInfo;

/**
 * Forward `application:didReceiveRemoteNotification:fetchCompletionHandler:`
 * here. The SDK always calls `completionHandler` exactly once: immediately when
 * the push needs no JS work, otherwise after JS answers `completeBackgroundWake`
 * (`.newData` if it sent the delivery report, `.noData` if not) or after 25 s,
 * whichever comes first. If JS has not subscribed within ~6 s of the push (JS not
 * loaded) the handler completes `.noData` without waking JS. Do not call the
 * handler yourself.
 *
 * The background wake needs the push to carry `content-available: 1` and the app
 * the `remote-notification` background mode. iOS never runs it for an app the
 * user force-quit.
 *
 * When the app has mirrored a usable access token (any `setIdentity` since
 * install), the reports are uploaded by the SDK itself with a background
 * URLSession and `completionHandler` is called right after the hand-off - JS is
 * not woken and the upload finishes even if the app is suspended or killed.
 * Without a token the JS hand-off above is the fallback.
 */
+ (void)didReceiveRemoteNotification:(NSDictionary *)userInfo
              fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler;

/**
 * Forward `application:handleEventsForBackgroundURLSession:completionHandler:`
 * here. The SDK uploads delivery reports with background URLSessions (from a
 * background wake, and from the Notification Service Extension); iOS relaunches
 * the app to hand it the results. Returns YES, and calls `completionHandler`
 * itself once the events are delivered, for the SDK's own sessions
 * (`com.sinch.push.reports.app` and the Notification Service Extension's
 * `com.sinch.push.reports.nse.<uuid>`, one per extension process). Returns NO
 * for any other identifier - call your own handling (or the handler) then.
 *
 * iOS does not relaunch a force-quit app for these events. The SDK therefore also
 * reconnects to its sessions (the app's, and the extension's that the App Group
 * still lists) when the module loads, and collects the results on the next launch.
 *
 *     - (void)application:(UIApplication *)application
 *         handleEventsForBackgroundURLSession:(NSString *)identifier
 *                           completionHandler:(void (^)(void))completionHandler {
 *       if (![SinchPush handleEventsForBackgroundURLSession:identifier
 *                                         completionHandler:completionHandler]) {
 *         completionHandler();
 *       }
 *     }
 */
+ (BOOL)handleEventsForBackgroundURLSession:(NSString *)identifier
                          completionHandler:(void (^)(void))completionHandler;

@end

NS_ASSUME_NONNULL_END