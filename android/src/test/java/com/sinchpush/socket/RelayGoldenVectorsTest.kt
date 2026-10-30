package com.sinchpush.socket

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import sinch.push.delivery.v1beta1.ws.Ack
import sinch.push.delivery.v1beta1.ws.Close
import sinch.push.delivery.v1beta1.ws.CloseReason
import sinch.push.delivery.v1beta1.ws.DeliveryReport
import sinch.push.delivery.v1beta1.ws.Hello
import sinch.push.delivery.v1beta1.ws.HelloAck
import sinch.push.delivery.v1beta1.ws.Message
import sinch.push.delivery.v1beta1.ws.Ping
import sinch.push.delivery.v1beta1.ws.Platform
import sinch.push.delivery.v1beta1.ws.Pong
import sinch.push.delivery.v1beta1.ws.Poll
import sinch.push.v1beta1.resources.BackgroundServiceState
import sinch.push.v1beta1.resources.Importance

/**
 * Kotlin conformance against the relay's golden wire vectors.
 *
 * `ws_frames.v1beta1.golden.json` is generated from the same Go codec the relay
 * runs (relay: `make golden-vectors`), so it cannot drift from the relay's
 * implementation without a relay test failing. This suite is the Kotlin half of
 * that contract, in both directions.
 *
 * The fixture is pinned like the protos: `npm run proto:fetch` copies
 * `testdata/wire/ws_frames.v1beta1.golden.json` out of the relay commit recorded
 * in proto-sources.json into this repository's gitignored `proto-testdata/`, so
 * the vectors under test are the ones the generated Wire code was built from.
 * `RELAY_DIR` (or the `relay.dir` system property) and a sibling
 * `../sinch-push-relay` checkout are still honoured as overrides. When none of
 * them resolves the suite skips rather than fails, so `npm run test:android`
 * still works without the fixture.
 */
class RelayGoldenVectorsTest {

    private lateinit var golden: Map<String, Any?>

    @Before
    fun loadFixture() {
        val file = RelayGoldenVectors.locate()
        assumeTrue(
            "relay golden vectors not found; run `npm run proto:fetch` to copy the pinned fixture " +
                "into proto-testdata/, or set RELAY_DIR to a sinch-push-relay checkout " +
                "(looked in: ${RelayGoldenVectors.searchDescription()})",
            file != null,
        )
        golden = TestJson.parse(file!!.readText()).jsonObject()
    }

    private val frames: List<Map<String, Any?>>
        get() = golden.objects("frames")

    private val negativeCases: List<Map<String, Any?>>
        get() = golden.objects("negative_cases")

    private fun directionOf(vector: Map<String, Any?>): FrameDirection =
        when (vector.string("direction")) {
            "client_to_server" -> FrameDirection.CLIENT
            "server_to_client" -> FrameDirection.SERVER
            else -> error("unknown direction ${vector.string("direction")}")
        }

    /** The `oneof payload` member name, e.g. `ServerFrame.hello_ack` -> `hello_ack`. */
    private fun payloadName(vector: Map<String, Any?>): String =
        vector.string("frame_type").substringAfter('.')

    private fun payloadOf(vector: Map<String, Any?>): ByteArray =
        hexToBytes(vector.string("payload_hex"))

    private fun frameOf(vector: Map<String, Any?>): ByteArray =
        hexToBytes(vector.string("frame_hex"))

    private fun byName(name: String): Map<String, Any?> =
        frames.single { it.string("name") == name }

    @Test
    fun `loaded the fixture the relay generated`() {
        assertEquals("fixture schema version", 1, golden.int("version"))
        // 48 = 19 client_to_server + 29 server_to_client: four Hello vectors carry
        // the device-info fields 9-12 and RELAY_DISABLED.
        assertEquals("positive vectors", 48, frames.size)
        assertEquals("negative cases", 14, negativeCases.size)
        assertTrue("framing is documented in the fixture", golden.string("framing").isNotEmpty())
    }

