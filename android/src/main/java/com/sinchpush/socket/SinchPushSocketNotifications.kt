package com.sinchpush.socket

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

internal object SinchPushSocketNotifications {

    const val CHANNEL_ID = "com.sinch.push.socket"
    const val CHANNEL_NAME = "Sinch Push (socket)"
    const val CHANNEL_DESCRIPTION =
        "Persistent delivery channel notifications from the Sinch push socket."

    /**
     * Relay messages get their own channel: the service channel above is
     * `IMPORTANCE_LOW` (right for the ongoing foreground notification) and on O+
     * the channel's importance wins over the builder's priority, so a message
     * posted there never reaches the screen. A new id because Android never
     * raises the importance of an existing channel.
     */
    const val MESSAGE_CHANNEL_ID = "com.sinch.push.socket.messages"
    const val MESSAGE_CHANNEL_NAME = "Sinch messages"
    const val MESSAGE_CHANNEL_DESCRIPTION = "Messages delivered by the Sinch push socket."

    const val SERVICE_CHANNEL_IMPORTANCE = NotificationManager.IMPORTANCE_LOW
    const val MESSAGE_CHANNEL_IMPORTANCE = NotificationManager.IMPORTANCE_HIGH
    const val MESSAGE_PRIORITY = NotificationCompat.PRIORITY_HIGH

    const val FOREGROUND_NOTIFICATION_ID = 0x534E_434E // 'SNCN'

    /** The channel of the ongoing foreground-service notification. */
    fun ensureChannel(context: Context) {
        createChannel(context, CHANNEL_ID, CHANNEL_NAME, CHANNEL_DESCRIPTION, SERVICE_CHANNEL_IMPORTANCE)
    }

    /** The channel relay messages are posted on; safe to call before every post. */
    fun ensureMessageChannel(context: Context) {
        createChannel(
            context,
            MESSAGE_CHANNEL_ID,
            MESSAGE_CHANNEL_NAME,
            MESSAGE_CHANNEL_DESCRIPTION,
            MESSAGE_CHANNEL_IMPORTANCE,
        )
    }

    private fun createChannel(context: Context, id: String, name: String, description: String, importance: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(id, name, importance).apply {
            this.description = description
            setShowBadge(id == MESSAGE_CHANNEL_ID)
        }
        manager.createNotificationChannel(channel)
    }

    fun hasPostNotificationsPermission(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            context,
            android.Manifest.permission.POST_NOTIFICATIONS,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    fun foregroundNotification(context: Context, text: String): android.app.Notification {
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle("Sinch Push")
            .setContentText(text)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setShowWhen(false)
        return builder.build()
    }

    /**
     * Posts the notification for ([tag], [id]) - a second post with the same pair
     * replaces the first (SB-65).
     *
     * @return whether one was actually posted. The `DISPLAYED` report is
     *   conditional on that: a notification the platform refused (no
     *   `POST_NOTIFICATIONS`, a throwing `NotificationManager`) was never
     *   shown, and reporting it as displayed would put a false record in the
     *   upstream sink of what the user actually saw.
     */
    // notify() needs POST_NOTIFICATIONS on API 33+; hasPostNotificationsPermission() below guards it.
    @SuppressLint("MissingPermission")
    fun show(
        context: Context,
        title: String?,
        body: String?,
        id: Int,
        alert: Boolean = true,
        tag: String? = null,
    ): Boolean {
        if (!hasPostNotificationsPermission(context)) return false

        // SB-36: an empty title is the same bytes as an absent one, so the app
        // label is rendered rather than an empty title - and the message model
        // has already mapped it to null before reaching here.
        val resolvedTitle = title?.takeIf { it.isNotEmpty() }
            ?: context.applicationInfo.loadLabel(context.packageManager).toString()
        val resolvedBody = body?.takeIf { it.isNotEmpty() }

        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val contentIntent = launchIntent?.let {
            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            PendingIntent.getActivity(
                context,
                id,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        ensureMessageChannel(context)
        val builder = NotificationCompat.Builder(context, MESSAGE_CHANNEL_ID)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(resolvedTitle)
            .setContentText(resolvedBody)
            .setStyle(NotificationCompat.BigTextStyle().bigText(resolvedBody))
            .setAutoCancel(true)
            .setPriority(MESSAGE_PRIORITY)
            // SB-63: every socket notification shares one group, so a replayed
            // burst stacks (Android also auto-groups from four notifications on;
            // no summary is posted here).
            .setGroup(SocketSpec.NOTIFICATION_GROUP)
            .apply { contentIntent?.let { setContentIntent(it) } }
        // SB-63: inside the alert window the notification is posted, but silent.
        if (!alert) silence(builder)

        // runCatching, and its result returned: a NotificationManager that throws
        // means nothing was displayed, which the caller has to know before it
        // reports DISPLAYED.
        return runCatching {
            NotificationManagerCompat.from(context).notify(tag, id, builder.build())
        }.isSuccess
    }

    /**
     * `setSilent` is androidx.core 1.8+; a host that pins an older core gets
     * the equivalent pre-1.8 pair instead of a `NoSuchMethodError`. Socket
     * messages are presented like an FCM push (heads-up, sound) on a
     * high-importance channel, so this is what keeps a message inside the
     * alert window quiet: the channel itself no longer does.
     */
    private fun silence(builder: NotificationCompat.Builder) {
        try {
            builder.setSilent(true)
        } catch (_: NoSuchMethodError) {
            // On O+ sound comes from the channel, so only the group alert behaviour silences it.
            builder.setOnlyAlertOnce(true).setSound(null).setVibrate(null)
                .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_SUMMARY)
        }
    }

    fun showLocal(context: Context, title: String?, body: String?, data: Map<String, String>) {
        val id = stableId(data, title, body)
        show(context, title, body, id)
    }

    private fun stableId(data: Map<String, String>, title: String?, body: String?): Int {
        val key = data["id"]
            ?: data["messageId"]
            ?: data["message_id"]
            ?: (title.orEmpty() + "|" + body.orEmpty())
        var h = 0
        for (c in key) {
            h = h * 31 + c.code
        }
        // Avoid colliding with the foreground notification id.
        return (h and 0x7FFF_FFFE) + 1
    }
}