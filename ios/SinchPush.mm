#import "SinchPush.h"

#import <React/RCTEventEmitter.h>
#import <React/RCTLog.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

#ifdef RCT_NEW_ARCH_ENABLED
#import <RNSinchPushSpec/RNSinchPushSpec.h>
#endif

// The Swift socket client (RN-032). The generated header's name is derived from
// the pod name, so it is probed rather than assumed: a host that has not
// re-run `pod install` since the Swift target appeared still compiles, and the
// socket methods degrade to the pre-RN-032 behaviour instead of failing the
// whole app build on an import.
#if __has_include(<react_native_sinch_push/react_native_sinch_push-Swift.h>)
#import <react_native_sinch_push/react_native_sinch_push-Swift.h>
#define SINCH_PUSH_SWIFT_AVAILABLE 1
#elif __has_include("react_native_sinch_push-Swift.h")
#import "react_native_sinch_push-Swift.h"
#define SINCH_PUSH_SWIFT_AVAILABLE 1
#endif

static NSString *const kSinchPushTokenNotification = @"SinchPushTokenNotification";
static NSString *const kSinchPushMessageNotification = @"SinchPushMessageNotification";
// Spelled out because a build without the Swift target has no generated header to read it from.
static NSString *const kSinchPushReportQueuedNotification = @"SinchPushReportQueuedNotification";

static NSString *const kEventTokenReceived = @"SinchPush:onTokenReceived";
static NSString *const kEventPushReceived = @"SinchPush:onPushReceived";
static NSString *const kEventSocketMessage = @"SinchPush:onSocketMessage";
static NSString *const kEventSocketState = @"SinchPush:onSocketState";
static NSString *const kEventReportQueued = @"SinchPush:onReportQueued";
/** A background push left a DELIVERED report for JS to flush; JS answers `completeBackgroundWake`. */
static NSString *const kEventBackgroundWake = @"SinchPushBackgroundWake";

/** iOS gives a background fetch ~30 s; the handler must be called before then. */
static const NSTimeInterval kBackgroundWakeTimeoutSeconds = 25.0;

/**
 * How long a wake waits for JS to add its listener. If none appears (JS not
 * loaded, or the app never subscribes) the handler completes `.noData` at once:
 * iOS throttles apps that burn their fetch time. Once the wake has been emitted
 * to JS only `kBackgroundWakeTimeoutSeconds` applies.
 */
static const NSTimeInterval kBackgroundWakeListenerGraceSeconds = 6.0;

/** userInfo key the Swift poster stamps on a socket notification (RN-019). */
static NSString *const kSocketNotificationMessageId = @"messageId";
static NSString *const kSocketNotificationSource = @"source";
static NSString *const kSocketNotificationSourceValue = @"socket";

static NSDictionary *gLatestToken = nil;

// Background wakes (see +didReceiveRemoteNotification:fetchCompletionHandler:).
// Class-level and main-queue-only: the AppDelegate callback can arrive before
// the module instance exists (cold background launch) and must still be answered.
static NSMutableDictionary<NSString *, void (^)(UIBackgroundFetchResult)> *gWakeHandlers = nil;
/** Wakes that have no JS listener yet; flushed by `addListener:` for the wake event. */
static NSMutableArray<NSString *> *gPendingWakeIds = nil;
/** The module instance whose JS currently listens for events. */
static __weak SinchPush *gWakeListener = nil;