    @Test
    fun `agrees with the relay on the payload size contract`() {
        val contract = golden.field("size_contract").jsonObject()
        assertEquals(
            "max_frame_payload_bytes is the protocol limit, not a tuning knob",
            FrameCodec.MAX_FRAME_PAYLOAD_BYTES,
            contract.int("max_frame_payload_bytes"),
        )
        assertEquals(
            "max_wire_frame_bytes is 1 tag + a 10-byte varint + payload",
            FrameCodec.MAX_FRAME_TOTAL_BYTES,
            contract.int("max_wire_frame_bytes"),
        )
        assertEquals(
            "the envelope we emit is 1 tag byte + the canonical 3-byte prefix",
            FrameCodec.MAX_FRAME_EMITTED_BYTES - FrameCodec.MAX_FRAME_PAYLOAD_BYTES,
            contract.int("canonical_envelope_max_bytes"),
        )
    }

    @Test
    fun `resolves exactly the tag table the relay derives`() {
        val types = golden.objects("frame_types")
        for (entry in types) {
            val direction = if (entry.string("direction") == "client_to_server") {
                FrameDirection.CLIENT
            } else {
                FrameDirection.SERVER
            }
            assertEquals(
                entry.string("frame_type"),
                entry.string("frame_type").substringAfter('.'),
                FrameCodec.payloadType(direction, entry.int("tag")),
            )
        }
        // ...and nothing else does, in either direction. The relay's own rule:
        // client tags are a strict subset of server tags, so a server decoder
        // can never raise wrong_direction_tag while a client decoder must
        // refuse 5, 6 and 7.
        val clientTags = types.filter { it.string("direction") == "client_to_server" }.map { it.int("tag") }
        val serverTags = types.filter { it.string("direction") == "server_to_client" }.map { it.int("tag") }
        for (tag in 0..255) {
            assertEquals(
                "client tag $tag",
                tag in clientTags,
                resolves(FrameDirection.CLIENT, tag),
            )
            assertEquals(
                "server tag $tag",
                tag in serverTags,
                resolves(FrameDirection.SERVER, tag),
            )
        }
    }

    private fun resolves(direction: FrameDirection, tag: Int): Boolean =
        runCatching { FrameCodec.payloadType(direction, tag) }.isSuccess

    @Test
    fun `decodes every positive vector to the payload the relay names`() {
        for (vector in frames) {
            val decoded = FrameCodec.readFrame(frameOf(vector), directionOf(vector))
            assertEquals("${vector.string("name")}: tag", vector.int("tag"), decoded.tag)
            assertEquals(
                "${vector.string("name")}: payload type",
                payloadName(vector),
                decoded.payloadType,
            )
            assertEquals(
                "${vector.string("name")}: payload bytes",
                vector.string("payload_hex"),
                bytesToHex(decoded.payload),
            )
            assertEquals(
                "${vector.string("name")}: payload length",
                vector.int("payload_len"),
                decoded.payload.size,
            )
        }
    }

    @Test
    fun `re-encodes every positive vector byte for byte`() {
        for (vector in frames) {
            val bytes = frameOf(vector)
            val direction = directionOf(vector)
            val decoded = FrameCodec.readFrame(bytes, direction)
            // Asserted against the wire bytes, not against a re-serialised
            // message: the tag byte and the length prefix are exactly what a
            // hand-rolled envelope gets wrong, and comparing payloads would hide
            // both.
            assertEquals(
                "${vector.string("name")}: re-encoded frame",
                bytesToHex(bytes),
                bytesToHex(FrameCodec.encodeFrame(decoded.tag, decoded.payload, direction)),
            )
        }
    }

