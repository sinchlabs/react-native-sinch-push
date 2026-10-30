package com.sinchpush.socket

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import sinch.push.delivery.v1beta1.ws.CloseReason
import sinch.push.delivery.v1beta1.ws.DeliveryReport

/**
 * SB-29, SB-62, SB-63: the fast ack, the replay cursor and the replay-burst
 * notification rule.
 *
 * The relay stores every message for 72 h, replays whatever follows
 * `Hello.last_seen_message_id` on reconnect (plan D3) and waits 5 s (Android)
 * for a `DELIVERED` before it falls back to FCM (D4/D5).
 */
class ReplayRulesTest {

    @Before
    fun resetPresentationBuffer() = SinchPushSocketStore.clear()

    /** [InMemorySocketStateStore] that reports each last-seen write, before it lands. */
    private class SpyStore(
        val inner: InMemorySocketStateStore = InMemorySocketStateStore(),
        var onSaveLastSeen: () -> Unit = {},
    ) : SocketStateStore by inner {
        override fun saveLastSeenMessageId(id: String) {
            onSaveLastSeen()
            inner.saveLastSeenMessageId(id)
        }

        override fun saveLastSeen(id: String, enqueuedAtMs: Long) {
            onSaveLastSeen()
            inner.saveLastSeen(id, enqueuedAtMs)
        }
    }

    // ------------------------------------------------------------ SB-62

    @Test
    fun `SB62_deliveredIsTheFirstOutboundFrameAfterAPushedMessage`() {
        val h = Harness()
        h.startAndConnect()
        val before = h.conn.sent.size

        h.conn.serverSends(pushMessage("m1"))

        val after = h.conn.sent.drop(before)
        assertEquals("DELIVERED, then DISPLAYED", 2, after.size)
        val first = after.first() as DeliveryReport
        assertEquals("m1", first.message_id)
        assertEquals(DeliveryReport.Status.DELIVERED, first.status)
    }

    @Test
    fun `SB62_deliveredIsOnTheWireBeforeTheJsListenerAndTheNotificationRun`() {
        val h = Harness()
        h.startAndConnect()
        var atListener = emptyList<DeliveryReport.Status>()
        var atShow = emptyList<DeliveryReport.Status>()
        h.client.setListener(object : SinchPushSocketClient.Listener {
            override fun onMessage(message: SinchPushSocketStore.SocketMessage) {
                atListener = h.conn.reports.map { it.status }
            }
            override fun onState(state: SinchPushSocketStore.SocketState) {}
        })
        h.notifications.onShow = { atShow = h.conn.reports.map { it.status } }

        h.conn.serverSends(pushMessage("m1"))

        assertEquals(listOf(DeliveryReport.Status.DELIVERED), atListener)
        assertEquals(listOf(DeliveryReport.Status.DELIVERED), atShow)
    }

    @Test
    fun `SB62_theSeenSetAndLastSeenAreDurableBeforeDeliveredGoesOut`() {
        val store = SpyStore()
        val h = Harness(store = store)
        h.startAndConnect()
        var reportsWhenSaved = -1
        var seenWhenSaved = emptyList<String>()
        store.onSaveLastSeen = {
            reportsWhenSaved = h.conn.reports.size
            seenWhenSaved = store.loadSeen()
        }

        h.conn.serverSends(pushMessage("m1"))

        assertEquals(listOf("m1"), seenWhenSaved)
        assertEquals("last_seen was saved after the report was sent", 0, reportsWhenSaved)
        assertEquals(1, h.conn.reports.count { it.status == DeliveryReport.Status.DELIVERED })
        assertEquals("m1", store.loadLastSeenMessageId())
    }

    @Test
    fun `SB62_aThrowingListenerCannotStopTheReportOrTheNotification`() {
        val h = Harness()
        h.startAndConnect()
        h.client.setListener(object : SinchPushSocketClient.Listener {
            override fun onMessage(message: SinchPushSocketStore.SocketMessage) = error("host listener bug")
            override fun onState(state: SinchPushSocketStore.SocketState) {}
        })

        h.conn.serverSends(pushMessage("m1"))

        assertEquals(1, h.conn.reports.count { it.status == DeliveryReport.Status.DELIVERED })
        assertEquals("the notification still posted", 1, h.notifications.shown.size)
        assertEquals("and DISPLAYED followed", 1, h.conn.reports.count { it.status == DeliveryReport.Status.DISPLAYED })
        assertTrue(h.logger.any("message listener failed"))
    }

