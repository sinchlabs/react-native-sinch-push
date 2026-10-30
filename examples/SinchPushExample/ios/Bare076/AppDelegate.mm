#import "AppDelegate.h"

#import <React/RCTBundleURLProvider.h>
#import "SinchPush.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
  self.moduleName = @"Bare076";
  // You can add your custom initial props in the dictionary below.
  // They will be passed down to the ViewController used by React Native.
  self.initialProps = @{};

  return [super application:application didFinishLaunchingWithOptions:launchOptions];
}

// MARK: - APNs forwarding (react-native-sinch-push)
//
// The SDK installs itself as the UNUserNotificationCenter delegate when its
// module loads, so no delegate is needed here.

- (void)application:(UIApplication *)application
    didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
  [SinchPush didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
}

- (void)application:(UIApplication *)application
    didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
  [SinchPush didFailToRegisterForRemoteNotificationsWithError:error];
}

// The SDK calls completionHandler exactly once: at once for a push that needs no
// JS work, otherwise when JS answers (or after 25 s). Do not call it yourself.
- (void)application:(UIApplication *)application
    didReceiveRemoteNotification:(NSDictionary *)userInfo
          fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler
{
  [SinchPush didReceiveRemoteNotification:userInfo fetchCompletionHandler:completionHandler];
}

// Forwards the background URLSession wake-up to the SDK (report uploads started
// by the Notification Service Extension finish here). Returns NO for a
// session the SDK does not own.
- (void)application:(UIApplication *)application
    handleEventsForBackgroundURLSession:(NSString *)identifier
                      completionHandler:(void (^)(void))completionHandler
{
  if (![SinchPush handleEventsForBackgroundURLSession:identifier completionHandler:completionHandler]) {
    completionHandler();
  }
}

- (NSURL *)sourceURLForBridge:(RCTBridge *)bridge
{
  return [self bundleURL];
}

- (NSURL *)bundleURL
{
#if DEBUG
  return [[RCTBundleURLProvider sharedSettings] jsBundleURLForBundleRoot:@"index"];
#else
  return [[NSBundle mainBundle] URLForResource:@"main" withExtension:@"jsbundle"];
#endif
}

@end

// Recent iOS SDKs (Xcode 26+/27) refuse to launch apps without the UIScene
// lifecycle. RCTAppDelegate (RN 0.76) still creates the window itself in
// didFinishLaunching, so the scene delegate only attaches it to the scene.
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
  AppDelegate *appDelegate = (AppDelegate *)UIApplication.sharedApplication.delegate;
  if ([scene isKindOfClass:UIWindowScene.class] && appDelegate.window != nil) {
    appDelegate.window.windowScene = (UIWindowScene *)scene;
    self.window = appDelegate.window;
    [self.window makeKeyAndVisible];
  }
}

@end