static void SinchPushRunOnMain(void (^block)(void)) {
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

/** Calls and forgets the wake's completion handler. Main queue only; no-op if already answered. */
static void SinchPushFinishWake(NSString *wakeId, UIBackgroundFetchResult result) {
  void (^handler)(UIBackgroundFetchResult) = gWakeHandlers[wakeId];
  if (handler == nil) {
    return;
  }
  [gWakeHandlers removeObjectForKey:wakeId];
  [gPendingWakeIds removeObject:wakeId];
  NSLog(@"[SinchPush] background wake %@ completed (%@)", wakeId,
             result == UIBackgroundFetchResultNewData ? @"newData" : @"noData");
  handler(result);
}

// New Architecture: the class conforms to `NativeSinchPushSpec` here, next to the
// `RCT_EXPORT_METHOD`s that implement it (see `getTurboModule:` at the end). A
// category in another file cannot see them and warns about every missing method.
@interface SinchPush () <UNUserNotificationCenterDelegate
#ifdef RCT_NEW_ARCH_ENABLED
                          , NativeSinchPushSpec
#endif
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
                          , SinchPushSocketFacadeDelegate
#endif
                          >
@end

@implementation SinchPush {
  BOOL _hasListeners;
  BOOL _invalidated;
  /**
   * RN-019: the delegate this module replaced. `init` below takes over
   * `UNUserNotificationCenter.delegate` so foreground pushes are routed here,
   * and every method the previous delegate implemented is still called — an app
   * that had its own delegate keeps working.
   */
  __weak id<UNUserNotificationCenterDelegate> _previousNotificationDelegate;
}

RCT_EXPORT_MODULE()

- (instancetype)init {
  if ((self = [super init])) {
    _hasListeners = NO;
    _invalidated = NO;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(handleTokenNotification:)
                   name:kSinchPushTokenNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleMessageNotification:)
                   name:kSinchPushMessageNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleReportQueuedNotification:)
                   name:kSinchPushReportQueuedNotification
                 object:nil];
    // Become the UNUserNotificationCenter delegate so foreground pushes are
    // routed through `willPresentNotification:withCompletionHandler:` below,
    // and so a socket notification's dismiss action reaches DISMISSED (RN-019).
    // setDelegate: must be called on the main thread.
    dispatch_async(dispatch_get_main_queue(), ^{
      UNUserNotificationCenter *notificationCenter =
          [UNUserNotificationCenter currentNotificationCenter];
      // Keep whatever was there before; see _previousNotificationDelegate.
      if (notificationCenter.delegate != self) {
        self->_previousNotificationDelegate = notificationCenter.delegate;
        notificationCenter.delegate = self;
      }
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
      [SinchPushSocket sharedInstance].delegate = self;
#endif
    });
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
    // Reconnect to the report uploads' background sessions now, not only when iOS relaunches
    // the app for one (it does not for a force-quit app): their results are delivered to the
    // sessions once they exist in this process. Off the main queue - it reads the App Group.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      [SinchPushReports resumeSessions];
    });
#endif
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)invalidate {
  _invalidated = YES;
  SinchPushRunOnMain(^{
    if (gWakeListener == self) {
      gWakeListener = nil;
    }
  });
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  // The bridge is going away, so the socket must not be left polling into a
  // module that can no longer emit. `stop` is terminal until JS starts it again
  // (SB-53: no timer survives that could open a socket).
  [[SinchPushSocket sharedInstance] stop];
#endif
}

- (NSArray<NSString *> *)supportedEvents {
  return @[kEventTokenReceived, kEventPushReceived, kEventSocketMessage, kEventSocketState,
           kEventReportQueued, kEventBackgroundWake];
}

- (void)startObserving {
  _hasListeners = YES;
  NSDictionary *token = gLatestToken;
  if (token) {
    [self sendEventWithName:kEventTokenReceived body:token];
  }
}

/**
 * `startObserving` fires for the first listener of *any* event, so it cannot say
 * that JS can already receive `SinchPushBackgroundWake`: an event emitted before
 * its own listener exists is dropped by JS. The wake listener is therefore
 * detected here, and the wakes that arrived before it (cold background launch)
 * are emitted now.
 */
- (void)addListener:(NSString *)eventName {
  [super addListener:eventName];
  if (![eventName isEqualToString:kEventBackgroundWake]) {
    return;
  }
  SinchPushRunOnMain(^{
    gWakeListener = self;
    NSArray<NSString *> *pending = [gPendingWakeIds copy];
    [gPendingWakeIds removeAllObjects];
    for (NSString *wakeId in pending) {
      NSLog(@"[SinchPush] background wake %@: emitting to JS (was queued)", wakeId);
      [self sendEventWithName:kEventBackgroundWake body:@{@"wakeId" : wakeId}];
    }
  });
}

- (void)stopObserving {
  _hasListeners = NO;
  SinchPushRunOnMain(^{
    if (gWakeListener == self) {
      gWakeListener = nil;
    }
  });
}

+ (BOOL)requiresMainQueueSetup {
  return NO;
}

#pragma mark - Promised methods

RCT_EXPORT_METHOD(getDeviceToken:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
  resolve(gLatestToken ?: @{});
}

