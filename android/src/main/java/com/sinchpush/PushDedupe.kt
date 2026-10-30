package com.sinchpush

import com.sinchpush.socket.ReportOutbox
import com.sinchpush.socket.ReportOutboxEntry
import com.sinchpush.socket.SeenSet
import com.sinchpush.socket.SinchNotificationIdentity
import com.sinchpush.socket.SocketSpec

/**
 * What the FCM service does with one data message (SB-64, SB-65).
 *
 * Nothing here touches Firebase or Android, so the decision is testable on the
 * JVM; [SinchPushFirebaseMessagingService] only feeds it a `RemoteMessage`'s
 * fields.
 */
internal sealed class PushDecision {
    /** A copy of a message another channel already delivered: no JS event, no notification. */
    object Drop : PushDecision()

    /**
     * Surface it. A Sinch message ([tag] non-null) is rendered under
     * `(tag = message_id, id = SINCH_MESSAGE_NOTIFICATION_ID)`; one without an
     * id ([tag] null) keeps the legacy identity.
     */
    data class Render(val tag: String?) : PushDecision()
}

internal class PushDedupe(
    private val seen: SeenSet,
    private val outbox: ReportOutbox? = null,
    private val onQueued: (ReportOutboxEntry) -> Unit = {},
) {

    /**
     * The dedupe key is `data["sinch.push.message_id"]` (= sinch-push's
     * trackingId = the relay's `message_id`). Unseen ids are marked as part of
     * the decision, so the socket's copy of the same message is then a dedupe
     * hit. No key, or an empty one, means no dedupe.
     */
    fun decide(data: Map<String, String>): PushDecision {
        val id = data[MESSAGE_ID_KEY]?.takeIf { it.isNotEmpty() } ?: return PushDecision.Render(tag = null)
        if (!seen.add(id)) return PushDecision.Drop
        queueReport(id, data)
        return PushDecision.Render(tag = id)
    }

    /** Queues the delivery report for a fresh provider push that names its subscriber. */
    private fun queueReport(messageId: String, data: Map<String, String>) {
        val subscriberId = data[SUBSCRIBER_ID_KEY]?.takeIf { it.isNotEmpty() } ?: return
        val entry = outbox?.enqueue(messageId, subscriberId) ?: return
        onQueued(entry)
    }

    companion object {
        /** The key sinch-push puts in the push metadata, so in the FCM `data`. */
        const val MESSAGE_ID_KEY = "sinch.push.message_id"

        /** The subscriber the push was addressed to, in the same metadata. */
        const val SUBSCRIBER_ID_KEY = "sinch.push.subscriber_id"
    }
}

/**
 * [PushDedupe] plus the two things the FCM service does with a message that is
 * not a copy: emit it to JS and render it.
 *
 * The side effects are lambdas so a JVM test can count them.
 */
internal class PushMessageHandler(
    private val dedupe: PushDedupe,
    private val emit: (data: Map<String, String>, title: String?, body: String?) -> Unit,
    private val show: (
        title: String?,
        body: String?,
        data: Map<String, String>,
        tag: String?,
        notificationId: Int,
    ) -> Unit,
) {

    /** [fcmMessageId] is `RemoteMessage.messageId`, used only for a message with no Sinch id. */
    fun handle(fcmMessageId: String?, data: Map<String, String>, title: String?, body: String?) {
        val decision = dedupe.decide(data)
        if (decision is PushDecision.Drop) return
        val tag = (decision as PushDecision.Render).tag
        emit(data, title, body)
        if (tag != null) {
            val identity = SinchNotificationIdentity.of(tag)
            show(title, body, data, identity.tag, identity.id)
        } else {
            // Legacy behaviour for a push with no Sinch message id: FCM's own
            // id as the tag, and an id hashed from it.
            show(title, body, data, fcmMessageId, legacyNotificationIdFor(fcmMessageId))
        }
    }

    companion object {
        private const val DEFAULT_NOTIFICATION_ID = 1

        fun legacyNotificationIdFor(messageId: String?): Int {
            if (messageId.isNullOrEmpty()) return DEFAULT_NOTIFICATION_ID
            var h = 0
            for (c in messageId) {
                h = h * 31 + c.code
            }
            // Coalesce to the default id space - keeps recent pushes from saturating
            // the tray and ensures taps on a single thread land on the same id.
            return h and 0x7FFF_FFFF
        }
    }
}
