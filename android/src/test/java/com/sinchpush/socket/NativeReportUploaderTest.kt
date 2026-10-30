package com.sinchpush.socket

import android.content.SharedPreferences
import java.net.URL
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** SB-67: the native `ReportEvents` upload - its bytes, its outcomes and what it does to the outbox. */
class NativeReportUploaderTest {

    private val clock = FakeClock()
    private val store = InMemorySocketStateStore()
    private val outbox = ReportOutbox(store, clock)
    private val sessions = InMemoryReportSessionStore(
        SharedReportSession("token-1", "https://push.example.com/", "u-1", "a-1"),
    )
    private val http = FakeHttp()

    private fun uploader(budgetMs: Long = 8_000) =
        NativeReportUploader(outbox, sessions, http, clock, budgetMs)

    private companion object {
        const val GRPC_WEB = "application/grpc-web+proto"
    }

    private fun keys(vararg pairs: Pair<String, String>) = pairs.toList()

    private fun queue(vararg ids: String) = ids.forEach { outbox.enqueue(it, "s-1") }

    private class FakeHttp : ReportHttp {
        class Call(val url: URL, val headers: Map<String, String>, val body: ByteArray, val timeoutMs: Int)

        val calls = mutableListOf<Call>()
        var respond: (Call) -> ReportHttpResponse? = { ReportHttpResponse(200, GRPC_WEB, "0", ByteArray(0)) }
        var onCall: (Call) -> Unit = {}

        override fun post(url: URL, headers: Map<String, String>, body: ByteArray, timeoutMs: Int): ReportHttpResponse? {
            val call = Call(url, headers, body, timeoutMs)
            calls.add(call)
            onCall(call)
            return respond(call)
        }
    }

    // --- the bytes ------------------------------------------------------------

    /** `ReportEventsRequest{ events: [{ message_id: "m1", subscriber_id: "s-1", event_type: DELIVERED }] }`, gRPC-web framed. */
    @Test
    fun `SB67_theRequestIsAGrpcWebFrameOfDeliveredEvents`() {
        val expected = byteArrayOf(
            0x00, 0x00, 0x00, 0x00, 0x0E, // data frame, 14 bytes of protobuf
            0x0A, 0x0C, // events[0], 12 bytes
            0x0A, 0x02, 'm'.code.toByte(), '1'.code.toByte(), // message_id
            0x12, 0x03, 's'.code.toByte(), '-'.code.toByte(), '1'.code.toByte(), // subscriber_id
            0x20, 0xAC.toByte(), 0x02, // event_type = 300 (DELIVERED)
        )

        assertArrayEquals(expected, ReportWire.requestBody(keys("m1" to "s-1")))
    }

    @Test
    fun `SB67_everyEventIsItsOwnRepeatedField`() {
        val body = ReportWire.requestBody(keys("m1" to "s-1", "m2" to "s-2"))

        assertEquals(5 + 2 * 14, body.size)
        assertEquals((2 * 14).toByte(), body[4])
        assertEquals(0x0A.toByte(), body[5])
        assertEquals(0x0A.toByte(), body[5 + 14])
    }

    @Test
    fun `SB67_aLongIdUsesAMultiByteLength`() {
        val id = "x".repeat(200)

        val body = ReportWire.requestBody(keys(id to "s"))

        // events[0] = tag + varint(len) ... ; the 200-byte id needs a 2-byte varint (0xC8 0x01).
        assertEquals(0x0A.toByte(), body[5])
        val eventLength = (body[6].toInt() and 0x7F) or ((body[7].toInt() and 0x7F) shl 7)
        assertEquals(1 + 2 + 200 + 1 + 1 + 1 + 3, eventLength)
        assertEquals(0xC8.toByte(), body[9])
        assertEquals(0x01.toByte(), body[10])
    }

    @Test
    fun `SB67_theEndpointIsTheServicePathUnderTheBaseUrl`() {
        assertEquals(
            "https://grpc.example.com/sinch.push.sdk.v1beta1.SdkService/ReportEvents",
            ReportWire.endpoint(" https://grpc.example.com// ")?.toString(),
        )
        assertNull(ReportWire.endpoint("ftp://grpc.example.com"))
        assertNull(ReportWire.endpoint("not a url"))
        assertNull(ReportWire.endpoint(""))
    }