    @Test
    fun `encodes the client payloads the way the relay encoded them`() {
        // The other direction through the codec: read the relay's bytes with an
        // independent reader, push the values into the generated messages, encode
        // them through FrameCodec, and compare. Significant fields are compared
        // because proto3 omits defaults; where the vector carries every field of
        // the message the bytes match exactly, which is asserted too - and now
        // they can, because Wire writes fields in schema order exactly as the
        // relay's Go codec does.
        for (vector in frames.filter { it.string("direction") == "client_to_server" }) {
            val name = vector.string("name")
            val payload = payloadOf(vector)
            val fields = protoFields(payload)
            if (name == "client_delivery_report_future_status") {
                // The relay's forward-compatibility vector: status 7, a value this
                // build's enum does not have, and the one case where "read the
                // relay's bytes, rebuild the message, encode it" is not a valid
                // comparison. A generated enum is a closed set, so a message built
                // from the vector's fields can only hold STATUS_UNSPECIFIED and the
                // 7 is gone - not a Wire defect, just what proto3 allows.
                //
                // What does have to hold, and is asserted here instead: the decode
                // does not fail, and the wire bytes survive a decode/encode round
                // trip, because Wire keeps a value it cannot map in the message's
                // unknown fields rather than dropping it. A client re-sending
                // status 7 to a newer relay therefore still says 7.
                assertEquals("the vector really is a status this build lacks", 7L, fields.num(3))
                assertNull(
                    "7 is not a Status in the pinned proto",
                    DeliveryReport.Status.fromValue(fields.num(3).toInt()),
                )
                val decoded = DeliveryReport.ADAPTER.decode(payload)
                assertEquals("message_id survives an unknown status", "m-1", decoded.message_id)
                assertEquals(
                    "an unknown status maps to the enum default",
                    DeliveryReport.Status.STATUS_UNSPECIFIED,
                    decoded.status,
                )
                assertTrue(
                    "the unmappable value is kept as an unknown field, not discarded",
                    decoded.unknownFields.size > 0,
                )
                assertEquals(
                    "$name: decode/encode is byte-exact",
                    bytesToHex(payload),
                    bytesToHex(
                        FrameCodec.readFrame(
                            FrameCodec.encode(decoded, FrameDirection.CLIENT),
                            FrameDirection.CLIENT,
                        ).payload,
                    ),
                )
                continue
            }
            if (payloadName(vector) == "poll" && 1 in fields) {
                // Poll.cursor is reserved and unused by the relay, so the
                // encoder has no value to put in it; the frame itself is covered
                // by the envelope tests above.
                assertEquals("cursor survives the envelope", "cursor-abc", fields[1]?.asString())
                continue
            }
            if (payloadName(vector) == "hello" && 12 in fields && fields[12]!!.asLong() !in 0L..5L) {
                // The relay's forward-compatibility vector for the device-info
                // fields: background_service carries a value this build's enum
                // does not have (99). Same reasoning as the unknown status above,
                // and the same guarantee: a decode must not fail, the unmappable
                // value has to be kept as an unknown field, and the bytes must
                // survive a decode/encode round trip - an SDK talking to a newer
                // relay still says what the device reported.
                // UNSPECIFIED(0)..RELAY_DISABLED(5) is the closed set this proto
                // version defines; a 99 is outside it and takes this path.
                assertEquals("the vector really is a state this build lacks", 99L, fields.num(12))
                assertNull(
                    "99 is not a BackgroundServiceState in the pinned proto",
                    BackgroundServiceState.fromValue(99),
                )
                val decoded = Hello.ADAPTER.decode(payload)
                assertEquals(
                    "an unknown background_service (99) maps to the enum default while the value is kept",
                    BackgroundServiceState.BACKGROUND_SERVICE_STATE_UNSPECIFIED,
                    decoded.background_service,
                )
                assertTrue(
                    "the unmappable value is kept as an unknown field, not discarded",
                    decoded.unknownFields.size > 0,
                )
                assertEquals(
                    "$name: decode/encode is byte-exact",
                    bytesToHex(payload),
                    bytesToHex(
                        FrameCodec.readFrame(
                            FrameCodec.encode(decoded, FrameDirection.CLIENT),
                            FrameDirection.CLIENT,
                        ).payload,
                    ),
                )
                continue
            }
            val message: WireMessage = when (payloadName(vector)) {
                "hello" -> Hello(
                    auth_token = fields.str(1),
                    project_id = fields.str(2),
                    app_id = fields.str(3),
                    user_id = fields.str(4),
                    platform = Platform.fromValue(fields.num(5).toInt())
                        ?: Platform.PLATFORM_UNSPECIFIED,
                    background = fields.num(6) != 0L,
                    last_seen_message_id = fields.str(7),
                    sdk_version = fields.str(8),
                    // Device info, relay routing (Hello fields 9-12).
                    installation_id = fields.str(9),
                    os_version = fields.str(10),
                    bundle_id = fields.str(11),
                    background_service = BackgroundServiceState.fromValue(fields.num(12).toInt())
                        ?: BackgroundServiceState.BACKGROUND_SERVICE_STATE_UNSPECIFIED,
                )
                "poll" -> Poll()
                "pong" -> Pong(correlation_id = fields.str(1))
                "delivery_report" -> DeliveryReport(
                    message_id = fields.str(1),
                    sinch_message_id = fields.str(2),
                    status = DeliveryReport.Status.fromValue(fields.num(3).toInt())
                        ?: DeliveryReport.Status.STATUS_UNSPECIFIED,
                    reason = fields.str(4),
                    reported_at_unix_millis = fields.num(5),
                )
                else -> error("no encoder for $name (${payloadName(vector)})")
            }
            // The payload as the SDK writes it: framed, then read back with the
            // same envelope reader the other half of this suite uses, so the
            // comparison is against the relay's payload bytes and not against a
            // second opinion about the framing.
            val encoded = FrameCodec.readFrame(
                FrameCodec.encode(message, FrameDirection.CLIENT),
                FrameDirection.CLIENT,
            ).payload
            assertEquals("$name: encoded fields", significantFields(payload), significantFields(encoded))
            if (fields.keys.containsAll(writtenFields(payloadName(vector)))) {
                assertEquals("$name: encoded bytes", bytesToHex(payload), bytesToHex(encoded))
            }
        }
    }

