package com.sinchpush.socket

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sinch.push.delivery.v1beta1.ws.DeliveryReport
import sinch.push.delivery.v1beta1.ws.Pong

/**
 * RN-030 Priority 0 — the frame bounds that were blockers before the Wire
 * migration, not cleanups.
 *
 * The reference implementation is `src/pushSocket/frame.ts` and its tests at tag
 * `ts-socket-client-snapshot`; these are the same cases with the same numbers.
 * Every one of them used to fail here: `readFrame` narrowed the length prefix to
 * an Int before reading it and bounded nothing.
 */
class FrameBoundsTest {

    private val atCap = FrameCodec.MAX_FRAME_PAYLOAD_BYTES // 65536
    private val overCap = FrameCodec.MAX_FRAME_PAYLOAD_BYTES + 1 // 65537

    // --- The three bounds are three constants and stay that way ---------------

    @Test
    fun `keeps the payload, emitted and accepted bounds distinct`() {
        assertEquals(65536, FrameCodec.MAX_FRAME_PAYLOAD_BYTES)
        // Accepted: 1 tag + a 10-byte varint + payload, matching the relay's
        // MaxWireFrameBytes.
        assertEquals(65547, FrameCodec.MAX_FRAME_TOTAL_BYTES)
        // Emitted: the same, with the canonical 3-byte varint (80 80 04).
        assertEquals(65540, FrameCodec.MAX_FRAME_EMITTED_BYTES)
        assertArrayEquals(
            byteArrayOf(0x80.toByte(), 0x80.toByte(), 0x04),
            varintBytes(atCap.toLong()),
        )
        assertEquals(3, varintSize(atCap.toLong()))
        assertTrue(FrameCodec.MAX_FRAME_EMITTED_BYTES < FrameCodec.MAX_FRAME_TOTAL_BYTES)
        // The payload cap alone would reject the frame the relay accepts.
        assertTrue(FrameCodec.MAX_FRAME_TOTAL_BYTES > FrameCodec.MAX_FRAME_PAYLOAD_BYTES)
    }

    // --- The 2^32 length that used to decode as an empty HelloAck ------------

    @Test
    fun `rejects the 4 GiB declaration that used to decode as an empty HelloAck`() {
        // The regression: `80 80 80 80 10` is 4294967296. A reader that
        // narrows to an Int first sees 0 and returns an empty payload, which the
        // client then treats as an empty HelloAck and moves to `connected` on.
        val error = failure(envelopeWithPrefix(0x02, byteArrayOf(0x80.toByte(), 0x80.toByte(), 0x80.toByte(), 0x80.toByte(), 0x10)))
        assertEquals(FrameErrorReason.PAYLOAD_TOO_LARGE, error.reason)
        assertEquals(4294967296L, error.declaredLength)
        assertTrue(error.message.orEmpty().contains("4294967296"))
    }

    @Test
    fun `rejects a length above the signed 64-bit range without reporting a narrowed one`() {
        // 2^63 is canonical, ten bytes, and far over any cap, so the payload
        // bound is what rejects it - which is what proves the varint itself was
        // read and accepted.
        val twoToThe63 = bytesOf(0x02, ByteArray(9) { 0x80.toByte() }, 0x01)
        val error = failure(twoToThe63)
        assertEquals(FrameErrorReason.PAYLOAD_TOO_LARGE, error.reason)
        assertNull("2^63 has no signed Long to report", error.declaredLength)
        assertTrue(error.message.orEmpty().contains("9223372036854775808"))

        // 2^64-1, the largest decodable varint: a legal encoding that declares
        // an impossible payload. Its tenth byte is 0x01 - the only bit still
        // free at shift 63 - so the varint is accepted and the payload bound is
        // what refuses it.
        val uint64Max = bytesOf(0x03, ByteArray(9) { 0xFF.toByte() }, 0x01)
        val max = failure(uint64Max)
        assertEquals(FrameErrorReason.PAYLOAD_TOO_LARGE, max.reason)
        assertNull(max.declaredLength)
        assertTrue(max.message.orEmpty().contains("18446744073709551615"))
    }

    // --- The tenth length-varint byte ---------------------------------------

    @Test
    fun `rejects a tenth byte carrying more than the one bit that fits`() {
        // OR-ing `(b and 0x7F) shl 63` in discards everything above bit 63
        // instead of failing, so these decode as 0 and sail through every other
        // check. The relay rejects them (internal/ws/codec.go) and so does the
        // TypeScript decoder.
        for (last in intArrayOf(0x02, 0x03, 0x40, 0x7F, 0x81, 0x82, 0xFF)) {
            val error = failure(bytesOf(0x02, ByteArray(9) { 0x80.toByte() }, last))
            assertEquals("tenth byte 0x%02x".format(last), FrameErrorReason.LENGTH_VARINT, error.reason)
        }
        // An eleventh byte means the value cannot be finished inside 64 bits.
        assertEquals(
            FrameErrorReason.LENGTH_VARINT,
            failure(bytesOf(0x02, ByteArray(11) { 0x80.toByte() }, 0x01)).reason,
        )
    }

