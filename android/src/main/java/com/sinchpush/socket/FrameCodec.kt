package com.sinchpush.socket

import com.squareup.wire.ProtoAdapter
import java.io.ByteArrayOutputStream
import okio.Buffer
import sinch.push.delivery.v1beta1.ws.Ack
import sinch.push.delivery.v1beta1.ws.AuthChallenge
import sinch.push.delivery.v1beta1.ws.Close
import sinch.push.delivery.v1beta1.ws.DeliveryReport
import sinch.push.delivery.v1beta1.ws.Hello
import sinch.push.delivery.v1beta1.ws.HelloAck
import sinch.push.delivery.v1beta1.ws.Message as ServerMessage
import sinch.push.delivery.v1beta1.ws.Ping
import sinch.push.delivery.v1beta1.ws.Pong
import sinch.push.delivery.v1beta1.ws.Poll

/**
 * Any message Square Wire can encode.
 *
 * `com.squareup.wire.Message` is recursively generic - `Message<M : Message<M, B>, B>`
 * - so everywhere a plain "some protobuf message" is meant, the type is the star
 * projection rather than the bare class.
 */
internal typealias WireMessage = com.squareup.wire.Message<*, *>

/**
 * Which side of the connection a frame is travelling on.
 *
 * Tags 1..4 name different payloads in each direction - `ClientFrame.hello`
 * (tag 1) is not `ServerFrame.auth_challenge` (tag 1), nor is `ClientFrame.poll`
 * (tag 2) `ServerFrame.hello_ack` (tag 2) - so a tag is meaningless without a
 * direction. A decoder that ignores it silently reads one message as another.
 */
internal enum class FrameDirection { CLIENT, SERVER }

/** Which envelope check rejected a frame. */
internal enum class FrameErrorReason {
    /** Fewer than a tag byte plus a length byte. */
    TOO_SHORT,

    /** The length prefix is unterminated, or a tenth byte carries more than one bit. */
    LENGTH_VARINT,

    /** The declared payload is over [FrameCodec.MAX_FRAME_PAYLOAD_BYTES]. */
    PAYLOAD_TOO_LARGE,

    /** The whole frame is over [FrameCodec.MAX_FRAME_TOTAL_BYTES]. */
    FRAME_TOO_LARGE,

    /** Fewer payload bytes are present than the prefix declared. */
    TRUNCATED_PAYLOAD,
}

/**
 * Thrown when an envelope is not decodable: a bad length prefix, a length this
 * SDK and the relay would disagree about, or a payload that is cut short.
 *
 * Separate from [UnknownFrameTagException] on purpose. An unknown tag means the
 * peer is ahead of this SDK and the bytes around it are fine; a malformed
 * envelope means the bytes are wrong whoever reads them. Keeping them apart lets
 * the caller apply a different policy to each - drop the frame, or fail the
 * connection.
 */
internal class MalformedFrameException(
    val direction: FrameDirection,
    val reason: FrameErrorReason,
    /**
     * The declared payload length, when it fits in a signed 64-bit integer and
     * is therefore worth reporting. `null` for a prefix above `Long.MAX_VALUE`,
     * where quoting the narrowed value would report a number the peer never
     * sent - the message always carries the unsigned form.
     */
    val declaredLength: Long?,
    message: String,
) : IllegalArgumentException(message)

/**
 * Thrown when the envelope tag is not a `oneof payload` field number of the
 * frame type for [direction]: a server-only tag on the client side, or a tag
 * that is not a frame at all in either direction.
 */
internal class UnknownFrameTagException(
    val direction: FrameDirection,
    val tag: Int,
) : IllegalArgumentException(
    "ws frame: unknown ${direction.name.lowercase()} frame tag $tag",
)

/**
 * Thrown when a message is not a `oneof payload` member of the frame type for a
 * direction - a `HelloAck` offered as an outbound client frame, say.
 *
 * SB-13 in docs/socket-behaviour-spec.md: encoding such a frame would emit a
 * perfectly well-formed frame that carries the wrong payload type, and a caller
 * bug would look exactly like a protocol-legal frame on the wire.
 */
internal class UnknownFramePayloadException(
    val direction: FrameDirection,
    val messageType: String,
) : IllegalArgumentException(
    "ws frame: $messageType is not a ${direction.name.lowercase()} frame payload",
)