    /** Field numbers a message of this payload type can carry on the wire. */
    private fun writtenFields(payloadType: String): List<Int> = when (payloadType) {
        "hello" -> (1..12).toList()
        "pong" -> listOf(1)
        "poll" -> emptyList()
        "delivery_report" -> (1..5).toList()
        else -> error("no encoder for $payloadType")
    }

    private fun Map<Int, ProtoField>.str(number: Int): String = this[number]?.asString() ?: ""

    private fun Map<Int, ProtoField>.num(number: Int): Long = this[number]?.asLong() ?: 0L

    @Test
    fun `decodes the Hello device-info vectors into the named fields`() {
        // Byte-for-byte round tripping does not prove the SDK *knows* Hello fields
        // 9-12: Wire keeps a field it has no message member for as an unknown
        // field, so a stale generated adapter would still re-emit the fixture's
        // bytes. What the relay reads is the named field, so that is asserted.
        val ios = Hello.ADAPTER.decode(payloadOf(byName("client_hello_device_info")))
        assertEquals("installation_id", "6f1c2a9e-3b7d-4e8a-9c21-5d4b7a0e1f23", ios.installation_id)
        assertEquals("os_version", "18.1", ios.os_version)
        assertEquals("bundle_id", "com.sinch.example", ios.bundle_id)
        // iOS has no background socket.
        assertEquals(BackgroundServiceState.UNSUPPORTED, ios.background_service)
        assertEquals(Platform.IOS, ios.platform)
        assertEquals(false, ios.background)

        // background = true with ENABLED_RUNNING: the only pairing the relay
        // treats as reachable in the background.
        val android = Hello.ADAPTER.decode(payloadOf(byName("client_hello_android_bg_running")))
        assertEquals("installation_id", "0b8f3d52-7c1e-4a96-b5d0-2e9f6a4c8d17", android.installation_id)
        assertEquals("os_version", "14", android.os_version)
        assertEquals("bundle_id", "com.sinch.example", android.bundle_id)
        assertEquals(BackgroundServiceState.ENABLED_RUNNING, android.background_service)
        assertEquals(Platform.ANDROID, android.platform)
        assertEquals(true, android.background)

        // background_service = RELAY_DISABLED: the relay switch is off in the
        // app, so the SDK holds no socket and no background service, and
        // sinch-push must not route this installation over the relay at all.
        // background = false is what makes the Hello consistent rather than
        // self-contradictory.
        val relayOff = Hello.ADAPTER.decode(payloadOf(byName("client_hello_relay_disabled")))
        assertEquals("installation_id", "3c9e1f7a-52b4-4d08-9a6e-1b7c2d5e8f40", relayOff.installation_id)
        assertEquals("os_version", "14", relayOff.os_version)
        assertEquals("bundle_id", "com.sinch.example", relayOff.bundle_id)
        assertEquals(BackgroundServiceState.RELAY_DISABLED, relayOff.background_service)
        assertEquals(Platform.ANDROID, relayOff.platform)
        assertEquals(false, relayOff.background)
        assertEquals(
            "RELAY_DISABLED is a member of the pinned enum, so nothing is left as an unknown field",
            0,
            relayOff.unknownFields.size,
        )

        // background_service = 99 is a state this proto version does not define.
        // It has to survive as an unknown field rather than being dropped, so an
        // SDK meeting a newer relay still reports what the device said.
        val future = Hello.ADAPTER.decode(payloadOf(byName("client_hello_unknown_background_service")))
        assertEquals(
            "the same installation id, only the state differs",
            android.installation_id,
            future.installation_id,
        )
        assertEquals(
            "an unmappable state maps to the enum default",
            BackgroundServiceState.BACKGROUND_SERVICE_STATE_UNSPECIFIED,
            future.background_service,
        )
        assertTrue(
            "the unmappable state is kept as an unknown field, not discarded",
            future.unknownFields.size > 0,
        )

        // The vector that predates the fields still decodes, and the new members
        // read as absent rather than as a value the relay would take literally.
        val old = Hello.ADAPTER.decode(payloadOf(byName("client_hello_full")))
        assertEquals("sdk_version", "1.2.3", old.sdk_version)
        assertEquals("", old.installation_id)
        assertEquals("", old.os_version)
        assertEquals("", old.bundle_id)
        assertEquals(BackgroundServiceState.BACKGROUND_SERVICE_STATE_UNSPECIFIED, old.background_service)
    }

