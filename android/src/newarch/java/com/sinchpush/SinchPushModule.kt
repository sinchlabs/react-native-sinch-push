package com.sinchpush

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap

class SinchPushModule(reactContext: ReactApplicationContext) :
  NativeSinchPushSpec(reactContext) {

  private val impl = SinchPushModuleImpl(reactContext)

  override fun getName(): String = SinchPushModuleImpl.NAME

  override fun getDeviceToken(promise: Promise) = impl.getDeviceToken(promise)

  override fun registerForToken(promise: Promise) = impl.registerForToken(promise)

  override fun getInstallationId(promise: Promise) = impl.getInstallationId(promise)

  override fun getDeviceInfo(promise: Promise) = impl.getDeviceInfo(promise)

  override fun setRelayEnabled(enabled: Boolean, promise: Promise) =
    impl.setRelayEnabled(enabled, promise)

  override fun isRelayEnabled(promise: Promise) = impl.isRelayEnabled(promise)

  override fun startPushSocket(config: ReadableMap?, promise: Promise) =
    impl.startPushSocket(config, promise)

  override fun stopPushSocket(promise: Promise) = impl.stopPushSocket(promise)

  override fun getPushSocketState(promise: Promise) = impl.getPushSocketState(promise)

  override fun getPendingPushMessages(promise: Promise) = impl.getPendingPushMessages(promise)

  override fun clearPendingPushMessages(promise: Promise) = impl.clearPendingPushMessages(promise)

  override fun reportPushMessageStatus(messageId: String, status: String, promise: Promise) =
    impl.reportPushMessageStatus(messageId, status, promise)

  override fun setSocketHandlerRegistered(registered: Boolean, promise: Promise) =
    impl.setSocketHandlerRegistered(registered, promise)

  override fun displayNotification(title: String?, body: String?, data: ReadableMap?, promise: Promise) =
    impl.displayNotification(title, body, data, promise)

  override fun getReportOutbox(promise: Promise) = impl.getReportOutbox(promise)

  override fun removeReportOutboxEntries(entries: ReadableArray, promise: Promise) =
    impl.removeReportOutboxEntries(entries, promise)

  override fun clearReportOutbox(promise: Promise) = impl.clearReportOutbox(promise)

  override fun completeBackgroundWake(wakeId: String, sent: Boolean, promise: Promise) =
    impl.completeBackgroundWake(wakeId, sent, promise)

  override fun configureSharedReports(appGroup: String?, promise: Promise) =
    impl.configureSharedReports(appGroup, promise)

  override fun setSharedReportSession(record: ReadableMap?, promise: Promise) =
    impl.setSharedReportSession(record, promise)

  override fun addListener(eventName: String?) = impl.addListener(eventName)

  override fun removeListeners(count: Double) = impl.removeListeners(count)
}