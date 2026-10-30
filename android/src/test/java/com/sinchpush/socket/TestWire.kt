package com.sinchpush.socket

import sinch.push.delivery.v1beta1.ws.Pong

/**
 * Byte-level helpers for the frame codec tests.
 *
 * These build envelopes by hand rather than through [FrameCodec.encodeFrame], so
 * a test can assert what the decoder does with bytes the encoder would never
 * produce: a length prefix of a chosen width, a declared length that does not
 * match the body, a prefix whose tenth byte overflows 64 bits. The TypeScript
 * equivalents live in `__tests__/utils/wire.ts` at tag `ts-socket-client-snapshot`.
 */

/**
 * Unsigned varint of [value], as the bytes that go on the wire.
 *
 * Unsigned on purpose: protobuf sign-extends a negative `int64` across ten
 * bytes, so the loop bound is compared unsigned too and the shift is a logical
 * one. A signed comparison would stop on the first byte of any negative value
 * and write its low seven bits alone - the same truncation the production
 * `writeVarInt` had.
 */
fun varintBytes(value: Long): ByteArray {
    val out = mutableListOf<Byte>()
    var rest = value
    while (java.lang.Long.compareUnsigned(rest, 0x80L) >= 0) {
        out.add((((rest and 0x7FL).toInt()) or 0x80).toByte())
        rest = rest ushr 7
    }
    out.add((rest.toInt() and 0x7F).toByte())
    return out.toByteArray()
}

/** Bytes an unsigned varint of [value] occupies. */
fun varintSize(value: Long): Int = varintBytes(value).size

/** Concatenation of ints (0..255) and byte arrays. */
fun bytesOf(vararg parts: Any): ByteArray {
    val out = mutableListOf<Byte>()
    for (part in parts) {
        when (part) {
            is Int -> out.add(part.toByte())
            is Byte -> out.add(part)
            is ByteArray -> for (b in part) out.add(b)
            else -> error("bytesOf: unsupported part $part")
        }
    }
    return out.toByteArray()
}

/** `[tag][varint(payload.length)][payload]`, written out by hand. */
fun envelope(tag: Int, payload: ByteArray): ByteArray =
    bytesOf(tag, varintBytes(payload.size.toLong()), payload)

/** `[tag][prefix as given][body]`, for prefixes [varintBytes] cannot produce. */
fun envelopeWithPrefix(tag: Int, prefix: ByteArray, body: ByteArray = ByteArray(0)): ByteArray =
    bytesOf(tag, prefix, body)

/** `[tag][varint(declared)][filler]`, where the body is deliberately too short. */
fun frameDeclaring(tag: Int, declared: Long, bodyBytes: Int): ByteArray =
    bytesOf(tag, varintBytes(declared), ByteArray(bodyBytes) { 'A'.code.toByte() })

/**
 * The same value as [varintBytes], extended to exactly [width] bytes without
 * changing what it decodes to.
 *
 * The obvious padding is wrong: leading `0x80` continuation bytes *shift* the
 * value by 128 for every group added, so `[80 80 04]` (65536) padded to ten
 * bytes as `[80 x7 80 80 04]` decodes to 65536 * 128^7 - it looks like padding
 * and silently encodes a different number.
 *
 * The construction that does work keeps every significant group where it is and
 * extends past it: set the canonical terminal byte's high bit so it becomes a
 * continuation carrying the same data bits, then append zero groups terminated
 * by `00`.
 *
 * ```
 * 65536 canonical   80 80 04
 * extended to 10    80 80 84 80 80 80 80 80 80 00   -> decodes 65536
 * ```
 *
 * This is the form protobuf permits and the relay accepts, so it is the shape a
 * non-canonical peer can actually send - and the reason the accepted frame bound
 * (65547) is wider than the emitted one (65540).
 */
fun extendedVarint(value: Long, width: Int): ByteArray {
    val canonical = varintBytes(value)
    require(width >= canonical.size) { "cannot extend a ${canonical.size}-byte varint to $width bytes" }
    if (width == canonical.size) return canonical
    val groups = canonical.toMutableList()
    groups[groups.size - 1] = (groups[groups.size - 1].toInt() or 0x80).toByte()
    return bytesOf(
        bytesOf(*groups.toTypedArray()),
        ByteArray(width - canonical.size - 1) { 0x80.toByte() },
        0x00,
    )
}

/** Lowercase hex of [bytes], the fixture's `frame_hex` format. */
fun bytesToHex(bytes: ByteArray): String =
    bytes.joinToString("") { b ->
        val v = b.toInt() and 0xFF
        val digits = "0123456789abcdef"
        "${digits[v ushr 4]}${digits[v and 0x0F]}"
    }