RCT_EXPORT_METHOD(registerForToken:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
  [self requestNotificationAuthorizationAndRegister];
  resolve(nil);
}

/**
 * The per-install id.
 *
 * Map unavailable storage to E_INSTALLATION_ID_UNAVAILABLE, and a build without
 * the Swift socket target to E_UNAVAILABLE.
 */
RCT_EXPORT_METHOD(getInstallationId:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  NSString *installationId = [[SinchPushSocket sharedInstance] installationId];
  if (installationId == nil) {
    reject(@"E_INSTALLATION_ID_UNAVAILABLE",
           @"the installation id could not be read or persisted (the Keychain is locked or unavailable)",
           nil);
    return;
  }
  resolve(installationId);
#else
  RCTLogWarn(@"[SinchPush] getInstallationId is unavailable: the Swift socket "
             @"target is not in this build (run `pod install`).");
  reject(@"E_UNAVAILABLE", @"the installation id is not available in this build", nil);
#endif
}

/**
 * The device facts `Subscribe` and `Hello` both carry.
 *
 * Map unavailable storage to E_INSTALLATION_ID_UNAVAILABLE.
 */
RCT_EXPORT_METHOD(getDeviceInfo:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  NSDictionary *info = [[SinchPushSocket sharedInstance] deviceInfo];
  if (info == nil) {
    reject(@"E_INSTALLATION_ID_UNAVAILABLE",
           @"the installation id could not be read or persisted (the Keychain is locked or unavailable)",
           nil);
    return;
  }
  resolve(info);
#else
  RCTLogWarn(@"[SinchPush] getDeviceInfo is unavailable: the Swift socket "
             @"target is not in this build (run `pod install`).");
  reject(@"E_UNAVAILABLE", @"device info is not available in this build", nil);
#endif
}

/**
 * The relay off switch (SB-66).
 */
RCT_EXPORT_METHOD(setRelayEnabled:(BOOL)enabled
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  [[SinchPushSocket sharedInstance] setRelayEnabled:enabled];
  resolve(nil);
#else
  RCTLogWarn(@"[SinchPush] setRelayEnabled is unavailable: the Swift socket "
             @"target is not in this build (run `pod install`).");
  reject(@"E_UNAVAILABLE", @"the relay switch is not available in this build", nil);
#endif
}

RCT_EXPORT_METHOD(isRelayEnabled:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  resolve(@([[SinchPushSocket sharedInstance] isRelayEnabled]));
#else
  RCTLogWarn(@"[SinchPush] isRelayEnabled is unavailable: the Swift socket "
             @"target is not in this build (run `pod install`).");
  reject(@"E_UNAVAILABLE", @"the relay switch is not available in this build", nil);
#endif
}

#pragma mark - Persistent push socket channel
//
// The socket is native on every platform now (RN-032 iOS, RN-034 Android), so
// these methods are real. They translate a promise block and an NSDictionary
// into calls on the Swift facade and nothing else: no frames, no timers, no
// reports live on this side.

RCT_EXPORT_METHOD(startPushSocket:(NSDictionary *)config
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  NSError *startError = nil;
  if (![[SinchPushSocket sharedInstance] startWithConfig:config error:&startError]) {
    // The relay is off in the SDK (SB-66): nothing was started. Same code JS
    // produces for an unavailable relay and Android rejects with.
    // Domain *and* code, not the code alone: the relay-off code is 1, which other
    // domains use too, and matching on it alone would report a relay switch that
    // is on.
    if ([startError.domain isEqualToString:SinchPushSocket.relayDisabledErrorDomain]
        && startError.code == SinchPushSocket.relayDisabledErrorCode) {
      reject(@"E_RELAY_DISABLED", startError.localizedDescription, startError);
    } else {
      reject(@"E_START_PUSH_SOCKET", startError.localizedDescription, startError);
    }
    return;
  }
  resolve(nil);
#else
  RCTLogWarn(@"[SinchPush] startPushSocket is unavailable: the Swift socket "
             @"target is not in this build (run `pod install`).");
  reject(@"E_UNAVAILABLE", @"the native push socket is not available in this build", nil);
#endif
}

RCT_EXPORT_METHOD(stopPushSocket:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  [[SinchPushSocket sharedInstance] stop];
#endif
  resolve(nil);
}

