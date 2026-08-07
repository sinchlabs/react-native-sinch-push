#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(SinchPush, RCTEventEmitter)

RCT_EXTERN_METHOD(getDeviceToken:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

RCT_EXTERN_METHOD(registerForToken:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)

@end
