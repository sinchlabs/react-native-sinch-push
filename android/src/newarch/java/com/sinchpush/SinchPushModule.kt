package com.sinchpush

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext

class SinchPushModule(reactContext: ReactApplicationContext) :
  NativeSinchPushSpec(reactContext) {

  private val impl = SinchPushModuleImpl(reactContext)

  override fun getName(): String = SinchPushModuleImpl.NAME

  override fun getDeviceToken(promise: Promise) = impl.getDeviceToken(promise)

  override fun registerForToken(promise: Promise) = impl.registerForToken(promise)

  override fun addListener(eventName: String?) = impl.addListener(eventName)

  override fun removeListeners(count: Double) = impl.removeListeners(count)
}