RCT_EXPORT_METHOD(getPushSocketState:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  // The real state, never a hard-coded `idle`: JS polls this to recover what it
  // missed while detached.
  resolve([[SinchPushSocket sharedInstance] stateDictionary]);
#else
  resolve(@{@"status": @"idle", @"transport": @"native"});
#endif
}

RCT_EXPORT_METHOD(getPendingPushMessages:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  resolve([[SinchPushSocket sharedInstance] pendingMessages]);
#else
  resolve(@[]);
#endif
}

RCT_EXPORT_METHOD(clearPendingPushMessages:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  [[SinchPushSocket sharedInstance] clearPendingMessages];
#endif
  resolve(nil);
}

RCT_EXPORT_METHOD(reportPushMessageStatus:(NSString *)messageId
                  status:(NSString *)status
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  // Queued, not sent: a dismissal can happen while the socket is suspended and
  // the report still has to reach the relay (SB-35).
  [[SinchPushSocket sharedInstance] reportWithMessageId:messageId status:status];
  resolve(nil);
#else
  reject(@"E_UNAVAILABLE", @"the native push socket is not available in this build", nil);
#endif
}

RCT_EXPORT_METHOD(setSocketHandlerRegistered:(BOOL)registered
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  [[SinchPushSocket sharedInstance] setHandlerRegistered:registered];
#endif
  resolve(nil);
}

/**
 * The queued provider-push reports, oldest first. Reports the Notification
 * Service Extension or a background upload already sent (or is sending) are
 * left out - and dropped from the queue once sent - so JS does not report them
 * again; reports the extension could not send are added.
 */
RCT_EXPORT_METHOD(getReportOutbox:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  NSArray<NSDictionary *> *entries = (NSArray<NSDictionary *> *)[[SinchPushSocket sharedInstance] reportOutboxEntries];
  NSArray<NSDictionary *> *sent = [SinchPushReports sentReportsFrom:entries];
  if (sent.count > 0) {
    [[SinchPushSocket sharedInstance] removeReportOutboxEntries:sent];
  }
  resolve([SinchPushReports pendingReportsFrom:entries]);
#else
  resolve(@[]);
#endif
}

/** Drops the provider-push reports JS flushed. */
RCT_EXPORT_METHOD(removeReportOutboxEntries:(NSArray *)entries
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  [[SinchPushSocket sharedInstance] removeReportOutboxEntries:(NSArray<NSDictionary *> *)entries];
  // Reported by JS: neither the extension nor a background upload sends them again.
  [SinchPushReports markReported:(NSArray<NSDictionary *> *)entries];
#endif
  resolve(nil);
}

/** Drops every queued provider-push report. */
RCT_EXPORT_METHOD(clearReportOutbox:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  [[SinchPushSocket sharedInstance] clearReportOutbox];
  [SinchPushReports clearRetries];
#endif
  resolve(nil);
}

/**
 * iOS only. The App Group the Notification Service Extension shares with the app
 * (`ios.appGroup` of `initialize`), or null for none. Persisted natively so a
 * background relaunch knows it before JS runs.
 */
RCT_EXPORT_METHOD(configureSharedReports:(NSString *_Nullable)appGroup
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  // Also reconnects to the background sessions (see +resumeSessions).
  [SinchPushReports configureWithAppGroup:appGroup];
#endif
  resolve(nil);
}

/**
 * Mirrors the minimal record the extension and background uploads report with
 * - { accessToken, reportBaseURL, userId, appId } - or clears it (null). Never
 * the HMAC secret. Goes to the App Group container when one is configured (iOS
 * only, see `configureSharedReports`), else to app-private storage.
 */
RCT_EXPORT_METHOD(setSharedReportSession:(NSDictionary *_Nullable)record
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  [SinchPushReports setSession:record];
#endif
  resolve(nil);
}

/**
 * JS's answer to a `SinchPushBackgroundWake` event: calls the stored
 * `fetchCompletionHandler` with `.newData` if the delivery report was sent,
 * `.noData` if not. An unknown or already-answered `wakeId` (late answer after
 * the 25 s timeout) is ignored.
 */
RCT_EXPORT_METHOD(completeBackgroundWake:(NSString *)wakeId
                  sent:(BOOL)sent
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
  SinchPushRunOnMain(^{
    SinchPushFinishWake(wakeId, sent ? UIBackgroundFetchResultNewData : UIBackgroundFetchResultNoData);
    resolve(nil);
  });
}

