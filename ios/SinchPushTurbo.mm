#ifdef RCT_NEW_ARCH_ENABLED
#import <RNSinchPushSpec/RNSinchPushSpec.h>
#import "SinchPush.h"

@interface SinchPush (Turbo) <NativeSinchPushSpec>
@end

@implementation SinchPush (Turbo)

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeSinchPushSpecJSI>(params);
}

@end
#endif