    @Test
    fun `SB67_theAuthorizationHeaderIsTheRawJwt`() {
        val headers = ReportWire.headers("abc.def.ghi")

        assertEquals("abc.def.ghi", headers["authorization"])
        assertEquals("application/grpc-web+proto", headers["content-type"])
        assertEquals("1", headers["x-grpc-web"])
    }

    // --- outcomes -------------------------------------------------------------

    @Test
    fun `SB67_aGrpcWebResponseIsDecidedByItsGrpcStatus`() {
        fun outcome(header: String?, body: ByteArray? = null, contentType: String? = GRPC_WEB) =
            ReportWire.outcome(200, contentType, header, body)

        assertEquals(ReportOutcome.SENT, outcome("0"))
        assertEquals(ReportOutcome.SENT, outcome("0", contentType = "application/grpc-web"))
        assertEquals(ReportOutcome.SENT, outcome("0", contentType = "Application/GRPC-Web-Text; charset=utf-8"))
        assertEquals(ReportOutcome.UNAUTHENTICATED, outcome("16"))
        assertEquals(ReportOutcome.DROPPED, outcome("3"))
        assertEquals(ReportOutcome.DROPPED, outcome("5"))
        assertEquals(ReportOutcome.DROPPED, outcome("7"))
        assertEquals(ReportOutcome.RETRY, outcome("14"))
        assertEquals("a gRPC 2xx with no status is the empty success", ReportOutcome.SENT, outcome(null))
        assertEquals(ReportOutcome.SENT, outcome(null, ByteArray(0)))
    }

    /** A native gRPC server answers a gRPC-web request as plain gRPC; its status is in HTTP/2 trailers. */
    @Test
    fun `SB67_aPlainGrpcResponseIsDecidedByItsStatusOrCountsAsSentWithoutOne`() {
        fun outcome(contentType: String?, status: String?) = ReportWire.outcome(200, contentType, status, ByteArray(0))

        assertEquals(ReportOutcome.SENT, outcome("application/grpc+proto", null))
        assertEquals(ReportOutcome.SENT, outcome("application/grpc", null))
        assertEquals(ReportOutcome.SENT, outcome("Application/GRPC+Proto; charset=x", "0"))
        assertEquals(ReportOutcome.UNAUTHENTICATED, outcome("application/grpc", "16"))
        assertEquals(ReportOutcome.UNAUTHENTICATED, outcome("application/grpc+proto", "16"))
        assertEquals(ReportOutcome.DROPPED, outcome("application/grpc", "7"))
        assertEquals(ReportOutcome.RETRY, outcome("application/grpc", "14"))
        assertEquals("a non-2xx is still decided by HTTP alone", ReportOutcome.RETRY, ReportWire.outcome(503, "application/grpc", "0", null))
        assertEquals(ReportOutcome.UNAUTHENTICATED, ReportWire.outcome(401, "application/grpc", null, null))
    }

    @Test
    fun `SB67_theTrailerFrameWinsOverTheHeaderStatus`() {
        val trailer = "grpc-status: 16\r\n".toByteArray()
        val body = byteArrayOf(0x80.toByte(), 0, 0, 0, trailer.size.toByte()) + trailer

        assertEquals(16, ReportWire.grpcStatus("0", body))
        assertEquals(0, ReportWire.grpcStatus("0", ByteArray(0)))
    }

    /** A captive portal's `200 text/html` must never delete a report. */
    @Test
    fun `SB67_aTwoHundredThatIsNotGrpcIsRetried`() {
        assertEquals(ReportOutcome.RETRY, ReportWire.outcome(200, "text/html; charset=utf-8", null, "<html/>".toByteArray()))
        assertEquals(ReportOutcome.RETRY, ReportWire.outcome(200, null, null, ByteArray(0)))
        assertEquals(ReportOutcome.RETRY, ReportWire.outcome(204, "application/json", "0", null))
        assertEquals(ReportOutcome.RETRY, ReportWire.outcome(200, "text/html", "0", null))
        assertEquals(ReportOutcome.RETRY, ReportWire.outcome(200, "application/grp", "0", null))
        assertEquals(ReportOutcome.RETRY, ReportWire.outcome(200, "application/grpcfoo", "0", null))
        assertEquals(ReportOutcome.RETRY, ReportWire.outcome(200, "application/grpc-other", "0", null))
    }

