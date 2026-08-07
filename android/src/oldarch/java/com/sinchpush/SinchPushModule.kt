package com.sinchpush

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod

class SinchPushModule(reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {

  private val impl = SinchPushModuleImpl(reactContext)

  override fun getName(): String = SinchPushModuleImpl.NAME

  @ReactMethod
  fun getDeviceToken(promise: Promise) = impl.getDeviceToken(promise)

  @ReactMethod
  fun registerForToken(promise: Promise) = impl.registerForToken(promise)
}