    @Test
    fun `SB62_aThrowingPresenterStillLeavesDeliveredSentAndNoDisplayed`() {
        val h = Harness()
        h.startAndConnect()
        h.notifications.onShow = { error("notification manager blew up") }

        h.conn.serverSends(pushMessage("m1"))
        h.conn.serverSends(pushMessage("m2"))

        assertEquals(listOf("m1", "m2"), h.conn.reports.filter { it.status == DeliveryReport.Status.DELIVERED }.map { it.message_id })
        assertEquals(0, h.conn.reports.count { it.status == DeliveryReport.Status.DISPLAYED })
        assertTrue(h.logger.any("notification failed"))
    }

    @Test
    fun `SB62_everyMessageOfAHelloAckReplayIsAckedInReplayOrderBeforeTheFirstPoll`() {
        val h = Harness(notificationsPost = false)
        h.start()
        h.connect("conn-1", 5000, pooled("a", enqueuedAt = 1_000), pooled("b", enqueuedAt = 2_000), pooled("c", enqueuedAt = 3_000))

        val kinds = h.conn.sent.map { it::class.simpleName }
        assertEquals(listOf("Hello", "DeliveryReport", "DeliveryReport", "DeliveryReport", "Poll"), kinds)
        assertEquals(listOf("a", "b", "c"), h.conn.reports.map { it.message_id })
    }