/** Parses lowercase or uppercase hex into bytes. */
fun hexToBytes(hex: String): ByteArray {
    val clean = hex.trim()
    require(clean.length % 2 == 0) { "odd-length hex: $clean" }
    val out = ByteArray(clean.length / 2)
    for (i in out.indices) {
        val high = Character.digit(clean[i * 2], 16)
        val low = Character.digit(clean[i * 2 + 1], 16)
        require(high >= 0 && low >= 0) { "not hex: $clean" }
        out[i] = ((high shl 4) or low).toByte()
    }
    return out
}

/**
 * A `correlation_id` of the length that makes a `Pong` payload [size] bytes.
 *
 * A Pong is the tag byte, the string's length prefix and the string, so the
 * payload grows by one at 128 and again at 16384 - the same boundaries the
 * envelope's own length prefix has.
 *
 * Encoded through the generated adapter, which is what the SDK writes with, so
 * the boundary payloads really are Pong messages and not filler that happens to
 * be the right size.
 */
fun pongCorrelationIdOfSize(size: Int): String {
    for (k in size downTo 0) {
        val candidate = "C".repeat(k)
        if (pongPayload(candidate).size == size) return candidate
    }
    error("no Pong payload serialises to exactly $size bytes")
}

/**
 * A serialized `Pong` payload of exactly [size] bytes, built through the
 * generated adapter so the boundary payloads are real messages rather than
 * filler.
 */
fun pongPayloadOfSize(size: Int): ByteArray = pongPayload(pongCorrelationIdOfSize(size))

/** The bytes of a `Pong` as the SDK writes them: the bare oneof member. */
fun pongPayload(correlationId: String): ByteArray =
    Pong.ADAPTER.encode(Pong(correlation_id = correlationId))

/** One top-level protobuf field of a message payload. */
sealed class ProtoField {
    data class Varint(val value: Long) : ProtoField()
    data class Bytes(val value: ByteArray) : ProtoField() {
        override fun equals(other: Any?): Boolean =
            other is Bytes && value.contentEquals(other.value)

        override fun hashCode(): Int = value.contentHashCode()
    }

    val isDefault: Boolean
        get() = when (this) {
            is Varint -> value == 0L
            is Bytes -> value.isEmpty()
        }

    fun asString(): String = when (this) {
        is Varint -> error("field is a varint, not a string")
        is Bytes -> String(value, Charsets.UTF_8)
    }

    fun asLong(): Long = when (this) {
        is Varint -> value
        is Bytes -> error("field is length-delimited, not a varint")
    }
}

/**
 * Top-level fields of a protobuf message payload, by field number.
 *
 * An independent reader, so a test can compare what the fixture's bytes say
 * against what [FrameCodec] produces without going through FrameCodec to read
 * the expectation. Fixed-width fields are not needed by any message in
 * `websocket.proto` and are skipped rather than decoded.
 */
fun protoFields(payload: ByteArray): Map<Int, ProtoField> {
    val out = linkedMapOf<Int, ProtoField>()
    var i = 0
    while (i < payload.size) {
        val (key, next) = readVarintAt(payload, i)
        i = next
        val number = (key ushr 3).toInt()
        when (val wire = (key and 0x7L).toInt()) {
            0 -> {
                val (value, after) = readVarintAt(payload, i)
                i = after
                out[number] = ProtoField.Varint(value)
            }
            2 -> {
                val (length, afterLength) = readVarintAt(payload, i)
                val end = afterLength + length.toInt()
                require(end <= payload.size) { "protobuf: truncated field $number" }
                out[number] = ProtoField.Bytes(payload.copyOfRange(afterLength, end))
                i = end
            }
            1, 5 -> i += if (wire == 1) 8 else 4
            else -> error("protobuf: unsupported wire type $wire")
        }
    }
    return out
}

/**
 * [protoFields] without the fields a proto3 encoder omits when they hold the
 * default: a zero varint, or a length-delimited field of no bytes.
 */
fun significantFields(payload: ByteArray): Map<Int, ProtoField> =
    protoFields(payload).filterValues { !it.isDefault }

private fun readVarintAt(bytes: ByteArray, start: Int): Pair<Long, Int> {
    var result = 0L
    var shift = 0
    var i = start
    while (true) {
        require(i < bytes.size) { "protobuf: truncated varint" }
        val b = bytes[i].toInt() and 0xFF
        i++
        require(shift <= 63 && (shift < 63 || b <= 0x01)) { "protobuf: varint overflows 64 bits" }
        result = result or ((b and 0x7F).toLong() shl shift)
        if ((b and 0x80) == 0) return result to i
        shift += 7
    }
}