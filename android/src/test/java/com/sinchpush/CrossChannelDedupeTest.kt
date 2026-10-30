package com.sinchpush

import com.sinchpush.socket.Harness
import com.sinchpush.socket.InMemorySocketStateStore
import com.sinchpush.socket.ReportStatus
import com.sinchpush.socket.SeenSet
import com.sinchpush.socket.SharedSeenSet
import com.sinchpush.socket.SinchNotificationIdentity
import com.sinchpush.socket.SinchPushSocketNotifications
import com.sinchpush.socket.SinchPushSocketStore
import com.sinchpush.socket.SocketSpec
import com.sinchpush.socket.pooled
import com.sinchpush.socket.pushMessage
import com.sinchpush.socket.testConfig
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * One seen set for the socket and FCM (SB-28, SB-64, SB-65).
 *
 * The FCM service is exercised through [PushMessageHandler], which is all of its
 * logic without Firebase; the socket through the same [Harness] every other
 * conformance test uses, handed the *same* [SeenSet] instance - which is exactly
 * what `androidSocketDependencies` does with [com.sinchpush.socket.SharedSeenSet].
 */
class CrossChannelDedupeTest {

    @Before
    fun resetPresentationBuffer() = SinchPushSocketStore.clear()

    private val key = PushDedupe.MESSAGE_ID_KEY

    /**
     * Every report frame this client actually wrote, as `<message_id>:<status code>`
     * - `m1:1` is the one `DELIVERED` (SB-30's code numbering, not the wire enum's).
     */
    private fun Harness.sentReports(): List<String> =
        conn.reports.map { "${it.message_id}:${ReportStatus.values().first { s -> s.wire == it.status }.code}" }

    /** What the FCM side did, counted. */
    private class Fcm(seen: SeenSet) {
        val emitted = mutableListOf<Map<String, String>>()
        class Shown(val tag: String?, val id: Int)
        val shown = mutableListOf<Shown>()
        val handler = PushMessageHandler(
            dedupe = PushDedupe(seen),
            emit = { data, _, _ -> emitted.add(data) },
            show = { _, _, _, tag, id -> shown.add(Shown(tag, id)) },
        )

        fun receive(messageId: String?, data: Map<String, String>) =
            handler.handle(messageId, data, "T", "B")
    }

    // ------------------------------------------------------------ SB-64

