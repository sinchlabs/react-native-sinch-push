package com.sinchpush

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap

class SinchPushModule(reactContext: ReactApplicationContext) :
  ReactContextBaseJavaModule(reactContext) {

  private val impl = SinchPushModuleImpl(reactContext)

  override fun getName(): String = SinchPushModuleImpl.NAME

  @ReactMethod
  fun getDeviceToken(promise: Promise) = impl.getDeviceToken(promise)

  @ReactMethod
  fun registerForToken(promise: Promise) = impl.registerForToken(promise)

  @ReactMethod
  fun getInstallationId(promise: Promise) = impl.getInstallationId(promise)

  @ReactMethod
  fun getDeviceInfo(promise: Promise) = impl.getDeviceInfo(promise)

  @ReactMethod
  fun setRelayEnabled(enabled: Boolean?, promise: Promise) = impl.setRelayEnabled(enabled, promise)

  @ReactMethod
  fun isRelayEnabled(promise: Promise) = impl.isRelayEnabled(promise)

  @ReactMethod
  fun startPushSocket(config: ReadableMap?, promise: Promise) =
    impl.startPushSocket(config, promise)

  @ReactMethod
  fun stopPushSocket(promise: Promise) = impl.stopPushSocket(promise)

  @ReactMethod
  fun getPushSocketState(promise: Promise) = impl.getPushSocketState(promise)

  @ReactMethod
  fun getPendingPushMessages(promise: Promise) = impl.getPendingPushMessages(promise)

  @ReactMethod
  fun clearPendingPushMessages(promise: Promise) = impl.clearPendingPushMessages(promise)

  @ReactMethod
  fun reportPushMessageStatus(messageId: String?, status: String?, promise: Promise) =
    impl.reportPushMessageStatus(messageId, status, promise)

  @ReactMethod
  fun setSocketHandlerRegistered(registered: Boolean?, promise: Promise) =
    impl.setSocketHandlerRegistered(registered, promise)

  @ReactMethod
  fun displayNotification(title: String?, body: String?, data: ReadableMap?, promise: Promise) =
    impl.displayNotification(title, body, data, promise)

  @ReactMethod
  fun getReportOutbox(promise: Promise) = impl.getReportOutbox(promise)

  @ReactMethod
  fun removeReportOutboxEntries(entries: ReadableArray?, promise: Promise) =
    impl.removeReportOutboxEntries(entries, promise)

  @ReactMethod
  fun clearReportOutbox(promise: Promise) = impl.clearReportOutbox(promise)

  @ReactMethod
  fun completeBackgroundWake(wakeId: String, sent: Boolean, promise: Promise) =
    impl.completeBackgroundWake(wakeId, sent, promise)

  @ReactMethod
  fun configureSharedReports(appGroup: String?, promise: Promise) =
    impl.configureSharedReports(appGroup, promise)

  @ReactMethod
  fun setSharedReportSession(record: ReadableMap?, promise: Promise) =
    impl.setSharedReportSession(record, promise)
}