package com.sinchpush

import android.content.Intent
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.sinchpush.socket.NativeReports
import com.sinchpush.socket.SharedReportOutbox
import com.sinchpush.socket.SharedSeenSet

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

  /**
   * Every FCM intent reaches this first, including a `notification` + `data`
   * message that the system displays itself while the app is backgrounded or
   * killed - [onMessageReceived] is *not* called for that one. The relay is off
   * by default and the backend then sends exactly that shape, so this is where
   * its delivery is recorded. Only a message intent is recorded - a token or
   * `deleted_messages` intent is passed straight through. The decision and the
   * order live in [ProviderPushIntent].
   *
   * The report is queued (durably) and the system display is left entirely to
   * `super`; the upload runs after it, so a slow network never delays the
   * notification. The same message may also reach [onMessageReceived] (data-only,
   * or the app in the foreground): the outbox remembers the key it queued, so
   * that second sight queues nothing, and the seen set is only marked once
   * `super` is done - marking it earlier would make [onMessageReceived] drop the
   * message and JS would never hear of it.
   */
  override fun handleIntent(intent: Intent) {
    ProviderPushIntent(
      seen = SharedSeenSet.get(applicationContext),
      outbox = SharedReportOutbox.get(applicationContext),
      onReportQueued = SinchPushEmitter::onReportQueued,
      flush = { NativeReports.flush(applicationContext) },
      ensureChannel = { SinchPushNotifications.ensureChannel(applicationContext) },
    ).handle(intent.action, intent::getStringExtra) { super.handleIntent(intent) }
  }

  override fun onMessageReceived(message: RemoteMessage) {
    super.onMessageReceived(message)
    SinchPushNotifications.ensureChannel(applicationContext)
    var queued = false
    val notification = message.notification
    // One seen set per process, shared with the socket client: a message the
    // socket (or an earlier FCM delivery) already handled is dropped here - no
    // JS event, no notification - and a new one is marked so the socket's copy
    // becomes the duplicate.
    PushMessageHandler(
      dedupe = PushDedupe(
        seen = SharedSeenSet.get(applicationContext),
        outbox = SharedReportOutbox.get(applicationContext),
        onQueued = {
          queued = true
          SinchPushEmitter.onReportQueued()
        },
      ),
      emit = { data, title, body ->
        SinchPushEmitter.onMessage(data = data, title = title, body = body)
      },
      // A Sinch message is rendered under the same identity the socket uses
      // (tag = message_id, one constant id), so a second copy replaces rather
      // than duplicates; one with no id keeps the tag + id derived from FCM's
      // own `messageId`.
      show = { title, body, data, tag, notificationId ->
        SinchPushNotifications.show(
          context = applicationContext,
          title = title,
          body = body,
          data = data,
          tag = tag,
          notificationId = notificationId,
        )
      },
    ).handle(
      fcmMessageId = message.messageId,
      data = message.data,
      title = notification?.title,
      body = notification?.body,
    )
    // After the message was emitted and rendered, so the network never delays it.
    if (queued) NativeReports.flush(applicationContext)
  }
}
