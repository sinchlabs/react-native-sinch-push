package com.sinchpush

import android.util.Log
import com.sinchpush.socket.ReportOutbox
import com.sinchpush.socket.SeenSet

/**
 * What [SinchPushFirebaseMessagingService.handleIntent] does with one intent,
 * without Firebase or `Intent`, so the JVM can test it (SB-67).
 *
 * `handleIntent` sees every intent Firebase's receiver forwards, not only
 * messages: a new token, `deleted_messages` and send events arrive the same way.
 * Only a message ([isMessage]) may queue a delivery report.
 *
 * The order is the contract:
 *  1. queue the report (durably), unless the socket already delivered the message;
 *  2. `super.handleIntent` - the system display, or `onMessageReceived`;
 *  3. mark the message seen - earlier, `onMessageReceived` would drop it and JS
 *     would never hear of it;
 *  4. flush the upload - last, so a slow network never delays the notification.
 */
internal class ProviderPushIntent(
    private val seen: SeenSet,
    private val outbox: ReportOutbox,
    /** Tells a live JS runtime a report was queued. */
    private val onReportQueued: () -> Unit,
    /** Uploads the outbox natively; runs only after a report was queued. */
    private val flush: () -> Unit,
    private val ensureChannel: () -> Unit = {},
) {

    /**
     * [extra] reads a string extra of the intent; [superHandle] is
     * `super.handleIntent(intent)`. Never throws on its own account: only what
     * [superHandle] throws propagates, after the bookkeeping has run.
     */
    fun handle(action: String?, extra: (String) -> String?, superHandle: () -> Unit) {
        if (!isMessage(action, extra(MESSAGE_TYPE_KEY))) {
            superHandle()
            return
        }
        val messageId = extra(PushDedupe.MESSAGE_ID_KEY)?.takeIf { it.isNotEmpty() }
        val subscriberId = extra(PushDedupe.SUBSCRIBER_ID_KEY)?.takeIf { it.isNotEmpty() }
        var queued = false
        try {
            ensureChannel()
            if (messageId != null && subscriberId != null) queued = queue(messageId, subscriberId)
        } catch (t: Throwable) {
            Log.w(TAG, "could not record the delivery of a push", t)
        }
        try {
            superHandle()
        } finally {
            try {
                // Displayed by the system, or handled by onMessageReceived: either way
                // the socket's copy of this message is a duplicate from here on.
                if (messageId != null) seen.add(messageId)
                if (queued) flush()
            } catch (t: Throwable) {
                Log.w(TAG, "could not upload the delivery report of a push", t)
            }
        }
    }

    /** Queues the report unless the socket already delivered (and reports) this message. */
    private fun queue(messageId: String, subscriberId: String): Boolean {
        if (seen.contains(messageId)) return false
        outbox.enqueue(messageId, subscriberId) ?: return false
        // A live JS runtime flushes it too (it leases what it reads, so the two do
        // not send the same entry); with none, this is a no-op.
        onReportQueued()
        return true
    }

    companion object {
        /** The action of every intent Firebase's receiver forwards to the service. */
        const val ACTION_RECEIVE = "com.google.android.c2dm.intent.RECEIVE"
        const val MESSAGE_TYPE_KEY = "message_type"

        /** The only `message_type` of a message (`deleted_messages`, `send_event`, `send_error` are not). */
        private const val MESSAGE_TYPE_GCM = "gcm"

        private const val TAG = "SinchPushFcm"

        /** `true` for a message: the c2dm receive action, with no `message_type` or `gcm`. */
        fun isMessage(action: String?, messageType: String?): Boolean =
            action == ACTION_RECEIVE && (messageType == null || messageType == MESSAGE_TYPE_GCM)
    }
}