    @Test
    fun `decodes the server payloads to what the relay encoded`() {
        // Spot checks on the payloads FrameCodec decodes, with the values read
        // out of the relay's own bytes. The envelope tests prove the frames
        // decode; these prove the payloads mean what the relay meant. Every
        // payload goes through the generated adapter for the message its tag
        // names - the same path the client takes in handleFrame.
        val ack = HelloAck.ADAPTER.decode(payloadOf(byName("server_hello_ack_with_messages")))
        assertEquals("connection_id", "conn-xyz", ack.connection_id)
        assertEquals("poll_interval_ms", 5000, ack.poll_interval_ms)
        assertEquals("pooled messages", 2, ack.messages.size)
        assertEquals("message_id", "m-1", ack.messages[0].message_id)
        assertEquals("sinch_message_id", "sm-1", ack.messages[0].sinch_message_id)
        assertEquals("enqueued_at_unix_millis", 1700000000000L, ack.messages[0].enqueued_at_unix_millis)
        val push = ack.messages[0].push_notification
        assertNotNull("push_notification", push)
        push!!
        assertEquals("tracking_id", "track-1", push.tracking_id)
        assertEquals("alert.title", "Ünicode — ☃ snowman, 日本語, emoji 🚀", push.alert?.title)
        assertEquals("alert.message", "line one\nline two\ttabbed \"quoted\" \\escaped\\", push.alert?.message)
        assertEquals("importance HIGH", Importance.IMPORTANCE_HIGH, push.importance)
        assertEquals("trigger", "trigger-value", push.trigger)
        // Deterministic marshalling sorts map entries; the vector only carries
        // the relay's values if the entries survive in that order.
        assertEquals(
            "metadata in fixture order",
            listOf("alpha" to "first", "mu" to "greek", "zeta" to "last"),
            push.metadata.toList(),
        )
        assertNull("a pooled message with no notification", ack.messages[1].push_notification)

        val message = Message.ADAPTER.decode(payloadOf(byName("server_message_nested_notification")))
        assertEquals("ack_token", "m-1", message.ack_token)
        assertEquals("message_id", "m-1", message.message?.message_id)
        assertEquals("sinch_message_id", "sm-1", message.message?.sinch_message_id)
        assertEquals(
            "title",
            "Ünicode — ☃ snowman, 日本語, emoji 🚀",
            message.message?.push_notification?.alert?.title,
        )

        val accepted = Ack.ADAPTER.decode(payloadOf(byName("server_ack_accepted")))
        assertEquals("m-1:1", accepted.ack_token)
        assertTrue("accepted", accepted.accepted)
        // proto3 has no presence for a scalar string, so "no error" and "an empty
        // error" are the same field: SB-36 maps empty to absent.
        assertEquals("no error on an accepted ack", "", accepted.error)

        val rejected = Ack.ADAPTER.decode(payloadOf(byName("server_ack_rejected_upstream")))
        assertEquals("m-1:1", rejected.ack_token)
        assertEquals("upstream_forward_failed", rejected.error)
        assertTrue("accepted is false when the relay rejects", !rejected.accepted)

        val legacy = Ack.ADAPTER.decode(payloadOf(byName("server_ack_accepted_empty_token")))
        assertEquals("the legacy Ack carried an empty token", "", legacy.ack_token)
        assertTrue(legacy.accepted)

        val uncorrelatable = Ack.ADAPTER.decode(payloadOf(byName("server_ack_rejected_missing_message_id")))
        assertEquals("an uncorrelatable report is rejected with an empty token", "", uncorrelatable.ack_token)
        assertEquals("missing_message_id", uncorrelatable.error)

        assertEquals(
            "ping correlation_id",
            "ping-7",
            Ping.ADAPTER.decode(payloadOf(byName("server_ping_correlation_id"))).correlation_id,
        )
        assertEquals(
            "",
            Ping.ADAPTER.decode(payloadOf(byName("server_ping_empty"))).correlation_id,
        )

        val shutdown = Close.ADAPTER.decode(payloadOf(byName("server_close_shutdown")))
        assertEquals(CloseReason.SHUTDOWN, shutdown.reason)
        assertEquals("relay draining", shutdown.detail)
        assertEquals(
            CloseReason.UNAUTHORIZED,
            Close.ADAPTER.decode(payloadOf(byName("server_close_unauthorized"))).reason,
        )
        assertEquals(
            CloseReason.STALE,
            Close.ADAPTER.decode(payloadOf(byName("server_close_stale"))).reason,
        )
        assertEquals(
            "the relay's own answer to a bad tag",
            "wrong_direction_tag",
            Close.ADAPTER.decode(payloadOf(byName("server_close_internal_protocol_violation"))).detail,
        )
        assertEquals(
            CloseReason.INTERNAL,
            Close.ADAPTER.decode(payloadOf(byName("server_close_internal_unknown_tag"))).reason,
        )
        assertEquals(
            "reason 0 = CLOSE_REASON_UNSPECIFIED",
            CloseReason.CLOSE_REASON_UNSPECIFIED,
            Close.ADAPTER.decode(payloadOf(byName("server_close_empty"))).reason,
        )
        // The numbers behind the enum names, so a regenerated enum that renumbered
        // the relay's values cannot pass by renaming alone.
        assertEquals("UNAUTHORIZED", 1, CloseReason.UNAUTHORIZED.value)
        assertEquals("STALE", 2, CloseReason.STALE.value)
        assertEquals("POOL_FULL", 3, CloseReason.POOL_FULL.value)
        assertEquals("INTERNAL", 4, CloseReason.INTERNAL.value)
        assertEquals("BG_RESUMED", 5, CloseReason.BG_RESUMED.value)
        assertEquals("SHUTDOWN", 6, CloseReason.SHUTDOWN.value)

        // int64 and int32 boundaries: the sign-extended ten-byte varints the
        // fixture uses to reach them.
        assertEquals(
            "int32 poll_interval_ms max",
            Int.MAX_VALUE,
            HelloAck.ADAPTER.decode(payloadOf(byName("int32_boundary_hello_ack_poll_interval_max"))).poll_interval_ms,
        )
        assertEquals(
            "int32 poll_interval_ms min",
            Int.MIN_VALUE,
            HelloAck.ADAPTER.decode(payloadOf(byName("int32_boundary_hello_ack_poll_interval_min"))).poll_interval_ms,
        )
        assertEquals(
            "int64 enqueued_at_unix_millis max",
            Long.MAX_VALUE,
            Message.ADAPTER.decode(payloadOf(byName("int64_boundary_pooled_message_max"))).message?.enqueued_at_unix_millis,
        )
    }

