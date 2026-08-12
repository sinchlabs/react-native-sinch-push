#import "SinchPush.h"

#import <React/RCTEventEmitter.h>
#import <React/RCTLog.h>
#import <UserNotifications/UserNotifications.h>

static NSString *const kSinchPushTokenNotification = @"SinchPushTokenNotification";
static NSString *const kSinchPushMessageNotification = @"SinchPushMessageNotification";

static NSString *const kEventTokenReceived = @"SinchPush:onTokenReceived";
static NSString *const kEventPushReceived = @"SinchPush:onPushReceived";

static NSDictionary *gLatestToken = nil;

@implementation SinchPush {
  BOOL _hasListeners;
  BOOL _invalidated;
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
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)invalidate {
  _invalidated = YES;
}

- (NSArray<NSString *> *)supportedEvents {
  return @[kEventTokenReceived, kEventPushReceived];
}

- (void)startObserving {
  _hasListeners = YES;
  NSDictionary *token = gLatestToken;
  if (token) {
    [self sendEventWithName:kEventTokenReceived body:token];
  }
}

- (void)stopObserving {
  _hasListeners = NO;
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
  message[@"source"] = @"apns";

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

  [[NSNotificationCenter defaultCenter] postNotificationName:kSinchPushMessageNotification
                                                      object:nil
                                                    userInfo:message];
}

@end