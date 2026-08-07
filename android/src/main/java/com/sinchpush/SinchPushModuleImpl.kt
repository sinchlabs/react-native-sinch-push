package com.sinchpush

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext

class SinchPushModuleImpl(private val reactContext: ReactApplicationContext) {

  init {
    SinchPushEmitter.attachReactContext(reactContext)
  }

  fun getDeviceToken(promise: Promise) {
    val cached = SinchPushEmitter.latestToken
    if (cached != null) {
      promise.resolve(tokenMap(cached))
    } else {
      promise.resolve(Arguments.createMap())
    }
  }

  fun registerForToken(promise: Promise) {
    promise.resolve(null)
  }

  fun addListener(eventName: String?) {
  }

  fun removeListeners(count: Double) {
  }

  private fun tokenMap(token: String) = Arguments.createMap().apply {
    putString("token", token)
    putString("type", "fcm")
  }

  companion object {
    const val NAME = "SinchPush"
  }
}