    @Test
    fun `SB64_fcmThenSocketIsOneNotificationOneEventAndOneDelivered`() {
        val seen = SeenSet(InMemorySocketStateStore())
        val fcm = Fcm(seen)
        fcm.receive("fcm-1", mapOf(key to "m1"))

        val h = Harness(seen = seen)
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))

        assertEquals("one JS event from FCM", 1, fcm.emitted.size)
        assertEquals("one notification from FCM", 1, fcm.shown.size)
        // The socket's copy is a dedupe hit: no second presentation, but it is
        // still acked.
        assertTrue(h.messages.isEmpty())
        assertTrue(h.notifications.shown.isEmpty())
        assertEquals(listOf("m1:1"), h.sentReports())
    }

    @Test
    fun `SB29_anIdFcmSawAdvancesTheCursorWhenItArrivesOverTheSocket`() {
        val store = InMemorySocketStateStore()
        val seen = SeenSet(store)
        Fcm(seen).receive("fcm-1", mapOf(key to "m1"))

        val h = Harness(store = store, seen = seen)
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1").copy(message = pooled("m1", enqueuedAt = 5_000)))

        assertEquals("m1", store.loadLastSeenMessageId())
        assertEquals(5_000L, store.loadLastSeenEnqueuedAtMs())
        assertTrue(h.messages.isEmpty())
        assertTrue(h.notifications.shown.isEmpty())
        assertEquals(listOf("m1:1"), h.sentReports())
    }

    @Test
    fun `SB29_aHitOnAnOlderIdDoesNotWalkTheCursorBack`() {
        val store = InMemorySocketStateStore()
        val seen = SeenSet(store)
        val fcm = Fcm(seen)
        fcm.receive("a", mapOf(key to "m1"))
        val h = Harness(store = store, seen = seen)
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m2").copy(message = pooled("m2", enqueuedAt = 9_000)))

        h.conn.serverSends(pushMessage("m1").copy(message = pooled("m1", enqueuedAt = 1_000)))

        assertEquals("m2", store.loadLastSeenMessageId())
    }

    /** Cursor at m2/9_000, then a hit on FCM-seen m1 carrying [hitAt]; returns the stored id. */
    private fun cursorAfterAHit(hitAt: Long): Pair<String?, Long> {
        val store = InMemorySocketStateStore()
        val seen = SeenSet(store)
        Fcm(seen).receive("a", mapOf(key to "m1"))
        val h = Harness(store = store, seen = seen)
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m2").copy(message = pooled("m2", enqueuedAt = 9_000)))
        h.conn.serverSends(pushMessage("m1").copy(message = pooled("m1", enqueuedAt = hitAt)))
        return store.loadLastSeenMessageId() to store.loadLastSeenEnqueuedAtMs()
    }

    @Test
    fun `SB29_aHitWithAnUnknownTimestampDoesNotMoveTheCursor`() {
        assertEquals("m2" to 9_000L, cursorAfterAHit(0))
    }

    @Test
    fun `SB29_aHitWithAnEqualTimestampDoesNotMoveTheCursor`() {
        assertEquals("m2" to 9_000L, cursorAfterAHit(9_000))
    }

    @Test
    fun `SB29_aHitWithAStrictlyNewerTimestampMovesTheCursor`() {
        assertEquals("m1" to 9_001L, cursorAfterAHit(9_001))
    }

    @Test
    fun `SB64_socketThenFcmDropsTheFcmCopyEntirely`() {
        val seen = SeenSet(InMemorySocketStateStore())
        val h = Harness(seen = seen)
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))
        assertEquals(1, h.messages.size)
        assertEquals(1, h.notifications.shown.size)

        val fcm = Fcm(seen)
        fcm.receive("fcm-1", mapOf(key to "m1"))

        assertTrue("no JS event", fcm.emitted.isEmpty())
        assertTrue("no notification", fcm.shown.isEmpty())
    }

    @Test
    fun `SB64_aNewMessageIsMarkedSoARepeatedFcmDeliveryIsDropped`() {
        val seen = SeenSet(InMemorySocketStateStore())
        val fcm = Fcm(seen)

        fcm.receive("a", mapOf(key to "m1"))
        fcm.receive("b", mapOf(key to "m1"))

        assertEquals(1, fcm.emitted.size)
        assertEquals(1, fcm.shown.size)
        assertTrue(seen.contains("m1"))
    }

    @Test
    fun `SB64_aPushWithoutAMessageIdIsNeverDedupedAndKeepsTodaysIdentity`() {
        val seen = SeenSet(InMemorySocketStateStore())
        val fcm = Fcm(seen)

        fcm.receive("fcm-1", mapOf("title" to "x"))
        fcm.receive("fcm-1", mapOf("title" to "x"))
        fcm.receive("fcm-2", mapOf(key to ""))

        assertEquals(3, fcm.emitted.size)
        assertEquals(3, fcm.shown.size)
        assertEquals("FCM's own id is the tag", "fcm-1", fcm.shown[0].tag)
        assertEquals(PushMessageHandler.legacyNotificationIdFor("fcm-1"), fcm.shown[0].id)
        assertEquals(0, seen.size())
    }

    @Test
    fun `SB64_theDecisionIsDropOnlyForASeenId`() {
        val dedupe = PushDedupe(SeenSet(InMemorySocketStateStore()))
        assertEquals(PushDecision.Render("m1"), dedupe.decide(mapOf(key to "m1")))
        assertEquals(PushDecision.Drop, dedupe.decide(mapOf(key to "m1")))
        assertEquals(PushDecision.Render(null), dedupe.decide(emptyMap()))
    }

    // -------------------------------------------- the cross-channel hit

    /**
     * The cross-channel half of the rule: the hit suppresses presentation, never
     * the ack - a hit that stayed silent recorded an `ACK_TIMEOUT`, and
     * sinch-push answers that with a second push for a message the user has.
     */
    @Test
    fun `RN049_anIdFcmAlreadyShowedIsStillAckedDeliveredOverTheSocket`() {
        val seen = SeenSet(InMemorySocketStateStore())
        Fcm(seen).receive("fcm-1", mapOf(key to "x"))
        val h = Harness(seen = seen)
        h.startAndConnect()

        h.conn.serverSends(pushMessage("x"))

        assertEquals("exactly one DELIVERED for x, and nothing else", listOf("x:1"), h.sentReports())
        assertTrue("no JS event", h.messages.isEmpty())
        assertTrue("no notification", h.notifications.shown.isEmpty())
    }

    /** The same id twice over the socket: the first ack stands (SB-30). */
    @Test
    fun `RN049_theSameIdTwiceOverTheSocketIsAckedOnce`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSends(pushMessage("x"))
        h.conn.serverSends(pushMessage("x")) // the relay re-offers it on the next Poll

        // The first copy acks DELIVERED and the notification acks DISPLAYED; the
        // second copy adds nothing (SB-30).
        assertEquals(listOf("x:1", "x:2"), h.sentReports())
        assertEquals(1, h.messages.size)
        assertEquals(1, h.notifications.shown.size)
    }

    // ------------------------------------------------------------ SB-65

    @Test
    fun `SB65_fcmAndSocketRenderUnderTheSameTagAndId`() {
        val fcm = Fcm(SeenSet(InMemorySocketStateStore()))
        fcm.receive("fcm-1", mapOf(key to "m1"))

        val socketIdentity = SinchNotificationIdentity.of("m1")

        assertEquals("m1", fcm.shown.single().tag)
        assertEquals(socketIdentity.tag, fcm.shown.single().tag)
        assertEquals(socketIdentity.id, fcm.shown.single().id)
        assertEquals(SocketSpec.SINCH_MESSAGE_NOTIFICATION_ID, socketIdentity.id)
    }

    @Test
    fun `SB65_theNotificationIdIsNotTheForegroundServiceId`() {
        assertNotEquals(
            SinchPushSocketNotifications.FOREGROUND_NOTIFICATION_ID,
            SocketSpec.SINCH_MESSAGE_NOTIFICATION_ID,
        )
    }

    @Test
    fun `SB65_aMessageWithoutAnIdIsNotRenderedUnderTheSharedIdentity`() {
        val fcm = Fcm(SeenSet(InMemorySocketStateStore()))
        fcm.receive(null, emptyMap())

        assertNull(fcm.shown.single().tag)
        assertNotEquals(SocketSpec.SINCH_MESSAGE_NOTIFICATION_ID, fcm.shown.single().id)
    }

    // ------------------------------------------------------------ SB-28

    @Test
    fun `SB28_theSharedSetHoldsTwoThousandAndEvictsTheOldest`() {
        val seen = SeenSet(InMemorySocketStateStore())
        for (i in 1..SocketSpec.SEEN_SET_CAPACITY) assertTrue(seen.add("m$i"))
        assertEquals(2000, seen.size())
        assertTrue(seen.add("m2001"))
        assertEquals(2000, seen.size())
        assertFalse(seen.contains("m1"))
        assertTrue(seen.contains("m2"))
    }

    @Test
    fun `SB28_anExistingFiveHundredSetLoadsIntoTheTwoThousandSet`() {
        val store = InMemorySocketStateStore()
        store.saveSeen((1..500).map { "old-$it" })

        val seen = SeenSet(store)

        assertEquals(500, seen.size())
        assertTrue(seen.contains("old-1"))
        assertFalse("a migrated id still dedupes", seen.add("old-250"))
        for (i in 1..1500) assertTrue(seen.add("new-$i"))
        assertEquals(2000, seen.size())
        assertTrue("nothing evicted yet", seen.contains("old-1"))
        assertTrue(seen.add("one-more"))
        assertFalse(seen.contains("old-1"))
        assertEquals(seen.snapshot(), store.loadSeen())
    }

    @Test
    fun `SB28_aSecondFcmHandlerOverTheSameStoreStillDedupesAfterARestart`() {
        val store = InMemorySocketStateStore()
        val first = Fcm(SeenSet(store))
        first.receive("a", mapOf(key to "m1"))

        val second = Fcm(SeenSet(store))
        second.receive("b", mapOf(key to "m1"))

        assertTrue(second.emitted.isEmpty())
    }

    @Test
    fun `SB64_theSocketAndFcmWiringResolveToOneSharedInstance`() {
        SharedSeenSet.setForTesting(null)
        try {
            val store = InMemorySocketStateStore()
            var built = 0
            // What `androidSocketDependencies` and the FCM service each do.
            val forSocket = SharedSeenSet.getOrCreate { built++; SeenSet(store) }
            val forFcm = SharedSeenSet.getOrCreate { built++; SeenSet(InMemorySocketStateStore()) }

            assertSame(forSocket, forFcm)
            assertEquals("the factory runs once", 1, built)

            val fcm = Fcm(forFcm)
            val h = Harness(seen = forSocket)
            h.startAndConnect()
            fcm.receive("fcm-1", mapOf(key to "m1"))
            h.conn.serverSends(pushMessage("m1"))

            assertEquals(1, fcm.emitted.size)
            assertTrue("the socket's copy is a hit", h.messages.isEmpty())
        } finally {
            SharedSeenSet.setForTesting(null)
        }
    }

    @Test
    fun `SB64_concurrentAddsAdmitEachIdExactlyOnce`() {
        val seen = SeenSet(InMemorySocketStateStore())
        val threads = 8
        val pool = Executors.newFixedThreadPool(threads)
        val admitted = AtomicInteger()
        val start = CountDownLatch(1)
        val done = CountDownLatch(threads)
        repeat(threads) {
            pool.execute {
                start.await()
                // Every thread races over the same 300 ids.
                for (i in 1..300) if (seen.add("m$i")) admitted.incrementAndGet()
                done.countDown()
            }
        }
        start.countDown()
        assertTrue(done.await(20, TimeUnit.SECONDS))
        pool.shutdown()

        assertEquals(300, admitted.get())
        assertEquals(300, seen.size())
    }
}