RCT_EXPORT_METHOD(displayNotification:(NSString *)title
                  body:(NSString *)body
                  data:(NSDictionary *)data
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject) {
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
    void (^postBlock)(void) = ^{
      UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
      if (title.length > 0) {
        content.title = title;
      }
      if (body.length > 0) {
        content.body = body;
      }
      content.sound = [UNNotificationSound defaultSound];
      if (data) {
        content.userInfo = data;
      }

      NSString *identifier = [[NSUUID UUID] UUIDString];
      UNNotificationRequest *request = [UNNotificationRequest
          requestWithIdentifier:identifier
                        content:content
                        trigger:nil];
      [center addNotificationRequest:request
               withCompletionHandler:^(NSError *_Nullable error) {
        if (error) {
          reject(@"E_NOTIFICATION", error.localizedDescription, error);
        } else {
          resolve(nil);
        }
      }];
    };

    if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
      UNAuthorizationOptions options = UNAuthorizationOptionAlert |
                                       UNAuthorizationOptionBadge |
                                       UNAuthorizationOptionSound;
      [center requestAuthorizationWithOptions:options
                          completionHandler:^(BOOL granted, NSError *_Nullable error) {
        if (error) {
          reject(@"E_NOTIFICATION_AUTH", error.localizedDescription, error);
          return;
        }
        postBlock();
      }];
    } else {
      postBlock();
    }
  }];
}

#pragma mark - APNs registration

- (void)requestNotificationAuthorizationAndRegister {
  UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
  UNAuthorizationOptions options = UNAuthorizationOptionAlert |
                                   UNAuthorizationOptionBadge |
                                   UNAuthorizationOptionSound;
  [center requestAuthorizationWithOptions:options
                        completionHandler:^(BOOL granted, NSError *_Nullable error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[UIApplication sharedApplication] registerForRemoteNotifications];
    });
  }];
}

#pragma mark - Notification handlers

- (void)handleTokenNotification:(NSNotification *)notification {
  if (!_hasListeners) return;
  NSDictionary *userInfo = notification.userInfo;
  if (!userInfo) return;
  [self sendEventWithName:kEventTokenReceived body:userInfo];
}

- (void)handleMessageNotification:(NSNotification *)notification {
  if (!_hasListeners) return;
  NSDictionary *userInfo = notification.userInfo;
  if (!userInfo) return;
  [self sendEventWithName:kEventPushReceived body:userInfo];
}

/** The payload is empty: JS reads the report back with `getReportOutbox()`. */
- (void)handleReportQueuedNotification:(NSNotification *)notification {
  if (!_hasListeners) return;
  [self sendEventWithName:kEventReportQueued body:@{}];
}

#pragma mark - SinchPushSocketFacadeDelegate

#ifdef SINCH_PUSH_SWIFT_AVAILABLE

/**
 * The socket's own events. JS also polls the native store (RN-020), so these are
 * the low-latency path, not the only one — a message that arrives while JS is
 * detached is still recovered by `getPendingPushMessages`.
 */
- (void)socketFacadeDidEmitMessage:(NSDictionary<NSString *, id> *)message {
  if (!_hasListeners) return;
  [self sendEventWithName:kEventSocketMessage body:message];
}

- (void)socketFacadeDidEmitState:(NSDictionary<NSString *, id> *)state {
  if (!_hasListeners) return;
  [self sendEventWithName:kEventSocketState body:state];
}

/**
 * SB-48 / OPEN-6: the relay closed with UNAUTHORIZED and the client has stopped.
 * Only a credential refresh revives it, and that is the identity layer's job,
 * not the socket's — so the host is asked for one and hands back the new token.
 */
- (void)socketFacadeRequiresTokenRefresh {
  RCTLogInfo(@"[SinchPush] socket reported auth_required; a credential refresh "
            @"is required before the socket can reconnect.");
}

#endif

#pragma mark - UNUserNotificationCenterDelegate

// Called when a push arrives while the app is in the foreground. Returning
// presentation options causes the system to display the banner / list entry
// even though the app is active.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
  NSDictionary *userInfo = notification.request.content.userInfo;
  BOOL isSocketNotification = [userInfo[kSocketNotificationSource] isEqualToString:kSocketNotificationSourceValue];