    @Test
    fun `SB67_everyGrpcContentTypeIsAccepted`() {
        for (type in listOf("application/grpc", "application/grpc+proto", "Application/GRPC-Web+proto", " application/grpc; charset=utf-8")) {
            assertEquals(type, ReportOutcome.SENT, ReportWire.outcome(200, type, "0", null))
        }
    }

    @Test
    fun `SB67_aGrpcStatusThatIsNotANumberIsRetriedNotTakenAsMissing`() {
        assertEquals(ReportOutcome.RETRY, ReportWire.outcome(200, "application/grpc", "abc", null))
        val trailer = "grpc-status: abc\r\n".toByteArray()
        val frame = byteArrayOf(0x80.toByte(), 0, 0, 0, trailer.size.toByte()) + trailer
        assertEquals("a trailer frame's status counts the same", ReportOutcome.RETRY, ReportWire.outcome(200, GRPC_WEB, null, frame))
        assertEquals(ReportOutcome.SENT, ReportWire.outcome(200, "application/grpc", null, null))
    }

    /** The mapping of connect-es' `codeFromHttpStatus`, as the JS flusher sees it. */
    @Test
    fun `SB67_aNon2xxIsDecidedByItsHttpStatusLikeTheJsFlusher`() {
        fun outcome(http: Int, header: String? = null) = ReportWire.outcome(http, GRPC_WEB, header, null)

        assertEquals(ReportOutcome.UNAUTHENTICATED, outcome(401))
        assertEquals(ReportOutcome.DROPPED, outcome(403))
        assertEquals("400 is Internal in connect-es: retried", ReportOutcome.RETRY, outcome(400))
        assertEquals("404 is Unimplemented in connect-es: retried", ReportOutcome.RETRY, outcome(404))
        assertEquals(ReportOutcome.RETRY, outcome(408))
        assertEquals(ReportOutcome.RETRY, outcome(429))
        assertEquals(ReportOutcome.RETRY, outcome(500))
        assertEquals(ReportOutcome.RETRY, outcome(502))
        assertEquals(ReportOutcome.RETRY, outcome(503))
        assertEquals(ReportOutcome.RETRY, outcome(504))
        assertEquals("a grpc-status does not rescue a failing HTTP status", ReportOutcome.RETRY, outcome(503, "0"))
        assertEquals(ReportOutcome.RETRY, outcome(301))
    }

    @Test
    fun `SB67_theStatusIsReadFromTheTrailerFrameWhenThereIsNoHeader`() {
        val trailer = "grpc-status: 16\r\ngrpc-message: bad token\r\n".toByteArray()
        val body = byteArrayOf(0x80.toByte(), 0, 0, 0, trailer.size.toByte()) + trailer

        assertEquals(16, ReportWire.grpcStatus(null, body))
        assertEquals(ReportOutcome.UNAUTHENTICATED, ReportWire.outcome(200, GRPC_WEB, null, body))
        val ok = "grpc-status: 0\r\n".toByteArray()
        val okBody = byteArrayOf(0, 0, 0, 0, 0) + byteArrayOf(0x80.toByte(), 0, 0, 0, ok.size.toByte()) + ok
        assertEquals(ReportOutcome.SENT, ReportWire.outcome(200, GRPC_WEB, null, okBody))
        assertNull(ReportWire.grpcStatus(null, ByteArray(0)))
        assertNull("a truncated frame says nothing", ReportWire.grpcStatus(null, byteArrayOf(0x80.toByte(), 0, 0, 1, 0)))
    }

    @Test
    fun `SB67_aRetriedResponseKeepsTheReportsForTheFlusher`() {
        queue("m1")
        http.respond = { ReportHttpResponse(200, "text/html", null, "<html/>".toByteArray()) }

        val result = uploader().flush()

        assertEquals(0, result.removed)
        assertEquals(listOf("m1"), outbox.snapshot().map { it.messageId })
        assertEquals("released, not left leased to native", 1, outbox.claim(ReportFlusher.JS, 60_000).size)
    }

    // --- draining -------------------------------------------------------------

