package com.sinchpush

import android.Manifest
import android.app.Activity
import android.os.Build
import android.util.Log
import androidx.core.app.ActivityCompat
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import com.sinchpush.socket.AndroidDeviceEnvironment
import com.sinchpush.socket.AndroidSocketLogger
import com.sinchpush.socket.DeviceInfoChanges
import com.sinchpush.socket.ForegroundServiceRefusedException
import com.sinchpush.socket.InstallationIdStore
import com.sinchpush.socket.InstallationIdUnavailableException
import com.sinchpush.socket.PushSocketConfig
import com.sinchpush.socket.NativeReports
import com.sinchpush.socket.RelayDisabledException
import com.sinchpush.socket.RelaySwitchController
import com.sinchpush.socket.ReportFlusher
import com.sinchpush.socket.SharedReportOutbox
import com.sinchpush.socket.SharedReportSession
import com.sinchpush.socket.SinchPushSocketController
import com.sinchpush.socket.SinchPushSocketNotifications
import com.sinchpush.socket.SinchPushSocketStore
import com.sinchpush.socket.DeviceInfoPurpose
import com.sinchpush.socket.SystemDeviceInfoProvider
import com.sinchpush.socket.toJsMap
import com.sinchpush.socket.toWritableArray

class SinchPushModuleImpl(private val reactContext: ReactApplicationContext) {

  init {
    SinchPushEmitter.attachReactContext(reactContext)
    DeviceInfoChanges.attach(reactContext.applicationContext)
    if (BuildConfig.FCM_AVAILABLE) {
      // Notification channel must exist before posting (API 26+).
      SinchPushNotifications.ensureChannel(reactContext.applicationContext)
      // Trigger auto-detection of Firebase Cloud Messaging on module construction
      // (process start / JS context attach). The call is a no-op when firebase-messaging
      // is not on the runtime classpath, or when the library was built with
      // SinchPush_firebaseMessaging=none (no FCM source set).
      FcmBridge.fetchAndListen()
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
      FcmBridge.fetchAndListen()
      // Re-request permission in case the user previously denied and the
      // activity has changed.
      SinchPushNotifications.requestPermission(reactContext.currentActivity)
    }
    promise.resolve(null)
  }

  /**
   * The per-install id: a plain accessor over `InstallationIdStore`.
   *
   * Map unavailable storage to E_INSTALLATION_ID_UNAVAILABLE.
   */
  fun getInstallationId(promise: Promise) {
    try {
      promise.resolve(InstallationIdStore.get(reactContext.applicationContext).installationId())
    } catch (e: InstallationIdUnavailableException) {
      promise.reject("E_INSTALLATION_ID_UNAVAILABLE", e.message ?: "the installation id is unavailable", e)
    } catch (t: Throwable) {
      promise.reject("E_INSTALLATION_ID", t.message ?: t.javaClass.simpleName, t)
    }
  }

  /**
   * The facts `Subscribe` and `Hello` both carry, from the collectors `Hello` uses.
   *
   * Map unavailable storage to E_INSTALLATION_ID_UNAVAILABLE.
   */
  fun getDeviceInfo(promise: Promise) {
    try {
      val context = reactContext.applicationContext
      val info = SystemDeviceInfoProvider(
        AndroidDeviceEnvironment(context),
        AndroidSocketLogger,
        RelaySwitchController.switch(context),
      )
        .current(SinchPushSocketController.currentConfig(context), DeviceInfoPurpose.SUBSCRIBE)
      val map = Arguments.createMap()
      for ((key, value) in info.toJsMap()) map.putString(key, value)
      promise.resolve(map)
    } catch (e: InstallationIdUnavailableException) {
      promise.reject("E_INSTALLATION_ID_UNAVAILABLE", e.message ?: "the installation id is unavailable", e)
    } catch (t: Throwable) {
      promise.reject("E_DEVICE_INFO", t.message ?: t.javaClass.simpleName, t)
    }
  }

  /**
   * Turns the relay channel off or on for this install.
   *
   * Off stops the socket and disables the service component; on re-enables it
   * and starts nothing - the host calls `startPushSocket`.
   *
   * Rejects `E_SET_RELAY_ENABLED` when the choice did not reach storage: the
   * switch is applied for this process, but a restart will not see it.
   */
  fun setRelayEnabled(enabled: Boolean?, promise: Promise) {
    if (enabled == null) {
      promise.reject("E_SET_RELAY_ENABLED", "setRelayEnabled requires a boolean")
      return
    }
    try {
      settleRelaySwitch(RelaySwitchController.setEnabled(reactContext.applicationContext, enabled), promise)
    } catch (t: Throwable) {
      promise.reject("E_SET_RELAY_ENABLED", t.message ?: t.javaClass.simpleName, t)
    }
  }

