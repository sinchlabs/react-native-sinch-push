#ifdef RCT_NEW_ARCH_ENABLED
#import <RNSinchPushSpec/RNSinchPushSpec.h>

// Swift-generated interface header.
// CocoaPods derives the module name from s.name in the podspec, replacing
// hyphens with underscores. If a build error mentions a different header name,
// run the build once and check DerivedData/<target>/.../ for the exact name.
#import "react_native_sinch_push-Swift.h"

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