    @Test
    fun `SB67_anAcknowledgedBatchIsRemovedFromTheOutbox`() {
        queue("m1", "m2")

        val result = uploader().flush()

        assertEquals(1, http.calls.size)
        assertEquals("https://push.example.com/sinch.push.sdk.v1beta1.SdkService/ReportEvents", http.calls[0].url.toString())
        assertEquals("token-1", http.calls[0].headers["authorization"])
        assertArrayEquals(ReportWire.requestBody(keys("m1" to "s-1", "m2" to "s-1")), http.calls[0].body)
        assertEquals(NativeReportUploader.Result(removed = 2, remaining = 0), result)
        assertTrue(outbox.snapshot().isEmpty())
        assertTrue("the removal reached the store", store.loadReportOutbox().isEmpty())
    }

    @Test
    fun `SB67_theOutboxIsSentInBatchesOfAHundred`() {
        (1..230).forEach { outbox.enqueue("m$it", "s-1") }

        val result = uploader().flush()

        assertEquals(listOf(100, 100, 30), http.calls.map { countEvents(it.body) })
        assertEquals(230, result.removed)
        assertTrue(outbox.snapshot().isEmpty())
    }

    private fun countEvents(body: ByteArray): Int {
        var offset = 5
        var events = 0
        while (offset < body.size) {
            assertEquals(0x0A.toByte(), body[offset])
            var length = 0
            var shift = 0
            var i = offset + 1
            while (true) {
                val b = body[i++].toInt()
                length = length or ((b and 0x7F) shl shift)
                shift += 7
                if (b and 0x80 == 0) break
            }
            offset = i + length
            events++
        }
        return events
    }

    @Test
    fun `SB67_withoutASessionNothingIsSentAndNothingIsLost`() {
        sessions.clear()
        queue("m1")

        val result = uploader().flush()

        assertTrue(http.calls.isEmpty())
        assertEquals(1, result.remaining)
        assertEquals(1, outbox.snapshot().size)
    }

    @Test
    fun `SB67_anExpiredTokenIsNotSent`() {
        // exp = 1 (1970): payload {"exp":1}
        sessions.save(SharedReportSession("e30.eyJleHAiOjF9.sig", "https://push.example.com"))
        queue("m1")

        uploader().flush()

        assertTrue(http.calls.isEmpty())
        assertEquals(1, outbox.snapshot().size)
    }

    @Test
    fun `SB67_unauthenticatedKeepsTheEntriesForTheFlusherAndStops`() {
        queue("m1")
        http.respond = { ReportHttpResponse(401, null, null, ByteArray(0)) }

        val result = uploader().flush()

        assertEquals(NativeReportUploader.Result(removed = 0, remaining = 1), result)
        assertEquals(listOf("m1"), outbox.snapshot().map { it.messageId })
    }

    @Test
    fun `SB67_aNetworkFailureKeepsTheEntriesAndReleasesThemForTheOtherFlusher`() {
        queue("m1")
        http.respond = { null }

        uploader().flush()

        assertEquals(listOf("m1"), outbox.snapshot().map { it.messageId })
        assertEquals(
            "the lease is released so JS can take the entry at once",
            listOf("m1"),
            outbox.claim(ReportFlusher.JS, 1_000).map { it.messageId },
        )
    }

    @Test
    fun `SB67_anEntryTheServerWillNeverAcceptIsDropped`() {
        queue("m1")
        http.respond = { ReportHttpResponse(200, GRPC_WEB, "3", ByteArray(0)) }

        val result = uploader().flush()

        assertEquals(1, result.removed)
        assertTrue(outbox.snapshot().isEmpty())
    }

    @Test
    fun `SB67_anEntryOlderThanSeventyTwoHoursIsDroppedUnsent`() {
        queue("old")
        clock.now += NativeReportUploader.TTL_MS + 1
        queue("fresh")

        uploader().flush()

        assertEquals(1, http.calls.size)
        assertEquals(1, countEvents(http.calls[0].body))
        assertTrue(outbox.snapshot().isEmpty())
    }

    @Test
    fun `SB67_theWholeAttemptIsBoundedByTheBudget`() {
        (1..250).forEach { outbox.enqueue("m$it", "s-1") }
        http.onCall = { clock.now += 5_000 } // every request eats the budget

        val result = uploader(budgetMs = 8_000).flush()

        assertEquals("the second request still fits, the third does not start", 2, http.calls.size)
        assertEquals(200, result.removed)
        assertEquals(50, outbox.snapshot().size)
        assertTrue("the request timeout is what is left of the budget", http.calls[1].timeoutMs <= 3_000)
    }

