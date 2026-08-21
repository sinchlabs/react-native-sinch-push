package com.sinchpush

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext

class SinchPushModuleImpl(private val reactContext: ReactApplicationContext) {

  init {
    SinchPushEmitter.attachReactContext(reactContext)
    if (BuildConfig.FCM_AVAILABLE) {
      // Notification channel must exist before posting (API 26+).
      SinchPushNotifications.ensureChannel(reactContext.applicationContext)
      // Trigger auto-detection of Firebase Cloud Messaging on module construction
      // (process start / JS context attach). The call is a no-op when firebase-messaging
      // is not on the runtime classpath.
      FcmProvider.fetchAndListen()
      // Ask for POST_NOTIFICATIONS permission on API 33+. No-op below.
      SinchPushNotifications.requestPermission(reactContext.currentActivity)
    }
  }

  fun getDeviceToken(promise: Promise) {
    val cached = SinchPushEmitter.latestToken
    if (cached != null) {
      promise.resolve(tokenMap(cached, SinchPushEmitter.latestTokenType))
    } else {
      promise.resolve(Arguments.createMap())
    }
  }

  fun registerForToken(promise: Promise) {
    if (BuildConfig.FCM_AVAILABLE) {
      FcmProvider.fetchAndListen()
      // Re-request permission in case the user previously denied and the
      // activity has changed.
      SinchPushNotifications.requestPermission(reactContext.currentActivity)
    }
    promise.resolve(null)
  }

  fun addListener(eventName: String?) {
  }

  fun removeListeners(count: Double) {
  }

  private fun tokenMap(token: String, type: String) = Arguments.createMap().apply {
    putString("token", token)
    putString("type", type)
  }

  companion object {
    const val NAME = "SinchPush"
  }
}