    @Test
    fun `rejects an unterminated length varint`() {
        for (bytes in listOf(
            bytesOf(0x02, 0x80),
            bytesOf(0x02, 0x80, 0x80, 0x80, 0x80, 0x80),
            bytesOf(0x06, ByteArray(9) { 0x80.toByte() }),
        )) {
            val error = failure(bytes)
            assertEquals(FrameErrorReason.LENGTH_VARINT, error.reason)
            assertTrue(error.message.orEmpty().contains("unterminated"))
        }
    }

    @Test
    fun `accepts a non-canonical length extension`() {
        // Documented relay leniency: zero-padded prefixes decode to the value
        // they carry. `length_zero_padded_accepted` in the golden fixture is the
        // same shape, pinned here so it survives without the relay checkout.
        val prefix = extendedVarint(0, 10)
        assertEquals(11, envelopeWithPrefix(FrameCodec.CLIENT_TAG_PONG, prefix).size)
        assertEquals(0, FrameCodec.readFrame(envelopeWithPrefix(FrameCodec.CLIENT_TAG_PONG, prefix), FrameDirection.CLIENT).payload.size)
    }

    // --- The 65547-byte frame the 65540 bound used to refuse -----------------

    @Test
    fun `accepts a maximum-size payload behind a ten-byte extended prefix`() {
        // The case the 65547 bound exists for. 65536 can legitimately be
        // encoded in ten bytes by promoting the canonical terminal byte to a
        // continuation and appending zero groups, giving a real
        // 1 + 10 + 65536 = 65547-byte frame. Under a 65540 total this was
        // rejected outright.
        val prefix = extendedVarint(atCap.toLong(), 10)
        assertArrayEquals(
            byteArrayOf(
                0x80.toByte(), 0x80.toByte(), 0x84.toByte(),
                0x80.toByte(), 0x80.toByte(), 0x80.toByte(), 0x80.toByte(), 0x80.toByte(), 0x80.toByte(),
                0x00,
            ),
            prefix,
        )
        val payload = pongPayloadOfSize(atCap)
        assertEquals("a real Pong payload, not filler", atCap, payload.size)

        for (case in listOf(Triple(FrameCodec.CLIENT_TAG_PONG, FrameDirection.CLIENT, "client pong"), Triple(FrameCodec.SERVER_TAG_PONG, FrameDirection.SERVER, "server pong"))) {
            val bytes = envelopeWithPrefix(case.first, prefix, payload)
            assertEquals("${case.third}: frame size", FrameCodec.MAX_FRAME_TOTAL_BYTES, bytes.size)
            assertEquals("${case.third}: 65547", 65547, bytes.size)
            // Seven bytes wider than anything our own encoder produces.
            assertTrue(FrameCodec.MAX_FRAME_EMITTED_BYTES < bytes.size)

            val decoded = FrameCodec.readFrame(bytes, case.second)
            assertEquals("${case.third}: tag", case.first, decoded.tag)
            assertEquals("${case.third}: payload", atCap, decoded.payload.size)
            assertArrayEquals("${case.third}: payload bytes", payload, decoded.payload)
            // A full-size payload of a real message, so this cannot pass on a
            // tag/schema mixup.
            assertEquals(
                "${case.third}: correlation_id survives",
                pongCorrelationIdOfSize(atCap),
                (FrameCodec.decode(decoded, case.second) as Pong).correlation_id,
            )
        }
    }

    @Test
    fun `rejects a frame one byte over the accepted bound`() {
        // Valid tag, declared length 0, then more bytes than the envelope can
        // hold: 1 tag byte + 1 prefix byte + filler.
        val bytes = bytesOf(0x06, 0x00, ByteArray(FrameCodec.MAX_FRAME_TOTAL_BYTES - 1) { 'A'.code.toByte() })
        assertEquals(65548, bytes.size)
        assertEquals(FrameErrorReason.FRAME_TOO_LARGE, failure(bytes).reason)
    }

    @Test
    fun `still refuses an oversized payload inside the widened envelope`() {
        // Widening the envelope must not have widened the payload cap. A
        // declared 65537 is refused on the payload bound, which is what guards
        // allocation, even though the envelope around it has room.
        val error = failure(frameDeclaring(0x06, overCap.toLong(), 0))
        assertEquals(FrameErrorReason.PAYLOAD_TOO_LARGE, error.reason)
        assertEquals(overCap.toLong(), error.declaredLength)

        // ...and behind the widest tolerated prefix, too.
        val padded = failure(
            envelopeWithPrefix(0x06, extendedVarint(overCap.toLong(), 10), ByteArray(16)),
        )
        assertEquals(FrameErrorReason.PAYLOAD_TOO_LARGE, padded.reason)
        assertEquals(overCap.toLong(), padded.declaredLength)
    }

