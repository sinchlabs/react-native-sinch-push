package com.sinchpush

import com.facebook.react.TurboReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider

/**
 * Registers [SinchPushModule]. As a [TurboReactPackage] this works unchanged on
 * both the old and new architectures — on the new architecture the module is
 * resolved lazily as a TurboModule, on the old one as a legacy native module.
 */
class SinchPushPackage : TurboReactPackage() {

  override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? {
    return if (name == SinchPushModuleImpl.NAME) {
      SinchPushModule(reactContext)
    } else {
      null
    }
  }

  override fun getReactModuleInfoProvider(): ReactModuleInfoProvider {
    return ReactModuleInfoProvider {
      mapOf(
        SinchPushModuleImpl.NAME to ReactModuleInfo(
          SinchPushModuleImpl.NAME,
          SinchPushModuleImpl.NAME,
          false, // canOverrideExistingModule
          false, // needsEagerInit
          false, // isCxxModule
          BuildConfig.IS_NEW_ARCHITECTURE_ENABLED, // isTurboModule
        ),
      )
    }
  }
}
