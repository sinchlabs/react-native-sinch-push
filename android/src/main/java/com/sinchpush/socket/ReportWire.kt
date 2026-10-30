package com.sinchpush.socket

import java.net.URI
import java.net.URL

/**
 * What a finished `ReportEvents` call means for the queued reports. The same four
 * outcomes the JS flusher (`src/api/reportOutbox.ts`) and the iOS extension
 * (`ReportWire.swift`) act on.
 */
internal enum class ReportOutcome {
    /** Acknowledged: never report again. */
    SENT,

    /** The server will never accept it (InvalidArgument / NotFound / PermissionDenied, or HTTP 403): drop it. */
    DROPPED,

    /** Rejected for the credential: keep the report for a newer token. */
    UNAUTHENTICATED,

    /** Transport or server trouble: keep the report for the next attempt. */
    RETRY,
    ;

    /** `true` when the reports are done with, one way or the other. */
    val isFinal: Boolean get() = this == SENT || this == DROPPED
}

/**
 * The `SdkService/ReportEvents` call, as bytes (SB-67).
 *
 * Hand-encoded rather than generated: the Wire output in `src/main/wire` covers
 * the socket and resource protos only, and the message is two strings and an
 * enum. Mirrors `src/api/pushRepository.ts` `reportEvents` and
 * `ios/NotificationExtension/Core/ReportWire.swift`:
 *
 *     ReportEventsRequest { repeated ReportedEvent events = 1; }
 *     ReportedEvent { string message_id = 1; string subscriber_id = 2; PushEventType event_type = 4; }
 *     PushEventType.DELIVERED = 300
 *
 * Framed as gRPC-web over an HTTPS POST: `0x00`, a big-endian length, the protobuf.
 */
internal object ReportWire {

    const val DELIVERED_EVENT_TYPE = 300L
    const val SERVICE_PATH = "sinch.push.sdk.v1beta1.SdkService/ReportEvents"
    const val CONTENT_TYPE = "application/grpc-web+proto"
    private const val GRPC_CONTENT_TYPE_PREFIX = "application/grpc"

    /** Per request; the JS flusher batches the same way. */
    const val BATCH_SIZE = 100

    /** `null` for a base URL that is not an http(s) URL with a host. */
    fun endpoint(baseUrl: String): URL? {
        val base = baseUrl.trim().trimEnd('/')
        return try {
            val uri = URI("$base/$SERVICE_PATH")
            val scheme = uri.scheme?.lowercase()
            if ((scheme != "https" && scheme != "http") || uri.host.isNullOrEmpty()) null else uri.toURL()
        } catch (_: Exception) {
            null
        }
    }

    /**
     * The headers of one call. `authorization` is the raw JWT with no `Bearer `
     * prefix, exactly what the JS transport and the iOS extension send.
     */
    fun headers(accessToken: String): Map<String, String> = linkedMapOf(
        "content-type" to CONTENT_TYPE,
        "accept" to CONTENT_TYPE,
        "x-grpc-web" to "1",
        "authorization" to accessToken,
    )

    fun requestBody(keys: List<Pair<String, String>>): ByteArray {
        val message = ByteSink()
        for ((messageId, subscriberId) in keys) {
            val event = ByteSink()
            event.string(1, messageId)
            event.string(2, subscriberId)
            event.byte(0x20) // field 4, varint
            event.varint(DELIVERED_EVENT_TYPE)
            message.byte(0x0A) // ReportEventsRequest.events
            message.varint(event.size.toLong())
            message.bytes(event.toByteArray())
        }
        val body = message.toByteArray()
        val frame = ByteSink()
        frame.byte(0x00)
        frame.byte(body.size ushr 24)
        frame.byte(body.size ushr 16)
        frame.byte(body.size ushr 8)
        frame.byte(body.size)
        frame.bytes(body)
        return frame.toByteArray()
    }

    /**
     * The gRPC status of a response: the trailer frame (flag `0x80`) in the body
     * (gRPC-web), else [header] (the `grpc-status` header, or an HTTP/2 trailer).
     * `null` when neither says (an empty void response).
     */
    fun grpcStatus(header: String?, body: ByteArray?): Int? =
        trailerFrameStatus(body) ?: header?.let { it.trim().toIntOrNull() ?: UNPARSABLE_STATUS }

    /** A `grpc-status` that is there but not a number: an unknown status, retried - not a missing one. */
    private const val UNPARSABLE_STATUS = -1

    private fun trailerFrameStatus(body: ByteArray?): Int? {
        if (body == null) return null
        var offset = 0
        var status: Int? = null
        while (body.size - offset >= 5) {
            val flag = body[offset].toInt() and 0xFF
            var length = 0L
            for (i in 1..4) length = (length shl 8) or (body[offset + i].toLong() and 0xFF)
            offset += 5
            if (offset + length > body.size) break
            if (flag and 0x80 != 0) {
                val text = String(body, offset, length.toInt(), Charsets.UTF_8)
                for (line in text.split("\r\n", "\n", "\r")) {
                    val parts = line.split(":", limit = 2)
                    if (parts.size == 2 && parts[0].trim().lowercase() == "grpc-status") {
                        status = parts[1].trim().toIntOrNull() ?: UNPARSABLE_STATUS
                    }
                }
            }
            offset += length.toInt()
        }
        return status
    }

