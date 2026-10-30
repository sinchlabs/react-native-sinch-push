package com.sinchpush

import com.sinchpush.socket.FakeClock
import com.sinchpush.socket.Harness
import com.sinchpush.socket.InMemorySocketStateStore
import com.sinchpush.socket.ReportOutbox
import com.sinchpush.socket.ReportOutboxEntry
import com.sinchpush.socket.SeenSet
import com.sinchpush.socket.pushMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The delivery report a provider push queues for the host. */
class ProviderPushReportTest {

    private val messageId = PushDedupe.MESSAGE_ID_KEY
    private val subscriberId = PushDedupe.SUBSCRIBER_ID_KEY

    /** The FCM service, without Firebase: what it decides and what it queues. */
    private class Fcm(seen: SeenSet, outbox: ReportOutbox) {
        val emitted = mutableListOf<Map<String, String>>()
        val queued = mutableListOf<ReportOutboxEntry>()
        val handler = PushMessageHandler(
            dedupe = PushDedupe(seen, outbox) { queued.add(it) },
            emit = { data, _, _ -> emitted.add(data) },
            show = { _, _, _, _, _ -> },
        )

        fun receive(data: Map<String, String>) = handler.handle("fcm-1", data, "T", "B")
    }

    private val clock = FakeClock()

    /**
     * A `notification` + `data` message in the foreground reaches `handleIntent`
     * (which queues the report) and then `onMessageReceived` (which renders it):
     * the message must still be emitted and shown, and reported once.
     */
    @Test
    fun `SB67_aMessageHandleIntentAlreadyQueuedIsStillDeliveredButNotQueuedTwice`() {
        val seen = SeenSet(InMemorySocketStateStore())
        val outbox = ReportOutbox(InMemorySocketStateStore(), clock)
        val fcm = Fcm(seen, outbox)
        outbox.enqueue("m1", "s-1")

        fcm.receive(mapOf(messageId to "m1", subscriberId to "s-1"))

        assertEquals("no second report", 1, outbox.snapshot().size)
        assertTrue("nobody is told of a second report", fcm.queued.isEmpty())
        assertEquals("the push is still delivered to JS", 1, fcm.emitted.size)
    }

    @Test
    fun `SB67_anUnseenProviderPushIsQueuedForTheHost`() {
        val seen = SeenSet(InMemorySocketStateStore())
        val outbox = ReportOutbox(InMemorySocketStateStore(), clock)
        val fcm = Fcm(seen, outbox)

        fcm.receive(mapOf(messageId to "m1", subscriberId to "s-1"))

        assertEquals(listOf(ReportOutboxEntry("m1", "s-1", clock.now)), outbox.snapshot())
        assertEquals("the host is told once", 1, fcm.queued.size)
        assertEquals("m1", fcm.queued.single().messageId)
        assertEquals("s-1", fcm.queued.single().subscriberId)
        assertEquals("the push is still delivered", 1, fcm.emitted.size)
    }

    @Test
    fun `SB67_aPushTheRelayDeliveredFirstIsNotQueued`() {
        val store = InMemorySocketStateStore()
        val seen = SeenSet(store)
        val outbox = ReportOutbox(store, clock)

        val harness = Harness(store = store, seen = seen)
        harness.startAndConnect()
        harness.conn.serverSends(pushMessage("m1"))

        val fcm = Fcm(seen, outbox)
        fcm.receive(mapOf(messageId to "m1", subscriberId to "s-1"))

        assertTrue("the socket's copy is a dedupe hit", fcm.emitted.isEmpty())
        assertTrue("nothing is queued", outbox.snapshot().isEmpty())
        assertTrue("no callback", fcm.queued.isEmpty())
    }

    @Test
    fun `SB67_aPushWithoutASubscriberIdIsNotQueued`() {
        val seen = SeenSet(InMemorySocketStateStore())
        val outbox = ReportOutbox(InMemorySocketStateStore(), clock)
        val fcm = Fcm(seen, outbox)

        fcm.receive(mapOf(messageId to "m1"))

        assertTrue(outbox.snapshot().isEmpty())
        assertTrue(fcm.queued.isEmpty())
        assertEquals("the push is still delivered", 1, fcm.emitted.size)
    }

    @Test
    fun `SB67_aPushWithAnEmptySubscriberIdIsNotQueued`() {
        val seen = SeenSet(InMemorySocketStateStore())
        val outbox = ReportOutbox(InMemorySocketStateStore(), clock)
        val fcm = Fcm(seen, outbox)

        fcm.receive(mapOf(messageId to "m1", subscriberId to ""))

        assertTrue(outbox.snapshot().isEmpty())
        assertTrue(fcm.queued.isEmpty())
    }

    @Test
    fun `SB67_aPushWithoutAMessageIdIsNotQueued`() {
        val seen = SeenSet(InMemorySocketStateStore())
        val outbox = ReportOutbox(InMemorySocketStateStore(), clock)
        val fcm = Fcm(seen, outbox)

        fcm.receive(mapOf(subscriberId to "s-1"))

        assertTrue(outbox.snapshot().isEmpty())
        assertTrue(fcm.queued.isEmpty())
        assertEquals("the push is still delivered", 1, fcm.emitted.size)
    }

    @Test
    fun `SB67_theCallbackFiresOncePerQueuedEntry`() {
        val seen = SeenSet(InMemorySocketStateStore())
        val outbox = ReportOutbox(InMemorySocketStateStore(), clock)
        val fcm = Fcm(seen, outbox)

        fcm.receive(mapOf(messageId to "m1", subscriberId to "s-1"))
        fcm.receive(mapOf(messageId to "m2", subscriberId to "s-1"))
        fcm.receive(mapOf(messageId to "m1", subscriberId to "s-1"))

        assertEquals("two entries, two callbacks", 2, fcm.queued.size)
        assertEquals(listOf("m1", "m2"), fcm.queued.map { it.messageId })
        assertEquals(listOf("m1", "m2"), outbox.snapshot().map { it.messageId })
    }
}