    // --- the two flushers -----------------------------------------------------

    @Test
    fun `SB67_anEntryJsHoldsIsNotSentNatively`() {
        queue("m1", "m2")
        val jsHas = outbox.claim(ReportFlusher.JS, 60_000, max = 1)
        assertEquals(listOf("m1"), jsHas.map { it.messageId })

        val result = uploader().flush()

        assertEquals(1, countEvents(http.calls.single().body))
        assertEquals(1, result.removed)
        assertEquals("JS's entry is untouched", listOf("m1"), outbox.snapshot().map { it.messageId })
    }

    @Test
    fun `SB67_anEntryTheNativeUploaderIsSendingIsNotHandedToJs`() {
        queue("m1")
        var seenByJs: List<String>? = null
        http.onCall = { seenByJs = outbox.claim(ReportFlusher.JS, 60_000).map { it.messageId } }

        uploader().flush()

        assertEquals("JS saw nothing while native had it on the wire", emptyList<String>(), seenByJs)
        assertTrue(outbox.snapshot().isEmpty())
    }

    @Test
    fun `SB67_aLeaseThatLapsedHandsTheEntryOver`() {
        queue("m1")
        outbox.claim(ReportFlusher.JS, 1_000)
        clock.now += 1_001

        uploader().flush()

        assertEquals(1, http.calls.size)
        assertTrue(outbox.snapshot().isEmpty())
    }

    @Test
    fun `SB67_theJsFlusherRemovingWhatNativeAlreadyRemovedLosesNothing`() {
        queue("m1", "m2")
        uploader().flush()
        outbox.enqueue("m3", "s-1")

        outbox.remove(keys("m1" to "s-1", "m2" to "s-1"))

        assertEquals(listOf("m3"), outbox.snapshot().map { it.messageId })
    }

    // --- the outbox, FCM side -------------------------------------------------

    @Test
    fun `SB67_aKeyReportedEarlierInTheProcessIsNotQueuedAgain`() {
        assertTrue(outbox.enqueue("m1", "s-1") != null)
        outbox.remove(keys("m1" to "s-1"))

        assertNull("handleIntent then onMessageReceived must not report twice", outbox.enqueue("m1", "s-1"))
        assertTrue(outbox.snapshot().isEmpty())
    }

    @Test
    fun `SB67_theFcmThreadsQueuedReportIsCommittedNotApplied`() {
        val prefs = CountingPrefs()
        val outbox = ReportOutbox(SharedPreferencesSocketStateStore(FakePrefsContext(prefs)), clock)

        outbox.enqueue("m1", "s-1")

        assertEquals(1, prefs.commits)
        assertEquals(0, prefs.applies)
    }

    // --- the session ----------------------------------------------------------

    @Test
    fun `SB67_theJwtExpiryIsReadFromThePayload`() {
        // {"exp":1700000000} base64url
        val payload = "eyJleHAiOjE3MDAwMDAwMDB9"
        assertEquals(1_700_000_000_000L, JwtExpiry.expiresAtMs("e30.$payload.sig"))
        assertNull(JwtExpiry.expiresAtMs("not-a-jwt"))
        assertNull(JwtExpiry.expiresAtMs("e30.e30.sig"))
    }

    /** [FakeSharedPreferences] that counts how its edits were written. */
    private class CountingPrefs(
        private val inner: SharedPreferences = FakeSharedPreferences(),
    ) : SharedPreferences by inner {
        var commits = 0
        var applies = 0

        override fun edit(): SharedPreferences.Editor {
            val editor = inner.edit()
            return object : SharedPreferences.Editor by editor {
                override fun commit(): Boolean {
                    commits++
                    return editor.commit()
                }

                override fun apply() {
                    applies++
                    editor.apply()
                }

                // Delegation returns the inner editor from the fluent calls; keep the wrapper.
                override fun putString(key: String?, value: String?) = apply { editor.putString(key, value) }
                override fun clear() = apply { editor.clear() }
            }
        }
    }
}