    @Test
    fun `every negative case is rejected with a typed error`() {
        for (case in negativeCases) {
            if (case.string("expect") == "accepted") continue
            val thrown = runCatching {
                FrameCodec.readFrame(hexToBytes(case.string("frame_hex")), directionOf(case))
            }.exceptionOrNull()
            assertNotNull("${case.string("name")} must not decode", thrown)
            assertTrue(
                "${case.string("name")}: expected a typed frame error but got $thrown",
                thrown is MalformedFrameException || thrown is UnknownFrameTagException,
            )
        }
    }

    @Test
    fun `handles every negative case the way the relay does`() {
        // `expect` is the relay's Close.detail, so this pins each vector to the
        // check that has to reject it - not merely to "something threw", which a
        // decoder that rejected every frame would also satisfy.
        rejected("body_truncated", FrameErrorReason.TRUNCATED_PAYLOAD)
        rejected("length_over_payload_limit", FrameErrorReason.PAYLOAD_TOO_LARGE)
        rejected("length_tenth_byte_overflow", FrameErrorReason.LENGTH_VARINT)
        rejected("length_truncated_varint", FrameErrorReason.LENGTH_VARINT)
        rejected("length_uint32_overflow", FrameErrorReason.PAYLOAD_TOO_LARGE)
        rejected("length_uint64_max", FrameErrorReason.PAYLOAD_TOO_LARGE)
        for (name in listOf("unknown_tag_0", "unknown_tag_8", "unknown_tag_200", "unknown_tag_255")) {
            unknownTag(negativeCase(name))
        }
        for (name in listOf(
            "wrong_direction_serverframe.close",
            "wrong_direction_serverframe.ping",
            "wrong_direction_serverframe.pong",
        )) {
            unknownTag(negativeCase(name))
        }

        // The relay's documented leniency: a zero-padded ten-byte prefix for a
        // zero length. Protobuf accepts it, so refusing it would reject frames
        // the relay considers valid.
        val padded = negativeCase("length_zero_padded_accepted")
        assertEquals("accepted", padded.string("expect"))
        val decoded = FrameCodec.readFrame(hexToBytes(padded.string("frame_hex")), FrameDirection.CLIENT)
        assertEquals(0, decoded.payload.size)
        assertEquals("ClientFrame.poll is tag 2, not ServerFrame.hello_ack", "poll", decoded.payloadType)
    }