#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  // RN-045 / SB-64: the shared seen set. A copy of a message another channel
  // (socket, FCM-equivalent) already delivered presents nothing and emits no JS
  // event; an unseen Sinch push is marked and handled as before. Socket-originated
  // local notifications always pass (the socket marks the id before it posts, so
  // the registry would call its own banner a duplicate), and a push without a
  // message id is never deduped. Decided in Swift (PushPresentation.swift).
  if (!isSocketNotification &&
      ![[SinchPushSocket sharedInstance] shouldPresentPushWithUserInfo:(userInfo ?: @{})
                                                     requestIdentifier:notification.request.identifier]) {
    // The host's own delegate is still told (SB-64): it may do work of its own
    // for the notification (analytics, badge). Whatever it answers, this copy
    // presents nothing, and the system's handler is called exactly once.
    SEL willPresentSelector = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
    if ([_previousNotificationDelegate respondsToSelector:willPresentSelector]) {
      __block BOOL completed = NO;
      NSObject *completionGuard = [NSObject new];
      [_previousNotificationDelegate userNotificationCenter:center
                                   willPresentNotification:notification
                                     withCompletionHandler:^(UNNotificationPresentationOptions) {
        @synchronized (completionGuard) {
          if (completed) { return; }
          completed = YES;
        }
        completionHandler(UNNotificationPresentationOptionNone);
      }];
      return;
    }
    completionHandler(UNNotificationPresentationOptionNone);
    return;
  }
#endif

  if (userInfo && !isSocketNotification) {
    NSDictionary *message = [self messageDictFromUserInfo:userInfo source:@"apns"];
    if (_hasListeners) {
      [self sendEventWithName:kEventPushReceived body:message];
    }
  }

  UNNotificationPresentationOptions options;
  if (@available(iOS 14.0, *)) {
    // RN-031: a socket message still shows its banner in the foreground — the
    // socket is a delivery channel, and the app being open does not mean the
    // user is looking at the screen it would render.
    options = UNNotificationPresentationOptionBanner |
              UNNotificationPresentationOptionList |
              UNNotificationPresentationOptionSound;
  } else {
    options = UNNotificationPresentationOptionAlert | UNNotificationPresentationOptionSound;
  }

  // Chain rather than replace: a host delegate that wanted this notification
  // handled its own way still gets to decide.
  if ([_previousNotificationDelegate respondsToSelector:@selector(userNotificationCenter:willPresentNotification:withCompletionHandler:)]) {
    [_previousNotificationDelegate userNotificationCenter:center
                                 willPresentNotification:notification
                                   withCompletionHandler:completionHandler];
    return;
  }
  completionHandler(options);
}

// RN-019: the dismiss branch of `sinchpush.socket` is the iOS route to
// DISMISSED, and it is the reason the category is registered with
// `UNNotificationCategoryOptionCustomDismissAction`. Reported natively rather
// than through a JS event so the report is queued in the outbox when the socket
// is suspended — which is the normal state on iOS at that moment.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
  NSDictionary *userInfo = response.notification.request.content.userInfo;
  BOOL isSocketNotification =
      [userInfo[kSocketNotificationSource] isEqualToString:kSocketNotificationSourceValue];

  if (isSocketNotification && response.actionIdentifier == UNNotificationDismissActionIdentifier) {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
    NSString *messageId = userInfo[kSocketNotificationMessageId];
    if (messageId.length > 0) {
      [[SinchPushSocket sharedInstance] notificationDidDismissWithMessageId:messageId];
    }
#endif
  } else if (isSocketNotification && response.actionIdentifier == UNNotificationDefaultActionIdentifier) {
    // The default action is the host's business; routed through the event the
    // host already has a handler for rather than a new one.
    if (_hasListeners) {
      [self sendEventWithName:kEventPushReceived
                         body:@{@"source" : kSocketNotificationSourceValue,
                                @"data" : userInfo ?: @{}}];
    }
  }

  if ([_previousNotificationDelegate respondsToSelector:@selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:)]) {
    [_previousNotificationDelegate userNotificationCenter:center
                              didReceiveNotificationResponse:response
                                       withCompletionHandler:completionHandler];
    return;
  }
  completionHandler();
}

#pragma mark - App delegate forwarding