    @Test
    fun `SB62_aPreviouslyReportedDuplicateSendsNoSecondReport`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))
        val sent = h.conn.sentBytes.size

        h.conn.serverSends(pushMessage("m1"))

        assertEquals(sent, h.conn.sentBytes.size)
    }

    // ------------------------------------------------------------ SB-29

    @Test
    fun `SB29_lastSeenIsPersistedOnEveryDedupeMissAndAHitNeverRegressesIt`() {
        val store = InMemorySocketStateStore()
        val h = Harness(store = store, notificationsPost = false)
        h.startAndConnect()

        h.conn.serverSends(pushMessage("m1", ackToken = "t1").copy(message = pooled("m1", enqueuedAt = 1_000)))
        assertEquals("m1", store.loadLastSeenMessageId())
        h.conn.serverSends(pushMessage("m2").copy(message = pooled("m2", enqueuedAt = 2_000)))
        assertEquals("m2", store.loadLastSeenMessageId())
        assertEquals(2_000L, store.loadLastSeenEnqueuedAtMs())

        h.conn.serverSends(pushMessage("m1").copy(message = pooled("m1", enqueuedAt = 1_000)))
        assertEquals("a hit on an older message does not move the cursor back", "m2", store.loadLastSeenMessageId())
    }

    @Test
    fun `SB29_aFreshClientOverTheSameStoreSendsTheCursorInItsHello`() {
        val store = InMemorySocketStateStore()
        val first = Harness(store = store, notificationsPost = false)
        first.startAndConnect()
        first.conn.serverSends(pushMessage("m1").copy(message = pooled("m1", enqueuedAt = 1_000)))
        first.conn.serverSends(pushMessage("m2").copy(message = pooled("m2", enqueuedAt = 2_000)))

        val restarted = Harness(store = store)
        restarted.start()
        restarted.conn.serverOpens()

        assertEquals("m2", restarted.conn.hellos.single().last_seen_message_id)
    }

    @Test
    fun `SB29_anOlderMessageArrivingAfterANewerOneDoesNotMoveTheCursorBack`() {
        val store = InMemorySocketStateStore()
        val h = Harness(store = store, notificationsPost = false)
        h.startAndConnect()

        h.conn.serverSends(pushMessage("new").copy(message = pooled("new", enqueuedAt = 5_000)))
        h.conn.serverSends(pushMessage("old").copy(message = pooled("old", enqueuedAt = 1_000)))

        assertEquals("new", store.loadLastSeenMessageId())
        assertEquals(5_000L, store.loadLastSeenEnqueuedAtMs())
        // Nothing about the older message is lost: it is emitted, reported and in
        // the seen set, which is what dedupes - never the cursor.
        assertEquals(listOf("new", "old"), h.messages.map { it.id })
        assertEquals(listOf("new", "old"), h.conn.reports.map { it.message_id })
        assertTrue(store.loadSeen().contains("old"))

        h.conn.serverSends(closeFrame(CloseReason.STALE))
        h.conn.serverOpens()
        assertEquals("new", h.conn.hellos.single().last_seen_message_id)
    }

    @Test
    fun `SB29_theNoRegressionRuleHoldsAcrossARestart`() {
        val store = InMemorySocketStateStore()
        val first = Harness(store = store, notificationsPost = false)
        first.startAndConnect()
        first.conn.serverSends(pushMessage("new").copy(message = pooled("new", enqueuedAt = 5_000)))

        val second = Harness(store = store, notificationsPost = false)
        second.startAndConnect()
        second.conn.serverSends(pushMessage("old").copy(message = pooled("old", enqueuedAt = 1_000)))

        assertEquals("new", store.loadLastSeenMessageId())
    }

    @Test
    fun `SB29_equalTimestampsAndMissingTimestampsFollowArrivalOrder`() {
        val store = InMemorySocketStateStore()
        val h = Harness(store = store, notificationsPost = false)
        h.startAndConnect()
        fun send(id: String, at: Long) = h.conn.serverSends(pushMessage(id).copy(message = pooled(id, enqueuedAt = at)))

        send("a", 5_000)
        send("b", 5_000)
        assertEquals("a tie is arrival order", "b", store.loadLastSeenMessageId())

        send("c", 0)
        assertEquals("no timestamp: arrival order", "c", store.loadLastSeenMessageId())
        assertEquals(0L, store.loadLastSeenEnqueuedAtMs())

        send("d", 1_000)
        assertEquals("nothing to compare against once the cursor has no timestamp", "d", store.loadLastSeenMessageId())
    }

    @Test
    fun `SB29_aHelloAckReplayLeavesTheCursorOnTheNewestMessage`() {
        val store = InMemorySocketStateStore()
        val h = Harness(store = store, notificationsPost = false)
        h.start()
        h.connect("conn-1", 5000, pooled("a", enqueuedAt = 1_000), pooled("b", enqueuedAt = 2_000))

        assertEquals("b", store.loadLastSeenMessageId())
    }

    // ------------------------------------------------------------ SB-63

    @Test
    fun `SB63_theWindowAndTheGroupAreTheSpecifiedConstants`() {
        assertEquals(2000L, SocketSpec.NOTIFICATION_ALERT_WINDOW_MS)
        assertEquals("com.sinch.push.messages", SocketSpec.NOTIFICATION_GROUP)
    }

    @Test
    fun `SB63_aBurstOfNWithinTheWindowIsOneAlertAndNMinusOneSilent`() {
        val h = Harness()
        h.startAndConnect()

        for (i in 0 until 6) {
            h.conn.serverSends(pushMessage("m-$i"))
            h.clock.now += 300 // 6 x 300 ms = 1.8 s < 2 s
        }

        assertEquals("nothing is dropped", 6, h.notifications.shown.size)
        assertEquals(listOf(true, false, false, false, false, false), h.notifications.shownAlerting)
        assertEquals("silent posts are still DISPLAYED", 6, h.conn.reports.count { it.status == DeliveryReport.Status.DISPLAYED })
        assertEquals(6, h.messages.size)
    }

    @Test
    fun `SB63_aReplayInOneHelloAckIsOneAlertAndTheRestSilent`() {
        val h = Harness()
        h.start()
        h.connect("conn-1", 5000, *(0 until 4).map { pooled("r-$it") }.toTypedArray())

        assertEquals(listOf(true, false, false, false), h.notifications.shownAlerting)
    }

    @Test
    fun `SB63_aNewAlertIsAllowedOnceTheWindowHasElapsed`() {
        val h = Harness()
        h.startAndConnect()

        h.conn.serverSends(pushMessage("m-0"))
        h.clock.now += 1_999
        h.conn.serverSends(pushMessage("m-1"))
        h.clock.now += 1 // exactly 2000 ms after the alert
        h.conn.serverSends(pushMessage("m-2"))
        h.clock.now += 100
        h.conn.serverSends(pushMessage("m-3"))

        assertEquals(listOf(true, false, true, false), h.notifications.shownAlerting)
    }

    @Test
    fun `SB63_aMessageThatIsNotDisplayedDoesNotSpendTheWindow`() {
        val h = Harness(config = testConfig(displayNotifications = false))
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m-0"))
        assertTrue(h.notifications.shown.isEmpty())

        val shown = Harness(config = testConfig(displayNotifications = true))
        shown.startAndConnect()
        shown.conn.serverSends(pushMessage("m-1"))

        assertEquals(listOf(true), shown.notifications.shownAlerting)
    }
}
