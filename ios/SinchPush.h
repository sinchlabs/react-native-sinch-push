#import <React/RCTEventEmitter.h>

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

@end

NS_ASSUME_NONNULL_END