    @Test
    fun `writes a negative int64 as the ten-byte varint protobuf sign-extends it to`() {
        // The encoder decides its own width by comparing against 0x80, so a
        // signed comparison stops on the first byte of any negative value and
        // writes its low seven bits alone: Long.MIN_VALUE went out as `28 00`
        // and came back as zero. The relay's `int64_boundary_delivery_report_min`
        // payload is `0a036d2d312880808080808080808001`, so the ten-byte form is
        // pinned here without needing the fixture at test time - through the
        // generated adapter, which is what actually writes these bytes now.
        fun field5Of(value: Long): ByteArray {
            val payload = DeliveryReport.ADAPTER.encode(
                DeliveryReport(
                    message_id = "m-1",
                    reported_at_unix_millis = value,
                ),
            )
            val tail = payload.copyOfRange(payload.size - 1 - varintSize(value), payload.size)
            assertEquals("reported_at_unix_millis tag byte", 0x28, tail[0].toInt() and 0xFF)
            assertEquals("round trip of $value", value, protoFields(payload)[5]?.asLong())
            return tail
        }

        // The relay's bytes for the two ends of the range, and -1, which
        // protobuf extends to a full ten bytes too.
        assertArrayEquals(
            bytesOf(0x28, ByteArray(9) { 0x80.toByte() }, 0x01),
            field5Of(Long.MIN_VALUE),
        )
        assertArrayEquals(
            bytesOf(0x28, ByteArray(8) { 0xFF.toByte() }, 0x7F),
            field5Of(Long.MAX_VALUE),
        )
        assertArrayEquals(bytesOf(0x28, ByteArray(9) { 0xFF.toByte() }, 0x01), field5Of(-1L))

        // Zero is the one value the encoder does *not* write: proto3 omits a
        // field holding its default, so there is no varint to get narrow. The
        // hand-rolled encoder this replaced wrote `28 00`, which the relay reads
        // as an absent field anyway - the same value, twice the bytes. Asserted
        // because it is a real difference between the generated encoder and the
        // old one, and because a "write defaults" change would put them back.
        val zero = DeliveryReport.ADAPTER.encode(DeliveryReport(message_id = "m-1"))
        assertFalse(
            "a default reported_at_unix_millis must not reach the wire",
            5 in protoFields(zero),
        )
        assertEquals(
            "round trip of the omitted default",
            0L,
            DeliveryReport.ADAPTER.decode(zero).reported_at_unix_millis,
        )
    }

    // --- Encode / decode symmetry -------------------------------------------

    @Test
    fun `emits the widest frame we accept at 65540 bytes`() {
        val payload = pongPayloadOfSize(atCap)
        val frame = FrameCodec.encodeFrame(FrameCodec.CLIENT_TAG_PONG, payload, FrameDirection.CLIENT)
        assertEquals(FrameCodec.MAX_FRAME_EMITTED_BYTES, frame.size)
        assertEquals(65540, frame.size)
        assertArrayEquals(bytesOf(0x04, 0x80, 0x80, 0x04), frame.copyOfRange(0, 4))
        assertEquals(atCap, FrameCodec.readFrame(frame, FrameDirection.CLIENT).payload.size)
    }

    @Test
    fun `refuses to encode a payload over the cap`() {
        val error = runCatching {
            FrameCodec.encodeFrame(FrameCodec.CLIENT_TAG_PONG, ByteArray(overCap), FrameDirection.CLIENT)
        }.exceptionOrNull() as MalformedFrameException
        assertEquals(FrameErrorReason.PAYLOAD_TOO_LARGE, error.reason)
        assertEquals(overCap.toLong(), error.declaredLength)
        assertEquals(FrameDirection.CLIENT, error.direction)
    }

    @Test
    fun `rejects a frame that is too short or truncated`() {
        assertEquals(FrameErrorReason.TOO_SHORT, failure(ByteArray(0)).reason)
        assertEquals(FrameErrorReason.TOO_SHORT, failure(bytesOf(0x02)).reason)
        // tag 2, length 10, two payload bytes present.
        assertEquals(
            FrameErrorReason.TRUNCATED_PAYLOAD,
            failure(bytesOf(0x02, 0x0A, 0x00, 0x00)).reason,
        )
        // One byte short of the declared length is still truncated.
        assertEquals(
            FrameErrorReason.TRUNCATED_PAYLOAD,
            failure(frameDeclaring(0x02, 10, 9)).reason,
        )
    }

