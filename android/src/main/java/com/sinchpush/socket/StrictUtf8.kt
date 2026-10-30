package com.sinchpush.socket

import sinch.push.delivery.v1beta1.ws.Ack
import sinch.push.delivery.v1beta1.ws.AuthChallenge
import sinch.push.delivery.v1beta1.ws.Close
import sinch.push.delivery.v1beta1.ws.DeliveryReport
import sinch.push.delivery.v1beta1.ws.Hello
import sinch.push.delivery.v1beta1.ws.HelloAck
import sinch.push.delivery.v1beta1.ws.Message as ServerMessage
import sinch.push.delivery.v1beta1.ws.Ping
import sinch.push.delivery.v1beta1.ws.Pong
import sinch.push.delivery.v1beta1.ws.PooledMessage
import sinch.push.v1beta1.resources.PushNotification

/**
 * SB-17: an ill-formed UTF-8 string is refused, not silently substituted.
 *
 * Wire's string adapter decodes with Okio's `readUtf8`, which quietly turns
 * every ill-formed byte into U+FFFD. Left alone that would let a device invent
 * user-visible text from bytes the protocol never encoded, and would make a
 * notification depend on which decoder produced it - the property SB-17 forbids.
 *
 * The check is a count comparison and needs no schema walk of the wire bytes: a
 * legitimately encoded U+FFFD is the three bytes `EF BF BD`, so a payload that
 * decodes to *more* U+FFFD characters than it contains `EF BF BD` sequences had
 * at least one substituted. (A payload that also carries `EF BF BD` inside a
 * non-string field can mask one substitution; that needs a peer building the
 * bytes on purpose, and the result is still only a replacement character.)
 */
internal object StrictUtf8 {

    private const val REPLACEMENT = '�'

    /** @throws java.io.IOException when [message] was decoded from ill-formed UTF-8. */
    fun check(message: WireMessage, payload: ByteArray) {
        var substituted = 0
        forEachString(message) { s -> substituted += s.count { it == REPLACEMENT } }
        if (substituted == 0) return
        if (substituted > countLegitimateReplacements(payload)) {
            throw java.io.IOException("ill-formed UTF-8 in a string field")
        }
    }

    private fun countLegitimateReplacements(payload: ByteArray): Int {
        var n = 0
        var i = 0
        while (i + 2 < payload.size) {
            if (payload[i] == 0xEF.toByte() && payload[i + 1] == 0xBF.toByte() && payload[i + 2] == 0xBD.toByte()) {
                n++
                i += 3
            } else {
                i++
            }
        }
        return n
    }

    private fun forEachString(message: WireMessage, visit: (String) -> Unit) {
        when (message) {
            is HelloAck -> {
                visit(message.connection_id)
                message.messages.forEach { forEachPooled(it, visit) }
            }
            is ServerMessage -> {
                visit(message.ack_token)
                message.message?.let { forEachPooled(it, visit) }
            }
            is Ack -> { visit(message.ack_token); visit(message.error) }
            is Close -> visit(message.detail)
            is Ping -> visit(message.correlation_id)
            is Pong -> visit(message.correlation_id)
            is AuthChallenge -> visit(message.nonce)
            is Hello -> {
                visit(message.auth_token); visit(message.project_id); visit(message.app_id)
                visit(message.user_id); visit(message.last_seen_message_id); visit(message.sdk_version)
            }
            is DeliveryReport -> {
                visit(message.message_id); visit(message.sinch_message_id); visit(message.reason)
            }
            else -> Unit
        }
    }

    private fun forEachPooled(pooled: PooledMessage, visit: (String) -> Unit) {
        visit(pooled.message_id)
        visit(pooled.sinch_message_id)
        pooled.push_notification?.let { forEachNotification(it, visit) }
    }

    private fun forEachNotification(pn: PushNotification, visit: (String) -> Unit) {
        visit(pn.tracking_id)
        visit(pn.trigger)
        pn.alert?.let { visit(it.title); visit(it.message); visit(it.image_url) }
        pn.metadata.forEach { (k, v) -> visit(k); visit(v) }
    }
}
