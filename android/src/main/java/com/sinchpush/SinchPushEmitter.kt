package com.sinchpush

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap

object SinchPushEmitter {

  const val EVENT_TOKEN_RECEIVED = "SinchPush:onTokenReceived"
  const val EVENT_PUSH_RECEIVED = "SinchPush:onPushReceived"
  const val EVENT_SOCKET_MESSAGE = "SinchPush:onSocketMessage"
  const val EVENT_SOCKET_STATE = "SinchPush:onSocketState"
  const val EVENT_DEVICE_INFO_CHANGED = "SinchPush:onDeviceInfoChanged"
  const val EVENT_REPORT_QUEUED = "SinchPush:onReportQueued"

  const val TOKEN_TYPE_FCM = "fcm"

  @Volatile
  private var reactContext: ReactApplicationContext? = null

  @Volatile
  var latestToken: String? = null
    private set

  @Volatile
  var latestTokenType: String = TOKEN_TYPE_FCM
    private set

  @Volatile
  private var latestSocketState: WritableMap? = null

  @Synchronized
  fun attachReactContext(context: ReactApplicationContext) {
    reactContext = context
    latestToken?.let { emitToken(it, latestTokenType) }
    latestSocketState?.let { emit(EVENT_SOCKET_STATE, it) }
  }

  @Synchronized
  fun detachReactContext(context: ReactApplicationContext) {
    if (reactContext === context) {
      reactContext = null
    }
  }

  fun onNewToken(token: String, type: String = TOKEN_TYPE_FCM) {
    latestToken = token
    latestTokenType = type
    emitToken(token, type)
  }

  fun onMessage(data: Map<String, String>, title: String?, body: String?) {
    val payload: WritableMap = Arguments.createMap()
    val dataMap: WritableMap = Arguments.createMap()
    for ((key, value) in data) {
      dataMap.putString(key, value)
    }
    payload.putMap("data", dataMap)
    payload.putString("source", latestTokenType)
    data["identity"]?.let { payload.putString("identity", it) }
    title?.let { payload.putString("title", title) }
    body?.let { payload.putString("body", body) }
    emit(EVENT_PUSH_RECEIVED, payload)
  }

  fun onSocketMessage(message: WritableMap) {
    emit(EVENT_SOCKET_MESSAGE, message)
  }

  fun onSocketState(state: WritableMap) {
    latestSocketState = state
    emit(EVENT_SOCKET_STATE, state)
  }

  /** Tells JS a provider-push report was queued; JS reads the outbox through the bridge. */
  fun onReportQueued() {
    emit(EVENT_REPORT_QUEUED, Arguments.createMap())
  }

  /**
   * Tells JS the device info may have changed. The payload is informational -
   * JS re-reads `getDeviceInfo()` - and the event is not buffered for replay on
   * attach: JS compares its fingerprint at `initialize`.
   *
   * @return whether it was handed to a React context; `false` leaves the caller
   *   free to offer it again.
   */
  fun onDeviceInfoChanged(backgroundService: String): Boolean {
    val context = reactContext ?: return false
    val payload: WritableMap = Arguments.createMap()
    payload.putString("backgroundService", backgroundService)
    return try {
      context.emitDeviceEvent(EVENT_DEVICE_INFO_CHANGED, payload)
      true
    } catch (t: Throwable) {
      false
    }
  }

  fun emitToken(token: String, type: String) {
    val payload: WritableMap = Arguments.createMap()
    payload.putString("token", token)
    payload.putString("type", type)
    emit(EVENT_TOKEN_RECEIVED, payload)
  }

  private fun emit(eventName: String, params: ReadableMap) {
    val context = reactContext ?: return
    // emitDeviceEvent is the bridgeless-safe path.
    try {
      context.emitDeviceEvent(eventName, params)
    } catch (t: Throwable) {
      // No JS runtime attached yet — buffered replay on attach covers it.
    }
  }
}