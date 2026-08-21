package com.sinchpush

import android.Manifest
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * Posts a system notification so that pushes received via
 * [com.google.firebase.messaging.FirebaseMessagingService.onMessageReceived]
 * are surfaced in the tray while the app is in foreground (or its process is
 * otherwise alive). When the app is backgrounded or terminated, FCM's own
 * delivery of `notification`-payload messages already displays a notification
 * via the system — this helper does not need to intervene.
 *
 * Source-set gated by `android/build.gradle`; only compiled when
 * `SinchPush_firebaseMessaging` is `optional` or `required`.
 */
internal object SinchPushNotifications {

  const val DEFAULT_CHANNEL_ID = "com.sinch.push.default"
  const val DEFAULT_CHANNEL_NAME = "Default"
  const val DEFAULT_CHANNEL_DESCRIPTION =
    "Notifications delivered by Sinch Push (FCM)."

  /**
   * Creates the default notification channel. Idempotent — Android ignores
   * re-creation when the channel already exists with the same attributes.
   */
  fun ensureChannel(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val manager = context.getSystemService(NotificationManager::class.java) ?: return
    val channel = NotificationChannel(
      DEFAULT_CHANNEL_ID,
      DEFAULT_CHANNEL_NAME,
      NotificationManager.IMPORTANCE_DEFAULT,
    ).apply {
      description = DEFAULT_CHANNEL_DESCRIPTION
      enableLights(true)
      enableVibration(true)
    }
    manager.createNotificationChannel(channel)
  }

  /**
   * Asks the host activity for the POST_NOTIFICATIONS runtime permission
   * (required on API 33+). No-op on older API levels and when no Activity is
   * currently attached.
   */
  fun requestPermission(activity: Activity?) {
    if (activity == null) return
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    val already = ContextCompat.checkSelfPermission(
      activity,
      Manifest.permission.POST_NOTIFICATIONS,
    )
    if (already == PackageManager.PERMISSION_GRANTED) return
    activity.requestPermissions(
      arrayOf(Manifest.permission.POST_NOTIFICATIONS),
      REQUEST_CODE_POST_NOTIFICATIONS,
    )
  }

  /**
   * Builds and posts a notification using the data extracted from an FCM
   * [com.google.firebase.messaging.RemoteMessage]. Silently no-ops if the
   * app does not currently hold the POST_NOTIFICATIONS permission (e.g. the
   * user denied it).
   */
  fun show(
    context: Context,
    title: String?,
    body: String?,
    data: Map<String, String>,
    tag: String?,
    notificationId: Int,
  ) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      val granted = ContextCompat.checkSelfPermission(
        context,
        Manifest.permission.POST_NOTIFICATIONS,
      ) == PackageManager.PERMISSION_GRANTED
      if (!granted) return
    }

    val resolvedTitle = title
      ?: data["title"]
      ?: data["sinch_title"]
      ?: run {
        val labelRes = context.applicationInfo.labelRes
        if (labelRes != 0) context.getString(labelRes)
        else context.applicationInfo.loadLabel(context.packageManager).toString()
      }
    val resolvedBody = body
      ?: data["body"]
      ?: data["text"]
      ?: data["message"]

    val launchIntent = context.packageManager
      .getLaunchIntentForPackage(context.packageName)
    val contentIntent = launchIntent?.let {
      it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
      PendingIntent.getActivity(
        context,
        notificationId,
        it,
        pendingIntentFlags(updateCurrent = true),
      )
    }

    val builder = NotificationCompat.Builder(context, DEFAULT_CHANNEL_ID)
      .setSmallIcon(context.applicationInfo.icon)
      .setContentTitle(resolvedTitle)
      .setContentText(resolvedBody)
      .setStyle(NotificationCompat.BigTextStyle().bigText(resolvedBody))
      .setPriority(NotificationCompat.PRIORITY_DEFAULT)
      .setAutoCancel(true)
      .apply { contentIntent?.let { setContentIntent(it) } }

    runCatching {
      NotificationManagerCompat.from(context).notify(tag, notificationId, builder.build())
    }
  }

  private fun pendingIntentFlags(updateCurrent: Boolean): Int {
    var flags = PendingIntent.FLAG_IMMUTABLE
    if (updateCurrent) flags = flags or PendingIntent.FLAG_UPDATE_CURRENT
    return flags
  }

  private const val REQUEST_CODE_POST_NOTIFICATIONS = 0x534E_4348 // 'SNCH'
}