/**
 * The WebSocket wire envelope: `[1-byte tag][varint length][protobuf payload]`.
 *
 * The envelope is ours; the payload is protobuf and belongs to Square Wire.
 * This object keeps everything that is *not* protobuf - the bounds, the
 * length-varint rules, the direction-scoped tag table and the typed exceptions -
 * and hands the payload bytes to the generated `ADAPTER` of whichever message
 * the tag names. There is no hand-written protobuf left here by design (RN-030).
 *
 * The tag is the field number of the `oneof payload` member in
 * `ClientFrame` / `ServerFrame` (websocket.proto). See [payloads] for how the
 * table is kept honest against the generated schema.
 */
internal object FrameCodec {

    const val CLIENT_TAG_HELLO = 1
    const val CLIENT_TAG_POLL = 2
    const val CLIENT_TAG_DELIVERY_REPORT = 3
    const val CLIENT_TAG_PONG = 4

    const val SERVER_TAG_AUTH_CHALLENGE = 1
    const val SERVER_TAG_HELLO_ACK = 2
    const val SERVER_TAG_MESSAGE = 3
    const val SERVER_TAG_ACK = 4
    const val SERVER_TAG_PING = 5
    const val SERVER_TAG_PONG = 6
    const val SERVER_TAG_CLOSE = 7

    /**
     * Largest protobuf payload a single frame may carry, in bytes.
     *
     * The v1beta1 protocol contract, mirrored from the relay's
     * `MaxFramePayloadBytes` (`internal/ws/codec.go`) and from `MAX_FRAME_PAYLOAD_BYTES`
     * in the TypeScript codec this was ported from. The bound is on the payload,
     * not on the frame; see [MAX_FRAME_TOTAL_BYTES] for the larger one. It is
     * checked against the length prefix *before* anything is allocated, so a
     * peer cannot declare 2^64 bytes and have them reserved.
     */
    const val MAX_FRAME_PAYLOAD_BYTES = 64 * 1024 // 65536

    /**
     * Widest a length prefix can legally be: 10 bytes for a 64-bit value.
     *
     * Protobuf accepts a non-minimal encoding of the same length and so does the
     * relay, so this is what the *accepted* envelope bound is built from.
     */
    private const val LENGTH_VARINT_MAX_BYTES_64 = 10

    /**
     * Widest a length prefix we *write* can be: 65536 encodes canonically as
     * `80 80 04`, so three bytes.
     */
    private const val CANONICAL_LENGTH_VARINT_MAX_BYTES = 3

    /**
     * Largest whole frame accepted on the wire, in bytes:
     * 1 tag byte + a 10-byte length prefix + [MAX_FRAME_PAYLOAD_BYTES] = 65547.
     *
     * Matches the relay's `MaxWireFrameBytes`. It is deliberately larger than
     * [MAX_FRAME_EMITTED_BYTES]: a length does not have to be encoded
     * canonically, so 65536 can legitimately arrive behind the ten-byte
     * `80 80 84 80 80 80 80 80 80 00` and make a real 65547-byte frame.
     */
    const val MAX_FRAME_TOTAL_BYTES =
        MAX_FRAME_PAYLOAD_BYTES + 1 + LENGTH_VARINT_MAX_BYTES_64 // 65547

    /**
     * Largest frame this codec ever *writes*, which is strictly smaller than what
     * it accepts: we always emit a canonical length prefix, so the widest frame
     * we produce is 1 + 3 + 65536 = 65540. Exported so the asymmetry is asserted
     * rather than assumed - emit canonical, accept a non-canonical extension.
     */
    const val MAX_FRAME_EMITTED_BYTES =
        MAX_FRAME_PAYLOAD_BYTES + 1 + CANONICAL_LENGTH_VARINT_MAX_BYTES // 65540