+ (void)didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
  NSMutableString *hex = [NSMutableString stringWithCapacity:deviceToken.length * 2];
  const unsigned char *bytes = (const unsigned char *)deviceToken.bytes;
  for (NSUInteger i = 0; i < deviceToken.length; i++) {
    [hex appendFormat:@"%02x", bytes[i]];
  }
  NSDictionary *token = @{@"token": hex, @"type": @"apns"};
  gLatestToken = token;
  [[NSNotificationCenter defaultCenter] postNotificationName:kSinchPushTokenNotification
                                                      object:nil
                                                    userInfo:token];
}

+ (void)didFailToRegisterForRemoteNotificationsWithError:(NSError *)error {
  RCTLogError(@"[SinchPush] APNs registration failed: %@", error.localizedDescription);
}

+ (void)didReceiveRemoteNotification:(NSDictionary *)userInfo {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  // RN-045 / SB-64: mark the push's message id in the shared seen set so the
  // socket's copy is a duplicate, and drop the JS event for a copy of a message
  // another channel already delivered. An active app with an alert push is left
  // to `willPresentNotification:` (marking it here would make that path swallow
  // the only copy); see PushPresentationDecider.
  BOOL appIsActive = [UIApplication sharedApplication].applicationState == UIApplicationStateActive;
  if (![[SinchPushSocket sharedInstance] shouldHandleRemotePushWithUserInfo:(userInfo ?: @{})
                                                                appIsActive:appIsActive]) {
    return;
  }
#endif
  NSDictionary *message = [self messageDictFromUserInfo:userInfo source:@"apns"];
  [[NSNotificationCenter defaultCenter] postNotificationName:kSinchPushMessageNotification
                                                      object:nil
                                                    userInfo:message];
}

/**
 * `application:didReceiveRemoteNotification:fetchCompletionHandler:`.
 *
 * Does everything `+didReceiveRemoteNotification:` does. When that queued a
 * provider-push DELIVERED report (a push carrying `sinch.push.message_id` and
 * `sinch.push.subscriber_id` that no other channel delivered first), the
 * completion handler is kept and JS is woken with `SinchPushBackgroundWake
 * { wakeId }`: JS reads `getReportOutbox()`, sends the report and answers
 * `completeBackgroundWake(wakeId, sent)`. If JS does not answer within 25 s the
 * handler is called with `.noData`. Any other push completes immediately.
 *
 * A cold background launch (the push relaunched a terminated app) runs
 * `didFinishLaunching` first, so RCTAppDelegate creates the bridge and loads the
 * JS bundle as in a normal launch; the wake event is queued until JS adds its
 * wake listener, so a listener registered at module load (not in a component)
 * still receives it. JS must be loaded (the SDK subscribes at module load) within
 * 6 s of the push; otherwise the handler completes `.noData` without waking JS.
 *
 * Requirements: the push must carry `content-available: 1` (and the app the
 * `remote-notification` background mode), otherwise iOS does not call this method
 * in the background. iOS never delivers background pushes to an app the user
 * force-quit, so no wake (and no delivery report from this path) happens until the
 * user opens the app again.
 */
+ (void)didReceiveRemoteNotification:(NSDictionary *)userInfo
              fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
  __block BOOL reportQueued = NO;
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  // The decider posts this synchronously, on this thread, only when it enqueued a report.
  id observer = [[NSNotificationCenter defaultCenter]
      addObserverForName:kSinchPushReportQueuedNotification
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification *note) { reportQueued = YES; }];
  [self didReceiveRemoteNotification:userInfo];
  [[NSNotificationCenter defaultCenter] removeObserver:observer];
#else
  [self didReceiveRemoteNotification:userInfo];
#endif

  if (!reportQueued) {
    completionHandler(UIBackgroundFetchResultNoData);
    return;
  }

#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  // The app has a usable mirrored token: a background URLSession sends the reports,
  // so this wake can finish at once and JS is not needed. Otherwise fall through to JS.
  // The upload can wait on the cross-process report lock for a couple of seconds, so it runs off
  // the main thread (this handler is called on it); the result comes back to main.
  NSArray<NSDictionary *> *queued =
      (NSArray<NSDictionary *> *)[[SinchPushSocket sharedInstance] reportOutboxEntries];
  void (^done)(UIBackgroundFetchResult) = [completionHandler copy];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    SinchPushBackgroundUpload result = [SinchPushReports uploadInBackground:queued];
    dispatch_async(dispatch_get_main_queue(), ^{
      switch (result) {
        case SinchPushBackgroundUploadHandedOff:
          NSLog(@"[SinchPush] background wake: reports handed to a background URLSession");
          done(UIBackgroundFetchResultNewData);
          return;
        case SinchPushBackgroundUploadNothingToSend:
          done(UIBackgroundFetchResultNoData);
          return;
        case SinchPushBackgroundUploadUnavailable:
          [self wakeJSWithCompletionHandler:done];
          return;
      }
    });
  });
