package com.sinchpush.socket

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The provider-push report outbox: keyed, bounded and persisted. */
class ReportOutboxTest {

    private val clock = FakeClock()

    private fun outbox(
        store: SocketStateStore = InMemorySocketStateStore(),
        capacity: Int = ReportOutbox.CAPACITY,
    ) = ReportOutbox(store, clock, capacity)

    @Test
    fun `SB67_anEntryIsQueuedWithItsSubscriberAndItsStamp`() {
        val outbox = outbox()

        val entry = requireNotNull(outbox.enqueue("m1", "s-1"))

        assertEquals("m1", entry.messageId)
        assertEquals("s-1", entry.subscriberId)
        assertEquals(clock.now, entry.enqueuedAtMs)
        assertEquals(listOf(entry), outbox.snapshot())
    }

    @Test
    fun `SB67_theSameKeyIsQueuedOnlyOnceAndKeepsItsOriginalStamp`() {
        val outbox = outbox()
        outbox.enqueue("m1", "s-1")
        clock.now += 5_000

        assertNull("a re-enqueue is a no-op", outbox.enqueue("m1", "s-1"))

        assertEquals(1, outbox.snapshot().size)
        assertEquals(clock.now - 5_000, outbox.snapshot().single().enqueuedAtMs)
    }

    @Test
    fun `SB67_anotherSubscriberIsASeparateEntry`() {
        val outbox = outbox()

        outbox.enqueue("m1", "s-1")
        outbox.enqueue("m1", "s-2")

        assertEquals(listOf("m1", "m1"), outbox.snapshot().map { it.messageId })
        assertEquals(listOf("s-1", "s-2"), outbox.snapshot().map { it.subscriberId })
    }

    @Test
    fun `SB67_anEntryWithoutAMessageIdOrASubscriberIsNotQueued`() {
        val outbox = outbox()

        assertNull(outbox.enqueue("", "s-1"))
        assertNull(outbox.enqueue("m1", ""))

        assertTrue(outbox.snapshot().isEmpty())
    }

    @Test
    fun `SB67_theOldestEntryIsDroppedWhenTheOutboxIsFull`() {
        val outbox = outbox()
        for (index in 1..ReportOutbox.CAPACITY) outbox.enqueue("m$index", "s-1")

        outbox.enqueue("m${ReportOutbox.CAPACITY + 1}", "s-1")

        assertEquals(ReportOutbox.CAPACITY, outbox.snapshot().size)
        assertEquals("m2", outbox.snapshot().first().messageId)
        assertEquals("m${ReportOutbox.CAPACITY + 1}", outbox.snapshot().last().messageId)
    }

    @Test
    fun `SB67_theQueueSurvivesARestart`() {
        val store = InMemorySocketStateStore()
        val entry = requireNotNull(outbox(store).enqueue("m1", "s-1"))

        val afterRestart = ReportOutbox(store, clock)

        assertEquals(listOf(entry), afterRestart.snapshot())
    }

    @Test
    fun `SB67_removeDropsOnlyTheNamedEntries`() {
        val outbox = outbox()
        outbox.enqueue("m1", "s-1")
        outbox.enqueue("m2", "s-1")
        outbox.enqueue("m2", "s-2")

        outbox.remove(listOf("m1" to "s-1", "m2" to "s-2"))

        assertEquals(listOf("m2"), outbox.snapshot().map { it.messageId })
        assertEquals(listOf("s-1"), outbox.snapshot().map { it.subscriberId })
    }

    @Test
    fun `SB67_clearDropsEveryEntry`() {
        val outbox = outbox()
        outbox.enqueue("m1", "s-1")
        outbox.enqueue("m2", "s-1")

        outbox.clear()

        assertTrue(outbox.snapshot().isEmpty())
    }

    @Test
    fun `SB67_theEntriesRoundTripThroughThePreferencesStore`() {
        val prefs = FakeSharedPreferences()
        val store = SharedPreferencesSocketStateStore(FakePrefsContext(prefs))

        ReportOutbox(store, clock).enqueue("m-1", "s-1")
        ReportOutbox(store, clock).enqueue("m-2", "s-2")

        val reloaded = ReportOutbox(SharedPreferencesSocketStateStore(FakePrefsContext(prefs)), clock)

        assertEquals(
            listOf(
                ReportOutboxEntry("m-1", "s-1", clock.now),
                ReportOutboxEntry("m-2", "s-2", clock.now),
            ),
            reloaded.snapshot(),
        )
        assertEquals(
            "m-1\u001Fs-1\u001F${clock.now}\u001Em-2\u001Fs-2\u001F${clock.now}",
            prefs.getString("report_outbox", null),
        )
    }

    @Test
    fun `SB67_aRecordThatCannotBeReadIsDropped`() {
        val prefs = FakeSharedPreferences()
        prefs.edit().putString("report_outbox", "m-1\u001Fs-1\u001F17\u001Em-2\u001Fs-2").commit()

        val store = SharedPreferencesSocketStateStore(FakePrefsContext(prefs))

        assertEquals(listOf(ReportOutboxEntry("m-1", "s-1", 17L)), store.loadReportOutbox())
    }
}
