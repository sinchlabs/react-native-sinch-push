package com.sinchpush

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Library-owned [FirebaseMessagingService] that forwards token events and inbound
 * messages to [SinchPushEmitter], and posts a system notification so that
 * foreground pushes are surfaced in the tray. This is the only way Android
 * delivers FCM pushes to an app while it is backgrounded or terminated, and
 * is the entry point for token refresh callbacks that fire while the process
 * is alive.
 *
 * Source-set gated by `android/build.gradle` (only compiled when
 * `SinchPush_firebaseMessaging` is `optional` or `required`). When the host app
 * does not actually include firebase-messaging at runtime, this class will not
 * be instantiated (no `MESSAGING_EVENT` broadcast is ever dispatched).
 *
 * Hosts that already declare their own `FirebaseMessagingService` can disable
 * this one by setting `SinchPush_firebaseMessaging = "none"` in the host
 * project — both services would otherwise receive the same broadcast.
 */
class SinchPushFirebaseMessagingService : FirebaseMessagingService() {

  override fun onNewToken(token: String) {
    super.onNewToken(token)
    SinchPushEmitter.onNewToken(token)
  }

  override fun onMessageReceived(message: RemoteMessage) {
    super.onMessageReceived(message)
    val notification = message.notification
    SinchPushEmitter.onMessage(
      data = message.data,
      title = notification?.title,
      body = notification?.body,
    )
    // Surface the push in the system tray regardless of app state. When the
    // app is backgrounded or terminated, FCM's own delivery of a
    // `notification`-payload message would have already shown one via the
    // system; calling `show` again is harmless because the tag+id pair is
    // stable per `messageId`.
    SinchPushNotifications.show(
      context = applicationContext,
      title = notification?.title,
      body = notification?.body,
      data = message.data,
      tag = message.messageId,
      notificationId = notificationIdFor(message.messageId),
    )
  }

  private fun notificationIdFor(messageId: String?): Int {
    if (messageId.isNullOrEmpty()) return DEFAULT_NOTIFICATION_ID
    var h = 0
    for (c in messageId) {
      h = h * 31 + c.code
    }
    // Coalesce to the default id space — keeps recent pushes from saturating
    // the tray and ensures taps on a single thread land on the same id.
    return h and 0x7FFF_FFFF
  }

  companion object {
    private const val DEFAULT_NOTIFICATION_ID = 1
  }
}
