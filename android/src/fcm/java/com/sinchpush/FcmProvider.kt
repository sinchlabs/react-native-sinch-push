package com.sinchpush

import com.google.android.gms.tasks.Tasks
import com.google.firebase.messaging.FirebaseMessaging
import java.util.concurrent.TimeUnit

/**
 * Runtime bridge to Firebase Cloud Messaging.
 *
 * Detection is intentionally reflection-free (the [SinchPushFirebaseMessagingService]
 * subclass already drags `FirebaseMessagingService` into the compile classpath
 * when this source-set is included), but every method here is a no-op if the
 * host app has not actually wired up firebase-messaging at runtime.
 *
 * Note: Firebase does NOT expose a "token refreshed" callback on the
 * [FirebaseMessaging] client. Token rotation is delivered exclusively through
 * [com.google.firebase.messaging.FirebaseMessagingService.onNewToken], which
 * [SinchPushFirebaseMessagingService] already routes into [SinchPushEmitter].
 * This provider is therefore only responsible for the initial token fetch.
 *
 * Source-set gated by `android/build.gradle`; only compiled when
 * `SinchPush_firebaseMessaging` is `optional` or `required`.
 */
internal object FcmProvider {

  private const val TOKEN_FETCH_TIMEOUT_SECONDS = 10L

  /**
   * Best-effort fetch of the current FCM device token. Returns `null` when FCM
   * is not available (no class on runtime classpath, no Play Services, no
   * `google-services.json`, missing `INTERNET` permission, etc.).
   */
  fun fetchTokenBlocking(): String? {
    return try {
      val task = FirebaseMessaging.getInstance().token
      Tasks.await(task, TOKEN_FETCH_TIMEOUT_SECONDS, TimeUnit.SECONDS)
    } catch (t: Throwable) {
      null
    }
  }

  /**
   * Fetches the current token (async) and forwards it to [SinchPushEmitter].
   * No-op if [isAvailable] returns false. Token refreshes are handled by
   * [SinchPushFirebaseMessagingService.onNewToken].
   */
  fun fetchAndListen() {
    if (!isAvailable()) return
    try {
      FirebaseMessaging.getInstance().token
        .addOnSuccessListener { token -> SinchPushEmitter.onNewToken(token) }
        .addOnFailureListener {
          // swallow — no retry here; a future process start or the
          // FirebaseMessagingService.onNewToken callback will pick up the token.
        }
    } catch (_: Throwable) {
      // FirebaseMessaging can throw synchronously when Google Play Services is
      // unavailable on the device or the app has not finished initializing.
    }
  }

  /**
   * True when Firebase Messaging is on the runtime classpath. We probe via the
   * static class lookup so hosts without firebase-messaging (e.g. an `none`
   * build, or a `required` build that was somehow stripped) degrade cleanly.
   */
  fun isAvailable(): Boolean = try {
    Class.forName("com.google.firebase.messaging.FirebaseMessaging")
    true
  } catch (_: ClassNotFoundException) {
    false
  } catch (_: Throwable) {
    false
  }
}