    data class DecodedFrame(val tag: Int, val payloadType: String, val payload: ByteArray) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is DecodedFrame) return false
            if (tag != other.tag) return false
            if (payloadType != other.payloadType) return false
            if (!payload.contentEquals(other.payload)) return false
            return true
        }

        override fun hashCode(): Int {
            var result = tag
            result = 31 * result + payloadType.hashCode()
            result = 31 * result + payload.contentHashCode()
            return result
        }
    }

    /** One `oneof payload` member: the name the relay uses, and its adapter. */
    private class Payload(val name: String, val adapter: ProtoAdapter<Any>)

    /**
     * The adapter of a message whose type is known here, erased to `Any`.
     *
     * The cast is confined to the one table that pairs a tag with the adapter of
     * the message that schema names for it, so no call site can pair a tag with
     * an adapter that does not belong to it: [encode] looks the adapter up by
     * the message's own type, and [decode] hands the payload to the adapter the
     * tag selected.
     */
    @Suppress("UNCHECKED_CAST")
    private fun <T> erased(adapter: ProtoAdapter<T>): ProtoAdapter<Any> = adapter as ProtoAdapter<Any>

    /**
     * The `oneof payload` members per direction, keyed by the field number that
     * is the envelope tag.
     *
     * These are the field numbers of `websocket.proto` (RN-001 pins the proto).
     * wire-compiler does not emit a lookup table for a oneof in its Kotlin
     * target - `ServerFrame.PAYLOAD`/`MESSAGE_OPTIONS` only exist with
     * `javaInterop` - so the mapping is spelled out here and pinned from both
     * ends:
     *
     *  - [payloadTable] fails construction if a tag is outside 1..255 or two
     *    members of one frame type share a tag, which is what SB-02 requires;
     *  - `FrameTagTableTest` asserts, from the generated `@WireField` tags on
     *    `ServerFrame`/`ClientFrame`, that this table is exactly the schema's;
     *  - `RelayGoldenVectorsTest` asserts it against the relay's own derivation
     *    of the same table.
     *
     * A renumbering upstream therefore fails a test rather than a push, and a tag
     * that cannot be written as one byte fails the first frame of the process
     * instead of wrapping to another payload type.
     */
    private val CLIENT_PAYLOADS: Map<Int, Payload> = payloadTable(
        CLIENT_TAG_HELLO to Payload("hello", erased(Hello.ADAPTER)),
        CLIENT_TAG_POLL to Payload("poll", erased(Poll.ADAPTER)),
        CLIENT_TAG_DELIVERY_REPORT to Payload("delivery_report", erased(DeliveryReport.ADAPTER)),
        CLIENT_TAG_PONG to Payload("pong", erased(Pong.ADAPTER)),
    )

    private val SERVER_PAYLOADS: Map<Int, Payload> = payloadTable(
        SERVER_TAG_AUTH_CHALLENGE to Payload("auth_challenge", erased(AuthChallenge.ADAPTER)),
        SERVER_TAG_HELLO_ACK to Payload("hello_ack", erased(HelloAck.ADAPTER)),
        SERVER_TAG_MESSAGE to Payload("message", erased(ServerMessage.ADAPTER)),
        SERVER_TAG_ACK to Payload("ack", erased(Ack.ADAPTER)),
        SERVER_TAG_PING to Payload("ping", erased(Ping.ADAPTER)),
        SERVER_TAG_PONG to Payload("pong", erased(Pong.ADAPTER)),
        SERVER_TAG_CLOSE to Payload("close", erased(Close.ADAPTER)),
    )

    /**
     * Builds one direction's table, refusing a tag that cannot go on the wire or
     * that a second payload would claim.
     *
     * A tag outside 1..255 (`256` would wrap to `0` and emit a frame the relay
     * reads as a different payload) and a duplicate - which `mapOf` would
     * silently resolve to the last writer, making the table order-dependent -
     * are both schema mistakes that should fail construction, naming the
     * offending payload, instead of appearing as a misframed push.
     */
    private fun payloadTable(vararg entries: Pair<Int, Payload>): Map<Int, Payload> {
        val table = LinkedHashMap<Int, Payload>(entries.size)
        for ((tag, payload) in entries) {
            require(tag in 1..255) {
                "ws frame: oneof payload '${payload.name}' has field number $tag, " +
                    "which cannot be written as the one-byte frame tag"
            }
            require(table.put(tag, payload) == null) {
                "ws frame: two oneof payloads of this frame type share tag $tag " +
                    "('${payload.name}' and '${table[tag]?.name}')"
            }
        }
        return table
    }

    private fun table(direction: FrameDirection): Map<Int, Payload> =
        if (direction == FrameDirection.CLIENT) CLIENT_PAYLOADS else SERVER_PAYLOADS

    /**
     * The payload member name for [tag] in [direction], or a thrown
     * [UnknownFrameTagException].
     */
    fun payloadType(direction: FrameDirection, tag: Int): String {
        val payload = table(direction)[tag] ?: throw UnknownFrameTagException(direction, tag)
        return payload.name
    }

    /** Whether [tag] names a `oneof payload` member in [direction]. */
    fun isKnownTag(direction: FrameDirection, tag: Int): Boolean =
        table(direction).containsKey(tag)

    /**
     * The generated adapter for the payload [tag] names in [direction].
     *
     * The one place the tag table and the schema meet at runtime: decoding goes
     * through the adapter of the message the tag names, so a payload is only ever
     * read by the schema its tag selects.
     */
    @Suppress("UNCHECKED_CAST")
    fun <T : WireMessage> adapter(direction: FrameDirection, tag: Int): ProtoAdapter<T> {
        val payload = table(direction)[tag] ?: throw UnknownFrameTagException(direction, tag)
        return payload.adapter as ProtoAdapter<T>
    }

    /**
     * `[tag byte][canonical varint length][payload]`, with the payload encoded by
     * the generated adapter of whichever message [message] is.
     *
     * The tag is derived from the message, not passed alongside it, so a caller
     * cannot pair a payload with a tag that names a different one (SB-13): the
     * only way to name the tag is to hand over a member of this frame type.
     *
     * Refuses to build a frame the relay would reject, at the call site: the
     * relay caps the payload on the way out too, so a frame above the bound
     * fails here instead of turning into a dropped connection.
     */
    fun encode(message: WireMessage, direction: FrameDirection): ByteArray {
        val entry = table(direction).entries.firstOrNull { (_, payload) ->
            payload.adapter.type?.isInstance(message) == true
        } ?: throw UnknownFramePayloadException(
            direction,
            message.javaClass.simpleName,
        )
        val payload = entry.value.adapter.encode(message)
        return encodeFrame(entry.key, payload, direction)
    }

    /**
     * `[tag byte][canonical varint length][payload]`.
     *
     * Takes bytes rather than a message so it can frame a payload the caller
     * read off the wire untouched - which is what the golden vectors assert.
     *
     * Refuses to build a frame the relay would reject, at the call site: the
     * relay caps the payload on the way out too, so a frame above the bound
     * fails here instead of turning into a dropped connection.
     */
    fun encodeFrame(tag: Int, payload: ByteArray, direction: FrameDirection): ByteArray {
        if (payload.size > MAX_FRAME_PAYLOAD_BYTES) {
            throw MalformedFrameException(
                direction,
                FrameErrorReason.PAYLOAD_TOO_LARGE,
                payload.size.toLong(),
                "ws frame: payload ${payload.size} bytes exceeds $MAX_FRAME_PAYLOAD_BYTES",
            )
        }
        val lengthBytes = varintBytes(payload.size.toLong())
        val out = ByteArray(1 + lengthBytes.size + payload.size)
        out[0] = tag.toByte()
        System.arraycopy(lengthBytes, 0, out, 1, lengthBytes.size)
        System.arraycopy(payload, 0, out, 1 + lengthBytes.size, payload.size)
        // Unreachable while the payload cap holds, because the prefix is
        // canonical; checked so the emitted bound is enforced rather than
        // assumed.
        check(out.size <= MAX_FRAME_EMITTED_BYTES) {
            "ws frame: emitted ${out.size} bytes exceeds $MAX_FRAME_EMITTED_BYTES"
        }
        return out
    }

    /**
     * Reads one wire frame: `[tag][varint length][payload]`, in that order.
     *
     * The length prefix is read losslessly as a 64-bit unsigned value and
     * checked against [MAX_FRAME_PAYLOAD_BYTES] *before* it is narrowed to an
     * `Int`. That ordering is the whole point: `80 80 80 80 10` declares
     * 4294967296 bytes, and a reader that narrows first sees 0 and returns an
     * empty payload - which a client then reports as an empty `HelloAck` and
     * moves to `connected` on. The relay reads the same prefix as a uint64 and
     * rejects it on the same bound.
     *
     * @throws UnknownFrameTagException when [tag][data] is not a payload member
     *   of the frame type for [direction].
     * @throws MalformedFrameException when the envelope is unreadable.
     */
    fun readFrame(data: ByteArray, direction: FrameDirection): DecodedFrame {
        if (data.size < 2) {
            throw MalformedFrameException(direction, FrameErrorReason.TOO_SHORT, null, "ws frame: too short")
        }
        if (data.size > MAX_FRAME_TOTAL_BYTES) {
            throw MalformedFrameException(
                direction,
                FrameErrorReason.FRAME_TOO_LARGE,
                null,
                "ws frame: ${data.size} bytes exceeds the $MAX_FRAME_TOTAL_BYTES-byte frame limit",
            )
        }
        val tag = data[0].toInt() and 0xFF
        // Length first, then tag: a prefix that does not parse is never
        // allowed to resolve to a frame type.
        val prefix = readLengthPrefix(data, direction)
        val declared = prefix.value
        // Unsigned: a varint above Long.MAX_VALUE arrives here as a negative
        // Long, and every such value is over the cap.
        if (java.lang.Long.compareUnsigned(declared, MAX_FRAME_PAYLOAD_BYTES.toLong()) > 0) {
            throw MalformedFrameException(
                direction,
                FrameErrorReason.PAYLOAD_TOO_LARGE,
                if (declared < 0) null else declared,
                "ws frame: declared payload ${java.lang.Long.toUnsignedString(declared)} " +
                    "bytes exceeds $MAX_FRAME_PAYLOAD_BYTES",
            )
        }
        // Safe from here on: declared <= MAX_FRAME_PAYLOAD_BYTES, so
        // prefix.length + declared cannot overflow the Int arithmetic below.
        val length = declared.toInt()
        val start = 1 + prefix.length
        val end = start + length
        if (end > data.size) {
            throw MalformedFrameException(
                direction,
                FrameErrorReason.TRUNCATED_PAYLOAD,
                declared,
                "ws frame: truncated payload (need $length bytes, have ${data.size - start})",
            )
        }
        val payload = ByteArray(length)
        System.arraycopy(data, start, payload, 0, length)
        return DecodedFrame(tag, payloadType(direction, tag), payload)
    }

    /**
     * The payload of [frame] as the message its tag names, decoded by that
     * message's generated adapter.
     *
     * The caller still passes [direction]: a tag is only meaningful together with
     * the side it travelled on, so the frame does not carry enough to decode
     * itself.
     */
    fun decode(frame: DecodedFrame, direction: FrameDirection): WireMessage =
        adapter<WireMessage>(direction, frame.tag).decode(Buffer().write(frame.payload)).also {
            // SB-17: the protobuf layer substitutes ill-formed UTF-8; refuse it.
            StrictUtf8.check(it, frame.payload)
        }

    /** The length prefix of a frame, as bytes counted and as an unsigned 64-bit value. */
    private class LengthPrefix(val length: Int, val value: Long)

    /**
     * Reads the length prefix that starts at index 1 of [data].
     *
     * One pass, validating and accumulating together: an unterminated prefix
     * (the buffer ends while the continuation bit is still set) is rejected, and
     * so is a tenth byte carrying more than the single bit that still fits in 64
     * bits. That second rule is the one a naive reader gets wrong - OR-ing
     * `(b and 0x7F) shl 63` in silently discards everything above bit 63, so
     * `80 80 80 80 80 80 80 80 80 02` would decode as 0 and pass every other
     * check. The relay rejects the same bytes (`internal/ws/codec.go`) and so does
     * the TypeScript codec.
     *
     * Done by hand rather than with a library reader because both hand-rolled and
     * library readers accept that tenth byte: the shape has to be inspected while
     * it is still visible on the wire (SB-06).
     */
    private fun readLengthPrefix(data: ByteArray, direction: FrameDirection): LengthPrefix {
        var value = 0L
        var shift = 0
        var index = 1
        while (true) {
            if (index >= data.size) {
                throw MalformedFrameException(
                    direction,
                    FrameErrorReason.LENGTH_VARINT,
                    null,
                    "ws frame: unterminated length varint after ${index - 1} bytes",
                )
            }
            val b = data[index].toInt() and 0xFF
            index++
            if (index == LENGTH_VARINT_MAX_BYTES_64 + 1 && b > 0x01) {
                throw MalformedFrameException(
                    direction,
                    FrameErrorReason.LENGTH_VARINT,
                    null,
                    "ws frame: length varint overflows 64 bits",
                )
            }
            value = value or ((b and 0x7F).toLong() shl shift)
            if ((b and 0x80) == 0) return LengthPrefix(index - 1, value)
            shift += 7
        }
    }

    /**
     * Unsigned protobuf varint of a full 64-bit value, as the bytes on the wire.
     *
     * The comparison has to be unsigned. A signed `while (v >= 0x80L)` stops
     * immediately on a negative value and writes its low seven bits alone, so
     * `Long.MIN_VALUE` - which protobuf sign-extends across ten bytes, as the
     * relay's `int64_boundary_delivery_report_min` vector shows - would be
     * written as `00` and read back as zero. `java.lang.Long.compareUnsigned`
     * with the existing `ushr` walks the whole 64 bits.
     *
     * SB-08: what we write is always the minimal encoding, even though what we
     * accept is not (SB-07). That asymmetry is why MAX_FRAME_EMITTED_BYTES is
     * seven bytes smaller than MAX_FRAME_TOTAL_BYTES.
     */
    private fun varintBytes(value: Long): ByteArray =
        ByteArrayOutputStream(LENGTH_VARINT_MAX_BYTES_64).apply {
            var v = value
            while (java.lang.Long.compareUnsigned(v, 0x80L) >= 0) {
                write(((v and 0x7FL).toInt()) or 0x80)
                v = v ushr 7
            }
            write(v.toInt() and 0x7F)
        }.toByteArray()
}