    /**
     * `true` for a `Content-Type` of the gRPC family: gRPC-web (`application/grpc-web`,
     * `+proto`, `-text`...) or plain gRPC (`application/grpc`, `application/grpc+proto`),
     * which a native gRPC server answers a gRPC-web request with.
     */
    fun isGrpc(contentType: String?): Boolean {
        val type = contentType?.trim()?.lowercase() ?: return false
        if (!type.startsWith(GRPC_CONTENT_TYPE_PREFIX)) return false
        // `application/grpc`, `application/grpc+proto`, `application/grpc-web…`, `application/grpc;…`.
        val rest = type.substring(GRPC_CONTENT_TYPE_PREFIX.length)
        return rest.isEmpty() || rest[0] == '+' || rest[0] == ';' || rest.startsWith("-web")
    }

    /**
     * What a finished call means, with the same answers as the JS flusher, whose
     * transport (connect-es, gRPC-web) reads a response like this:
     *
     *  - A non-2xx status is an error by its HTTP status alone: 401 is
     *    `Unauthenticated`, 403 `PermissionDenied` (dropped), everything else -
     *    400 and 404 included - retried.
     *  - A 2xx counts only when it is gRPC ([contentType] starts with
     *    `application/grpc`). A 2xx that is not (a captive portal's 200 HTML) is not
     *    an acknowledgement: retried, never deleted.
     *  - The gRPC status is the trailer frame in the body (gRPC-web), else
     *    [grpcStatusHeader] (the `grpc-status` header, or the HTTP/2 trailer the
     *    transport read after the body). A native gRPC server sends it in HTTP/2
     *    trailers; none at all is the empty success whose status could not be
     *    seen: sent, as in JS (fetch cannot read trailers either).
     */
    fun outcome(httpStatus: Int, contentType: String?, grpcStatusHeader: String?, body: ByteArray?): ReportOutcome {
        if (httpStatus !in 200..299) {
            return when (httpStatus) {
                401 -> ReportOutcome.UNAUTHENTICATED
                403 -> ReportOutcome.DROPPED
                else -> ReportOutcome.RETRY
            }
        }
        if (!isGrpc(contentType)) return ReportOutcome.RETRY
        return when (grpcStatus(grpcStatusHeader, body)) {
            null, 0 -> ReportOutcome.SENT
            16 -> ReportOutcome.UNAUTHENTICATED
            3, 5, 7 -> ReportOutcome.DROPPED // InvalidArgument, NotFound, PermissionDenied
            else -> ReportOutcome.RETRY
        }
    }

    private class ByteSink {
        private val out = java.io.ByteArrayOutputStream()
        val size: Int get() = out.size()

        fun byte(value: Int) = out.write(value and 0xFF)

        fun bytes(value: ByteArray) = out.write(value, 0, value.size)

        fun varint(value: Long) {
            var v = value
            while (v >= 0x80) {
                out.write(((v and 0x7F) or 0x80).toInt())
                v = v ushr 7
            }
            out.write(v.toInt())
        }

        fun string(field: Int, value: String) {
            val raw = value.toByteArray(Charsets.UTF_8)
            byte(field shl 3 or 2)
            varint(raw.size.toLong())
            bytes(raw)
        }

        fun toByteArray(): ByteArray = out.toByteArray()
    }
}

/**
 * The `exp` of a JWT, so a token that has already expired is not sent just to be
 * answered `Unauthenticated`. Hand-parsed (no `org.json`, which a JVM test does
 * not have); `null` when the token has no readable `exp` - then it is usable.
 */
internal object JwtExpiry {

    private val EXP = Regex("\"exp\"\\s*:\\s*(\\d+(?:\\.\\d+)?)")

    fun expiresAtMs(token: String): Long? {
        val parts = token.split('.')
        if (parts.size != 3) return null
        val payload = decodeBase64Url(parts[1]) ?: return null
        val exp = EXP.find(String(payload, Charsets.UTF_8))?.groupValues?.get(1)?.toDoubleOrNull() ?: return null
        return (exp * 1000).toLong()
    }

    private fun decodeBase64Url(text: String): ByteArray? {
        val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        val out = java.io.ByteArrayOutputStream()
        var buffer = 0
        var bits = 0
        for (c in text.trimEnd('=')) {
            val v = alphabet.indexOf(c)
            if (v < 0) return null
            buffer = (buffer shl 6) or v
            bits += 6
            if (bits >= 8) {
                bits -= 8
                out.write((buffer shr bits) and 0xFF)
            }
        }
        return out.toByteArray()
    }
}
