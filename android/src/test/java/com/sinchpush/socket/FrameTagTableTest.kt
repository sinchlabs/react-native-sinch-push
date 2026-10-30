package com.sinchpush.socket

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import sinch.push.delivery.v1beta1.ws.ClientFrame
import sinch.push.delivery.v1beta1.ws.ServerFrame
import com.squareup.wire.WireField

/**
 * SB-02 — the frame tag table must be the schema's, not a copy of it.
 *
 * The tag byte is the field number of the `oneof payload` member, so a copy of
 * those numbers in `FrameCodec` is a second source of truth that only the tests
 * know about. wire-compiler does not emit a lookup table for a Kotlin oneof
 * (`ServerFrame.PAYLOAD` only exists with `javaInterop`), so this test is what
 * derives the truth: it reads the `@WireField(tag = ...)` of every member
 * straight off the generated classes and requires the codec's table to be
 * exactly that, in both directions.
 *
 * Reflecting here, in a JVM test, is the point - not in production. A runtime
 * implementation would have to keep constructor parameters and their field tags
 * alive under R8, and would still be a second derivation; a test costs neither
 * and fails the build the moment a proto is renumbered.
 */
class FrameTagTableTest {

    /** `ServerFrame.payload` and `ClientFrame.payload`, as generated. */
    private fun generatedTags(oneofClass: Class<*>): Map<String, Int> {
        val tags = mutableMapOf<String, Int>()
        // @WireField is a FIELD-target annotation, and the generated Kotlin puts
        // it on the backing field of each oneof member, whose name is the proto
        // field name - the same name FrameCodec keys its table by.
        for (field in oneofClass.declaredFields) {
            val wireField = field.getAnnotation(WireField::class.java) ?: continue
            if (wireField.oneofName != "payload") continue
            tags[field.name] = wireField.tag
        }
        assertTrue("$oneofClass declares no payload members", tags.isNotEmpty())
        return tags
    }

    private fun codecTable(direction: FrameDirection): Map<String, Int> {
        val out = linkedMapOf<String, Int>()
        for (tag in 0..255) {
            if (!FrameCodec.isKnownTag(direction, tag)) continue
            out[FrameCodec.payloadType(direction, tag)] = tag
        }
        return out
    }

    @Test
    fun `server tags are the generated ServerFrame payload tags`() {
        assertEquals(generatedTags(ServerFrame::class.java), codecTable(FrameDirection.SERVER))
    }

    @Test
    fun `client tags are the generated ClientFrame payload tags`() {
        assertEquals(generatedTags(ClientFrame::class.java), codecTable(FrameDirection.CLIENT))
    }

    @Test
    fun `client tags are a strict subset of server tags`() {
        // The relay's own rule: a client decoder can never raise wrong_direction_tag
        // on a tag the server sends, and tags 5..7 belong to the server alone.
        val client = codecTable(FrameDirection.CLIENT).values
        val server = codecTable(FrameDirection.SERVER).values
        assertTrue("client tags must be a subset of server tags", server.containsAll(client))
        assertEquals(
            "ServerFrame owns the tags ClientFrame does not",
            listOf(5, 6, 7),
            server.filterNot { it in client },
        )
    }

    @Test
    fun `every tag is writable as the one byte that carries it`() {
        // A field number of 256 wraps to 0 on the wire and is read by the relay as
        // a different payload type, so FrameCodec refuses to construct the table
        // with one. Asserted here as well so the failure is visible as a test.
        for (direction in FrameDirection.values()) {
            for (tag in 0..255) {
                if (!FrameCodec.isKnownTag(direction, tag)) continue
                assertTrue("$direction tag $tag must be in 1..255", tag in 1..255)
                assertEquals(
                    "$direction tag $tag survives the byte it is written as",
                    tag,
                    (tag.toByte().toInt() and 0xFF),
                )
            }
        }
    }

    @Test
    fun `each payload adapter is the one for the message the tag names`() {
        // The table pairs a tag with an adapter; this asserts the pairing is the
        // schema's, per direction - `pong` is tag 4 on the way out and tag 6 on
        // the way in, so a merged table would hide exactly the mix-up this is
        // meant to catch.
        for ((direction, frame) in listOf(
            FrameDirection.CLIENT to ClientFrame::class.java,
            FrameDirection.SERVER to ServerFrame::class.java,
        )) {
            val expected = generatedTags(frame)
            for (tag in 0..255) {
                if (!FrameCodec.isKnownTag(direction, tag)) continue
                val name = FrameCodec.payloadType(direction, tag)
                assertEquals("$direction $name is the generated field number", expected[name], tag)
                val adapter = FrameCodec.adapter<WireMessage>(direction, tag)
                assertNotNull("$direction tag $tag has an adapter", adapter)
                assertEquals(
                    "$direction tag $tag carries $name",
                    Class.forName("sinch.push.delivery.v1beta1.ws.${messageClassName(name)}"),
                    adapter.type?.java,
                )
            }
        }
    }

    /** `delivery_report` -> `DeliveryReport`, the generated class name for a member. */
    private fun messageClassName(payloadName: String): String =
        payloadName.split('_').joinToString("") { part ->
            part.replaceFirstChar { it.uppercase() }
        }
}