#else
  [self wakeJSWithCompletionHandler:completionHandler];
#endif
}

/**
 * Hands a background wake to JS (see `didReceiveRemoteNotification:fetchCompletionHandler:`):
 * JS sends the report and answers `completeBackgroundWake`.
 */
+ (void)wakeJSWithCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {
  NSString *wakeId = [[NSUUID UUID] UUIDString];
  void (^handler)(UIBackgroundFetchResult) = [completionHandler copy];
  SinchPushRunOnMain(^{
    if (gWakeHandlers == nil) {
      gWakeHandlers = [NSMutableDictionary dictionary];
      gPendingWakeIds = [NSMutableArray array];
    }
    gWakeHandlers[wakeId] = handler;
    SinchPush *listener = gWakeListener;
    if (listener != nil) {
      NSLog(@"[SinchPush] background wake %@: emitting to JS", wakeId);
      [listener sendEventWithName:kEventBackgroundWake body:@{@"wakeId" : wakeId}];
    } else {
      NSLog(@"[SinchPush] background wake %@: no JS listener yet, queued", wakeId);
      [gPendingWakeIds addObject:wakeId];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBackgroundWakeTimeoutSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      SinchPushFinishWake(wakeId, UIBackgroundFetchResultNoData);
    });
    if (listener == nil) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBackgroundWakeListenerGraceSeconds * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        // Still queued = never emitted: no JS listener showed up in time.
        if ([gPendingWakeIds containsObject:wakeId]) {
          NSLog(@"[SinchPush] background wake %@: no JS listener within grace", wakeId);
          SinchPushFinishWake(wakeId, UIBackgroundFetchResultNoData);
        }
      });
    }
  });
}

/**
 * `application:handleEventsForBackgroundURLSession:completionHandler:`. See the
 * header.
 */
+ (BOOL)handleEventsForBackgroundURLSession:(NSString *)identifier
                          completionHandler:(void (^)(void))completionHandler {
#ifdef SINCH_PUSH_SWIFT_AVAILABLE
  return [SinchPushReports handleEventsForBackgroundURLSession:identifier
                                             completionHandler:completionHandler];
#else
  return NO;
#endif
}

#pragma mark - Helpers

+ (NSDictionary *)messageDictFromUserInfo:(NSDictionary *)userInfo source:(NSString *)source {
  NSMutableDictionary *data = [NSMutableDictionary dictionary];
  for (id key in userInfo) {
    if ([key isKindOfClass:[NSString class]] && ![key isEqualToString:@"aps"]) {
      id value = userInfo[key];
      data[key] = [NSString stringWithFormat:@"%@", value];
    }
  }

  NSDictionary *aps = userInfo[@"aps"];
  id alert = aps[@"alert"];

  NSMutableDictionary *message = [NSMutableDictionary dictionary];
  message[@"data"] = data;
  message[@"source"] = source;

  if ([alert isKindOfClass:[NSDictionary class]]) {
    NSString *title = alert[@"title"];
    NSString *body = alert[@"body"];
    if (title) message[@"title"] = title;
    if (body) message[@"body"] = body;
  } else if ([alert isKindOfClass:[NSString class]]) {
    message[@"body"] = alert;
  }

  NSString *identity = userInfo[@"identity"];
  if ([identity isKindOfClass:[NSString class]]) {
    message[@"identity"] = identity;
  }

  return message;
}

- (NSDictionary *)messageDictFromUserInfo:(NSDictionary *)userInfo source:(NSString *)source {
  return [[self class] messageDictFromUserInfo:userInfo source:source];
}

#ifdef RCT_NEW_ARCH_ENABLED
// The spec methods are the `RCT_EXPORT_METHOD`s above, and the ObjC TurboModule
// dispatches them by selector at runtime.
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeSinchPushSpecJSI>(params);
}
#endif

@end