  /** Whether the relay may run at all right now: the value JS last set, or the default. */
  fun isRelayEnabled(promise: Promise) {
    try {
      promise.resolve(RelaySwitchController.isEnabled(reactContext.applicationContext))
    } catch (t: Throwable) {
      promise.reject("E_RELAY_ENABLED", t.message ?: t.javaClass.simpleName, t)
    }
  }

  fun addListener(eventName: String?) {
  }

  fun removeListeners(count: Double) {
  }

  // --- Persistent push socket channel ---------------------------------------

  fun startPushSocket(config: ReadableMap?, promise: Promise) {
    try {
      val parsed = PushSocketConfig.fromReadableMap(config)
      val activity = reactContext.currentActivity
      if (activity != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        requestPostNotificationsPermission(activity)
      }
      SinchPushSocketController.start(reactContext.applicationContext, parsed)
      promise.resolve(null)
    } catch (e: RelayDisabledException) {
      // The relay is off: nothing was started and no socket state was written.
      promise.reject("E_RELAY_DISABLED", e.message, e)
    } catch (e: ForegroundServiceRefusedException) {
      // The platform would not start the foreground service that owns the socket.
      promise.reject("E_FGS_START_REFUSED", e.message, e)
    } catch (t: Throwable) {
      promise.reject("E_START_PUSH_SOCKET", t.message ?: t.javaClass.simpleName, t)
    }
  }

  fun stopPushSocket(promise: Promise) {
    try {
      SinchPushSocketController.stop(reactContext.applicationContext)
      promise.resolve(null)
    } catch (t: Throwable) {
      promise.reject("E_STOP_PUSH_SOCKET", t.message ?: t.javaClass.simpleName, t)
    }
  }

  fun getPushSocketState(promise: Promise) {
    promise.resolve(SinchPushSocketController.state().toWritableMap())
  }

  fun getPendingPushMessages(promise: Promise) {
    promise.resolve(toWritableArray(SinchPushSocketController.messages()))
  }

  fun clearPendingPushMessages(promise: Promise) {
    SinchPushSocketController.clearMessages()
    promise.resolve(null)
  }

  fun displayNotification(title: String?, body: String?, data: ReadableMap?, promise: Promise) {
    try {
      val metadata = mutableMapOf<String, String>()
      data?.let { source ->
        val iterator = source.keySetIterator()
        while (iterator.hasNextKey()) {
          val key = iterator.nextKey()
          val value = source.getString(key)
          if (value != null) metadata[key] = value
        }
      }
      SinchPushSocketNotifications.ensureChannel(reactContext.applicationContext)
      SinchPushSocketNotifications.showLocal(
        reactContext.applicationContext,
        title,
        body,
        metadata,
      )
      promise.resolve(null)
    } catch (t: Throwable) {
      promise.reject("E_DISPLAY_NOTIFICATION", t.message ?: t.javaClass.simpleName, t)
    }
  }

  /**
   * Forwards to the socket owner. A report with no owner rejects
   * (`E_NOT_RUNNING`) rather than resolving, so the host never believes a
   * DISPLAYED/DISMISSED was recorded when nothing could carry it. With an owner
   * but no live connection the client queues it in the persisted outbox.
   */
  fun reportPushMessageStatus(messageId: String?, status: String?, promise: Promise) {
    if (messageId.isNullOrEmpty()) {
      promise.reject("E_INVALID_MESSAGE_ID", "messageId is required")
      return
    }
    try {
      when (SinchPushSocketController.reportFromHost(messageId, status)) {
        SinchPushSocketController.HostReport.ACCEPTED -> promise.resolve(null)
        SinchPushSocketController.HostReport.INVALID_STATUS -> promise.reject(
          "E_INVALID_STATUS",
          "status must be 'displayed' or 'dismissed', got '$status'",
        )
        SinchPushSocketController.HostReport.NOT_RUNNING -> promise.reject(
          "E_NOT_RUNNING",
          "the push socket is not running; call startPushSocket first",
        )
      }
    } catch (t: Throwable) {
      promise.reject("E_REPORT_STATUS", t.message ?: t.javaClass.simpleName, t)
    }
  }

  /** Feeds the `whenUnhandled` display rule. */
  fun setSocketHandlerRegistered(registered: Boolean?, promise: Promise) {
    SinchPushSocketController.setHandlerRegistered(registered == true)
    promise.resolve(null)
  }

