package com.sinchpush.socket

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** SB-28, SB-30, SB-35 persistence mechanics, and the "no token in the state store" constraint. */
class StateStoreRulesTest {

    @Before
    fun resetPresentationBuffer() = SinchPushSocketStore.clear()

    @Test
    fun `SB35_outboxCodecRoundTripsEveryField`() {
        val entries = listOf(
            PendingReport("a:1", "s1", ReportStatus.DISMISSED, "", 5L, attempts = 2, notBeforeMs = 99L, deferredByRateLimit = true),
            PendingReport("b", "", ReportStatus.FAILED, "decode: bad\ttab", 7L),
        )
        assertEquals(entries, OutboxCodec.decode(OutboxCodec.encode(entries)))
    }

    @Test
    fun `SB35_aCorruptedOutboxRecordIsDroppedNotThrown`() {
        val good = PendingReport("ok", "", ReportStatus.DISPLAYED, "", 1L)
        val text = "garbage\u001E" + OutboxCodec.encode(listOf(good)) + "\u001E\u001F\u001F"
        assertEquals(listOf(good), OutboxCodec.decode(text))
        assertTrue(OutboxCodec.decode("").isEmpty())
    }

    @Test
    fun `SB28_boundedLruKeepsInsertionOrderAndEvictsTheOldest`() {
        val lru = BoundedLru<String, Boolean>(3)
        assertTrue(lru.put("a", true)); lru.put("b", true); lru.put("c", true)
        assertFalse("re-insert is not new", lru.put("a", true))
        lru.put("d", true)
        assertEquals(listOf("b", "c", "d"), lru.keys())
    }

    @Test
    fun `SB30_theSentSetIsBoundedToo`() {
        val store = InMemorySocketStateStore()
        val tracker = ReportTracker(store, FakeClock(), RecordingLogger())
        val sink = object : ReportTransport { override fun send(report: PendingReport) = true }
        for (i in 1..(SocketSpec.SENT_SET_CAPACITY + 10)) tracker.report("m$i", "", ReportStatus.DELIVERED, "", sink)
        assertEquals(SocketSpec.SENT_SET_CAPACITY, store.loadSentKeys().size)
    }

    @Test
    fun `SB55_noTokenIsEverWrittenToTheSocketStateStore`() {
        val store = InMemorySocketStateStore()
        val h = Harness(testConfig(displayNotifications = false), store = store)
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))
        h.client.reportStatus("m1", ReportStatus.DISMISSED)
        h.conn.serverSends(closeFrame(sinch.push.delivery.v1beta1.ws.CloseReason.POOL_FULL, "rate_limited"))
        h.client.reportStatus("m1", ReportStatus.DISPLAYED)
        val everything = store.loadSeen() + store.loadSentKeys() + store.loadLastSeenMessageId() +
            OutboxCodec.encode(store.loadOutbox()) + store.loadSinchMessageIds().flatMap { listOf(it.key, it.value) }
        assertTrue(everything.isNotEmpty())
        assertTrue(everything.none { it.contains(h.config.authToken) })
    }
}