    @Test
    fun `reports the length it was given, not the value it narrowed to`() {
        // The regression the whole length-varint rule exists for: `80 80 80 80
        // 10` is 4294967296, and a reader that narrows to an Int first sees 0
        // and hands back an empty payload - which the client then reports as an
        // empty HelloAck and connects on.
        val error = malformed(negativeCase("length_uint32_overflow"))
        assertEquals(FrameErrorReason.PAYLOAD_TOO_LARGE, error.reason)
        assertEquals(4294967296L, error.declaredLength)
        assertTrue(
            "message quotes what the peer sent: ${error.message}",
            error.message.orEmpty().contains("4294967296"),
        )

        // 2^64-1 does not fit in a signed Long, so there is no exact length to
        // report - but the message still names it.
        val max = malformed(negativeCase("length_uint64_max"))
        assertEquals(FrameErrorReason.PAYLOAD_TOO_LARGE, max.reason)
        assertNull("nothing exactly representable was declared", max.declaredLength)
        assertTrue(
            "message quotes the unsigned value: ${max.message}",
            max.message.orEmpty().contains("18446744073709551615"),
        )
    }

    private fun negativeCase(name: String): Map<String, Any?> =
        negativeCases.single { it.string("name") == name }

    private fun rejected(name: String, reason: FrameErrorReason) {
        val case = negativeCase(name)
        val error = malformed(case)
        assertEquals("$name: ${case.string("description")}", reason, error.reason)
        assertEquals("$name: direction", directionOf(case), error.direction)
    }