  /**
   * The provider-push reports waiting to be flushed, oldest first.
   *
   * Entries the native uploader is sending right now are left out, and the ones
   * returned are leased to JS for [JS_REPORT_LEASE_MS], so the two flushers do
   * not report the same delivery twice. A flush that gives up simply lets the
   * lease lapse.
   */
  fun getReportOutbox(promise: Promise) {
    val entries: WritableArray = Arguments.createArray()
    val claimed = SharedReportOutbox.get(reactContext.applicationContext)
      .claim(ReportFlusher.JS, JS_REPORT_LEASE_MS)
    for (entry in claimed) {
      val map: WritableMap = Arguments.createMap()
      map.putString("messageId", entry.messageId)
      map.putString("subscriberId", entry.subscriberId)
      map.putDouble("enqueuedAt", entry.enqueuedAtMs.toDouble())
      entries.pushMap(map)
    }
    promise.resolve(entries)
  }

  /** Drops the named reports; the rest keep their place. */
  fun removeReportOutboxEntries(entries: ReadableArray?, promise: Promise) {
    val keys = mutableListOf<Pair<String, String>>()
    if (entries != null) {
      for (index in 0 until entries.size()) {
        val entry: ReadableMap? = entries.getMap(index)
        if (entry == null) continue
        val messageId = entry.getString("messageId") ?: continue
        val subscriberId = entry.getString("subscriberId") ?: continue
        keys.add(messageId to subscriberId)
      }
    }
    SharedReportOutbox.get(reactContext.applicationContext).remove(keys)
    promise.resolve(null)
  }

  /** Drops every queued report. */
  fun clearReportOutbox(promise: Promise) {
    SharedReportOutbox.get(reactContext.applicationContext).clear()
    promise.resolve(null)
  }

  /** iOS only (answers a `SinchPushBackgroundWake`); Android never emits the event. */
  fun completeBackgroundWake(wakeId: String, sent: Boolean, promise: Promise) {
    promise.resolve(null)
  }

  /** iOS only (Notification Service Extension App Group); a no-op on Android. */
  fun configureSharedReports(appGroup: String?, promise: Promise) {
    promise.resolve(null)
  }

  /**
   * Mirrors `{ accessToken, reportBaseURL, userId, appId }` to app-private storage
   * so the FCM service can report a delivery with no JS runtime, or clears it
   * (`null`). A record without a token or a base URL clears too, like iOS.
   * Best-effort: a write that did not reach disk is logged, not rejected - the
   * worst outcome is a stale token, which the server answers `Unauthenticated`
   * and the outbox keeps for JS.
   */
  fun setSharedReportSession(record: ReadableMap?, promise: Promise) {
    try {
      val store = NativeReports.sessionStore(reactContext.applicationContext)
      val session = sharedReportSessionOf(record)
      val persisted = if (session == null) store.clear() else store.save(session)
      if (!persisted) Log.w(TAG, "the shared report session did not reach storage")
      promise.resolve(null)
    } catch (t: Throwable) {
      promise.reject("E_SET_REPORT_SESSION", t.message ?: t.javaClass.simpleName, t)
    }
  }

  private fun sharedReportSessionOf(record: ReadableMap?): SharedReportSession? {
    if (record == null) return null
    fun string(key: String): String =
      if (record.hasKey(key) && !record.isNull(key)) record.getString(key).orEmpty() else ""
    val token = string("accessToken")
    val base = string("reportBaseURL")
    if (token.isEmpty() || base.isEmpty()) return null
    return SharedReportSession(token, base, string("userId"), string("appId"))
  }

  private fun requestPostNotificationsPermission(activity: Activity) {
    if (ActivityCompat.checkSelfPermission(
        activity,
        Manifest.permission.POST_NOTIFICATIONS,
      ) == android.content.pm.PackageManager.PERMISSION_GRANTED
    ) {
      return
    }
    ActivityCompat.requestPermissions(
      activity,
      arrayOf(Manifest.permission.POST_NOTIFICATIONS),
      REQUEST_CODE_POST_NOTIFICATIONS,
    )
  }

  private fun tokenMap(token: String, type: String) = Arguments.createMap().apply {
    putString("token", token)
    putString("type", type)
  }

  companion object {
    const val NAME = "SinchPush"
    private const val TAG = "SinchPush"

    /**
     * Must outlast the JS flusher's worst case (up to five failed attempts with
     * 1-8 s jittered backoff between them, and the transport has no request
     * timeout of its own); short enough that a dead one lets go. A lease that
     * lapses mid-flush costs a duplicate report, never a lost one.
     */
    private const val JS_REPORT_LEASE_MS = 120_000L
    private const val REQUEST_CODE_POST_NOTIFICATIONS = 0x534E_434E // 'SNCN'
  }
}

/**
 * The bridge's answer to an applied relay switch.
 *
 * A value that reached storage resolves; one that did not rejects with
 * `E_SET_RELAY_ENABLED`: the switch is applied for this process, and the host
 * has to know that a restart will not see the choice.
 */
internal fun settleRelaySwitch(persisted: Boolean, promise: Promise) {
  if (persisted) {
    promise.resolve(null)
  } else {
    promise.reject("E_SET_RELAY_ENABLED", "relay switch applied but not persisted")
  }
}