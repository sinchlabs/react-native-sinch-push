package com.sinchpush

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule

object SinchPushEmitter {

  const val EVENT_TOKEN_RECEIVED = "SinchPush:onTokenReceived"
  const val EVENT_PUSH_RECEIVED = "SinchPush:onPushReceived"

  @Volatile
  private var reactContext: ReactApplicationContext? = null

  @Volatile
  var latestToken: String? = null
    private set

  @Synchronized
  fun attachReactContext(context: ReactApplicationContext) {
    reactContext = context
    latestToken?.let { emitToken(it) }
  }

  @Synchronized
  fun detachReactContext(context: ReactApplicationContext) {
    if (reactContext === context) {
      reactContext = null
    }
  }

  fun onNewToken(token: String) {
    latestToken = token
    emitToken(token)
  }

  fun onMessage(data: Map<String, String>, title: String?, body: String?) {
    val payload: WritableMap = Arguments.createMap()
    val dataMap: WritableMap = Arguments.createMap()
    for ((key, value) in data) {
      dataMap.putString(key, value)
    }
    payload.putMap("data", dataMap)
    payload.putString("source", "fcm")
    data["identity"]?.let { payload.putString("identity", it) }
    title?.let { payload.putString("title", it) }
    body?.let { payload.putString("body", it) }
    emit(EVENT_PUSH_RECEIVED, payload)
  }

  fun emitToken(token: String) {
    val payload: WritableMap = Arguments.createMap()
    payload.putString("token", token)
    payload.putString("type", "fcm")
    emit(EVENT_TOKEN_RECEIVED, payload)
  }

  private fun emit(eventName: String, params: ReadableMap) {
    val context = reactContext ?: return
    if (!context.hasActiveReactInstance()) {
      return
    }
    context
      .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
      .emit(eventName, params)
  }
}