    @Test
    fun `checks the length before the tag, so a bad prefix is never trusted`() {
        // Tag 99 resolves to nothing and the prefix is malformed. Either
        // way it is a typed error, and nothing is allocated from the length.
        val thrown = runCatching {
            FrameCodec.readFrame(bytesOf(0x63, 0x80), FrameDirection.SERVER)
        }.exceptionOrNull()
        assertTrue("expected a malformed envelope, got $thrown", thrown is MalformedFrameException)
        assertEquals(FrameErrorReason.LENGTH_VARINT, (thrown as MalformedFrameException).reason)

        // The same, with a prefix that parses but declares 2^39 bytes: the
        // length bound fires, still without consulting the tag.
        val oversized = runCatching {
            FrameCodec.readFrame(bytesOf(0x63, 0x80, 0x80, 0x80, 0x80, 0x80, 0x10), FrameDirection.SERVER)
        }.exceptionOrNull()
        assertTrue("expected a malformed envelope, got $oversized", oversized is MalformedFrameException)
        assertEquals(FrameErrorReason.PAYLOAD_TOO_LARGE, (oversized as MalformedFrameException).reason)
    }

    // --- Direction is part of a tag -----------------------------------------

    @Test
    fun `rejects server-only tags on the client direction`() {
        // ServerFrame.payload owns 5..7; ClientFrame.payload owns 1..4. A tag is
        // only meaningful together with a direction, and on an empty payload a
        // mixup would still decode - so the table is asserted, not the bytes.
        val expected = mapOf(
            FrameCodec.SERVER_TAG_PING to "ping",
            FrameCodec.SERVER_TAG_PONG to "pong",
            FrameCodec.SERVER_TAG_CLOSE to "close",
        )
        for ((tag, name) in expected) {
            assertEquals(name, FrameCodec.readFrame(envelope(tag, ByteArray(0)), FrameDirection.SERVER).payloadType)
            val thrown = runCatching { FrameCodec.readFrame(envelope(tag, ByteArray(0)), FrameDirection.CLIENT) }
                .exceptionOrNull()
            assertTrue("client must refuse server tag $tag", thrown is UnknownFrameTagException)
            assertEquals(FrameDirection.CLIENT, (thrown as UnknownFrameTagException).direction)
        }
        for (tag in intArrayOf(0, 8, 99, 255)) {
            assertTrue(
                "unknown tag $tag",
                runCatching { FrameCodec.readFrame(envelope(tag, ByteArray(0)), FrameDirection.SERVER) }
                    .exceptionOrNull() is UnknownFrameTagException,
            )
        }
    }

    @Test
    fun `decodes the same tag to a different payload per direction`() {
        // Tag 4 is ClientFrame.pong inbound and ServerFrame.ack outbound, so the
        // tag alone does not identify the payload. A boundary test that
        // hard-codes "tag 4 is pong" is right in one direction and silently
        // wrong in the other - and on an empty payload it would still pass.
        val empty = envelopeWithPrefix(4, extendedVarint(0, 10))
        assertEquals("pong", FrameCodec.readFrame(empty, FrameDirection.CLIENT).payloadType)
        assertEquals("ack", FrameCodec.readFrame(empty, FrameDirection.SERVER).payloadType)
    }

    // --- Length-prefix widths -----------------------------------------------

    @Test
    fun `spans both varint width boundaries without a discontinuity`() {
        // 127/128 and 16383/16384 differ only in the prefix; the payload
        // boundary is where the prefix changes, not the payload.
        assertEquals(1, varintSize(127))
        assertEquals(2, varintSize(128))
        assertEquals(2, varintSize(16383))
        assertEquals(3, varintSize(16384))
        for (size in listOf(127, 128, 16383, 16384)) {
            val payload = pongPayloadOfSize(size)
            val frame = FrameCodec.encodeFrame(FrameCodec.SERVER_TAG_PONG, payload, FrameDirection.SERVER)
            assertEquals("payload of $size bytes", 1 + varintSize(size.toLong()) + size, frame.size)
            assertEquals(FrameCodec.SERVER_TAG_PONG, frame[0].toInt())
            val decoded = FrameCodec.readFrame(frame, FrameDirection.SERVER)
            assertEquals(size, decoded.payload.size)
            assertArrayEquals(payload, decoded.payload)
            assertEquals(
                pongCorrelationIdOfSize(size),
                (FrameCodec.decode(decoded, FrameDirection.SERVER) as Pong).correlation_id,
            )
        }
    }

    private fun failure(bytes: ByteArray): MalformedFrameException {
        val thrown = runCatching { FrameCodec.readFrame(bytes, FrameDirection.SERVER) }.exceptionOrNull()
        assertTrue("expected a malformed envelope for ${bytesToHex(bytes.take(12))}..., got $thrown", thrown is MalformedFrameException)
        return thrown as MalformedFrameException
    }
}

private fun ByteArray.take(n: Int): ByteArray = copyOfRange(0, minOf(n, size))