    private fun malformed(case: Map<String, Any?>): MalformedFrameException {
        val thrown = runCatching {
            FrameCodec.readFrame(hexToBytes(case.string("frame_hex")), directionOf(case))
        }.exceptionOrNull()
        assertTrue("${case.string("name")} must be a malformed envelope, got $thrown", thrown is MalformedFrameException)
        return thrown as MalformedFrameException
    }

    private fun unknownTag(case: Map<String, Any?>) {
        val thrown = runCatching {
            FrameCodec.readFrame(hexToBytes(case.string("frame_hex")), directionOf(case))
        }.exceptionOrNull()
        assertTrue("${case.string("name")} must be rejected, got $thrown", thrown is UnknownFrameTagException)
        thrown as UnknownFrameTagException
        assertEquals("${case.string("name")}: tag", case.int("tag"), thrown.tag)
        assertEquals("${case.string("name")}: direction", directionOf(case), thrown.direction)
    }
}

/** Locates the relay's golden-vector fixture. */
internal object RelayGoldenVectors {

    private const val FILE_NAME = "testdata/wire/ws_frames.v1beta1.golden.json"

    private const val RELATIVE_PATH = "../../sinch-push-relay/$FILE_NAME"

    /** Where the pinned copy lands, relative to the repository root. */
    private const val PINNED_RELATIVE_PATH = "proto-testdata/wire/ws_frames.v1beta1.golden.json"

    fun locate(): File? = candidates().firstOrNull { it.isFile }

    fun searchDescription(): String = candidates().joinToString(", ")

    private fun candidates(): List<File> {
        // Unit tests run with android/ as the working directory; the parent is
        // tried too in case the task is run from the repository root.
        val workingDir = File("").absoluteFile
        val bases = listOfNotNull(workingDir, workingDir.parentFile)
        val explicit = System.getProperty("relay.dir") ?: System.getenv("RELAY_DIR")
        if (explicit != null) {
            return listOf(File(explicit), File(explicit, FILE_NAME)) + bases.map { File(it, explicit) }
        }
        // The pinned copy first: a sibling checkout on another branch would
        // otherwise decide what this suite tests. It is found by walking up to
        // proto-sources.json, the manifest that names the pin and the path, so
        // the lookup does not depend on where Gradle was started from.
        val pinned = repositoryRoot()?.let { File(it, PINNED_RELATIVE_PATH) }
        return listOfNotNull(pinned) + bases.map { File(it, RELATIVE_PATH) }
    }

    /** The repository root, marked by its own pin manifest. */
    private fun repositoryRoot(): File? {
        var dir: File? = File("").absoluteFile
        while (dir != null) {
            if (File(dir, "proto-sources.json").isFile) return dir
            dir = dir.parentFile
        }
        return null
    }
}