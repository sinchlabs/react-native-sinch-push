package com.sinchpush.socket

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import sinch.push.delivery.v1beta1.ws.CloseReason
import sinch.push.delivery.v1beta1.ws.DeliveryReport
import sinch.push.delivery.v1beta1.ws.Message as ServerMessage

/** SB-25 .. SB-37, SB-40: dedupe, the report state machine, Ack policy and the outbox. */
class DeliveryReportRulesTest {

    @Before
    fun resetPresentationBuffer() = SinchPushSocketStore.clear()

    private fun Harness.statuses(): List<Pair<String, ReportStatus>> =
        conn.reports.map { it.message_id to ReportStatus.values().first { s -> s.wire == it.status } }

    private fun Harness.reportsFor(id: String, status: ReportStatus) =
        conn.reports.count { it.message_id == id && it.status == status.wire }

    // ------------------------------------------------------------- dedupe

    @Test
    fun `SB25_dedupeKeyIsMessageIdNeverAckToken`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1", ackToken = "tok-A"))
        h.conn.serverSends(pushMessage("m1", ackToken = "tok-B"))
        assertEquals("same message_id, different token: one event", 1, h.messages.size)
        h.conn.serverSends(pushMessage("m2", ackToken = "tok-A"))
        assertEquals("different message_id, same token: a second event", 2, h.messages.size)
    }

    @Test
    fun `SB25_aColonInsideAMessageIdNeedsNoEscaping`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSends(pushMessage("a:1"))
        h.conn.serverSends(pushMessage("a:1"))
        assertEquals(1, h.messages.size)
        assertEquals(1, h.reportsFor("a:1", ReportStatus.DELIVERED))
    }

    @Test
    fun `SB26_toleratesAckTokenEqualOrIndependentOfMessageId`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSends(pushMessage("same", ackToken = "same"))
        h.conn.serverSends(pushMessage("apart", ackToken = "unrelated-random"))
        assertEquals(listOf("same", "apart"), h.messages.map { it.id })
        assertEquals(listOf("same", "unrelated-random"), h.messages.map { it.ackToken })
        assertEquals(1, h.reportsFor("same", ReportStatus.DELIVERED))
        assertEquals(1, h.reportsFor("apart", ReportStatus.DELIVERED))
    }

    @Test
    fun `SB27_aSocketDuplicateIsSilentAndSendsNoSecondReport`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))
        val framesAfterFirst = h.conn.sentBytes.size
        val shownAfterFirst = h.notifications.shown.size
        h.conn.serverSends(pushMessage("m1")) // the relay re-offers on the next Poll
        assertEquals("no event", 1, h.messages.size)
        assertEquals("no report", framesAfterFirst, h.conn.sentBytes.size)
        assertEquals("no notification", shownAfterFirst, h.notifications.shown.size)
        assertEquals(1, h.reportsFor("m1", ReportStatus.DELIVERED))
    }

    @Test
    fun `SB27_aHitInsideHelloAckIsAlsoSilentAndSendsNoSecondReport`() {
        val store = InMemorySocketStateStore()
        Harness(store = store).apply { startAndConnect("conn-1", 5000, pooled("m1")) }
        val again = Harness(store = store)
        again.startAndConnect("conn-1", 5000, pooled("m1"))
        assertTrue(again.messages.isEmpty())
        assertTrue(again.conn.reports.isEmpty())
    }

    @Test
    fun `SB27_emptyMessageIdIsDroppedWithoutAReport`() {
        val h = Harness()
        h.startAndConnect()
        val frames = h.conn.sentBytes.size
        h.conn.serverSends(ServerMessage(ack_token = "t", message = pooled("")))
        assertTrue(h.messages.isEmpty())
        assertEquals(frames, h.conn.sentBytes.size)
        assertTrue(h.conn.reports.none { it.message_id.isEmpty() })
    }

    @Test
    fun `SB28_seenSetIsBoundedAt2000EvictingTheOldest`() {
        val store = InMemorySocketStateStore()
        val seen = SeenSet(store)
        assertEquals(2000, SocketSpec.SEEN_SET_CAPACITY)
        for (i in 1..2000) assertTrue(seen.add("id-$i"))
        assertEquals(2000, seen.size())
        assertTrue(seen.contains("id-1"))
        assertTrue(seen.add("id-2001"))
        assertEquals(2000, seen.size())
        assertFalse("2001st insert evicts the oldest", seen.contains("id-1"))
        assertTrue(seen.contains("id-2"))
        assertTrue(seen.contains("id-2001"))
        assertEquals(2000, store.loadSeen().size)
    }

    @Test
    fun `SB28_evictedIdCanBeRedeliveredAndReReported`() {
        val h = Harness()
        h.startAndConnect()
        for (i in 1..(SocketSpec.SEEN_SET_CAPACITY + 1)) h.conn.serverSends(pushMessage("id-$i"))
        val delivered = h.messages.size
        h.conn.serverSends(pushMessage("id-1"))
        assertEquals(delivered + 1, h.messages.size)
    }

    @Test
    fun `SB28_seenSetIsPersistedAndNotWipedOnStart`() {
        val store = InMemorySocketStateStore()
        val first = Harness(store = store)
        first.startAndConnect()
        first.conn.serverSends(pushMessage("m1"))

        val restarted = Harness(store = store)
        restarted.startAndConnect()
        restarted.conn.serverSends(pushMessage("m1"))
        assertTrue("dedupe survives a client restart", restarted.messages.isEmpty())
        // RN-049 acks the hit, but SB-30's persisted sent set is what keeps that
        // from being a second DELIVERED for one delivery.
        assertTrue("nothing re-reported", restarted.conn.reports.isEmpty())
    }

    // ------------------------------------------------- report state machine

    @Test
    fun `SB30_deliveredOnDedupeMissThenDisplayedWhenNotificationPosted`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))
        assertEquals(
            listOf("m1" to ReportStatus.DELIVERED, "m1" to ReportStatus.DISPLAYED),
            h.statuses(),
        )
        assertEquals(1, h.notifications.shown.size)
    }

    @Test
    fun `SB30_noDisplayedWhenThePlatformRefusedTheNotification`() {
        val h = Harness(notificationsPost = false)
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))
        assertEquals(listOf("m1" to ReportStatus.DELIVERED), h.statuses())
    }

    @Test
    fun `SB30_noNotificationNoDisplayedWhenDisplayIsDisabled`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))
        assertTrue(h.notifications.shown.isEmpty())
        assertEquals(listOf("m1" to ReportStatus.DELIVERED), h.statuses())
    }

    @Test
    fun `SB30_hostReportedDisplayedAndDismissedAreSentOncePerStatus`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))
        repeat(3) { h.client.reportStatus("m1", ReportStatus.DISPLAYED) }
        repeat(3) { h.client.reportStatus("m1", ReportStatus.DISMISSED) }
        assertEquals(1, h.reportsFor("m1", ReportStatus.DELIVERED))
        assertEquals(1, h.reportsFor("m1", ReportStatus.DISPLAYED))
        assertEquals(1, h.reportsFor("m1", ReportStatus.DISMISSED))
        assertEquals(ReportStatus.DISMISSED, ReportStatus.fromHostString("dismissed"))
        assertNull(ReportStatus.fromHostString("delivered"))
    }

    @Test
    fun `SB30_statusEnumValuesAreThePinnedNumbers`() {
        assertEquals(
            listOf(1, 2, 3, 4),
            listOf(ReportStatus.DELIVERED, ReportStatus.DISPLAYED, ReportStatus.FAILED, ReportStatus.DISMISSED).map { it.code },
        )
        assertEquals(DeliveryReport.Status.DISMISSED, ReportStatus.DISMISSED.wire)
    }

    @Test
    fun `SB30_sentSetSurvivesRestartSoNothingIsReReported`() {
        val store = InMemorySocketStateStore()
        val first = Harness(testConfig(displayNotifications = false), store = store)
        first.startAndConnect()
        first.conn.serverSends(pushMessage("m1"))
        first.client.reportStatus("m1", ReportStatus.DISMISSED)

        val restarted = Harness(testConfig(displayNotifications = false), store = store)
        restarted.startAndConnect()
        restarted.client.reportStatus("m1", ReportStatus.DISMISSED)
        restarted.client.reportStatus("m1", ReportStatus.DELIVERED)
        assertTrue(restarted.conn.reports.isEmpty())
    }

    @Test
    fun `SB31_reportCarriesPooledIdSinchIdStatusReasonAndTimestamp`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect()
        h.clock.now = 1_234_567L
        h.conn.serverSends(ServerMessage(ack_token = "t", message = pooled("pooled-1", sinchId = "sinch-9")))
        val r = h.conn.reports.single()
        assertEquals("pooled-1", r.message_id)
        assertEquals("sinch-9", r.sinch_message_id)
        assertEquals(DeliveryReport.Status.DELIVERED, r.status)
        assertEquals("", r.reason)
        assertEquals(1_234_567L, r.reported_at_unix_millis)
    }

    @Test
    fun `SB31_hostReportRetainsTheSinchIdFromTheOriginalMessage`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect()
        h.conn.serverSends(ServerMessage(message = pooled("p", sinchId = "s-p")))
        h.client.reportStatus("p", ReportStatus.DISMISSED)
        assertEquals("s-p", h.conn.reports.last().sinch_message_id)
    }

    @Test
    fun `SB31_neverAReportWithAnEmptyMessageId`() {
        val h = Harness()
        h.startAndConnect()
        h.client.reportStatus("", ReportStatus.DISMISSED)
        assertTrue(h.conn.reports.isEmpty())
        assertEquals("nothing queued either", 0, h.store.loadOutbox().size)
    }

    @Test
    fun `SB32_ackTokenIsMessageIdColonNumericStatus`() {
        for ((status, n) in listOf(ReportStatus.DELIVERED to 1, ReportStatus.DISPLAYED to 2, ReportStatus.FAILED to 3, ReportStatus.DISMISSED to 4)) {
            val report = PendingReport("abc123", "s", status, "", 0)
            assertEquals("abc123:$n", report.ackToken)
        }
    }

    @Test
    fun `SB32_emptyOrUnknownAckTokenIsIgnoredAndNeverClearsAnEntry`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))
        h.conn.serverSends(sinch.push.delivery.v1beta1.ws.Ack(ack_token = "", accepted = false, error = "rate_limited"))
        h.conn.serverSends(sinch.push.delivery.v1beta1.ws.Ack(ack_token = "nobody:1", accepted = false, error = "upstream_forward_failed"))
        h.scheduler.advanceBy(20_000)
        assertEquals("no retry, no resend", 1, h.reportsFor("m1", ReportStatus.DELIVERED))
        assertEquals(0, h.store.loadOutbox().size)
    }

    @Test
    fun `SB33_rateLimitedDefersWithBackoffAndIsNotRetriedOnTheNextPollTick`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect(pollMs = 1000)
        h.conn.serverSends(pushMessage("m1"))
        h.scheduler.advanceBy(1500) // a tick has just passed; the next is at +1000 from connect
        h.conn.serverSends(ackFor("m1", ReportStatus.DELIVERED, accepted = false, error = "rate_limited"))
        assertEquals("rejected report sets lastError", "report rejected: rate_limited", h.state.lastError)
        h.scheduler.advanceBy(500) // tick at 2000 is inside the deferral window (until 2500)
        assertEquals("a hot retry would reproduce the rejection", 1, h.reportsFor("m1", ReportStatus.DELIVERED))
        h.scheduler.advanceBy(1000) // tick at 3000, deferral expired
        assertEquals("retried once the backoff has elapsed", 2, h.reportsFor("m1", ReportStatus.DELIVERED))
    }

    @Test
    fun `SB33_upstreamForwardFailedRetriesOnTheNextTickThenGivesUp`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect(pollMs = 1000)
        h.conn.serverSends(pushMessage("m1"))
        repeat(5) {
            h.conn.serverSends(ackFor("m1", ReportStatus.DELIVERED, accepted = false, error = "upstream_forward_failed"))
            h.scheduler.advanceBy(1000)
        }
        assertEquals("bounded: first send plus two retries", SocketSpec.MAX_REPORT_ATTEMPTS, h.reportsFor("m1", ReportStatus.DELIVERED))
        assertEquals(0, h.store.loadOutbox().size)
    }

    @Test
    fun `SB33_unsupportedStatusIsPermanentForThatPair`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect(pollMs = 1000)
        h.conn.serverSends(pushMessage("m1"))
        h.client.reportStatus("m1", ReportStatus.DISMISSED)
        h.conn.serverSends(ackFor("m1", ReportStatus.DISMISSED, accepted = false, error = "unsupported_status"))
        assertEquals("report rejected: unsupported_status", h.state.lastError)
        h.scheduler.advanceBy(60_000)
        assertEquals("no retry on any tick", 1, h.reportsFor("m1", ReportStatus.DISMISSED))
        h.conn.serverSends(closeFrame(CloseReason.STALE))
        h.connect("conn-2")
        assertEquals("no resend after reconnect either", 0, h.reportsFor("m1", ReportStatus.DISMISSED))
        assertEquals(0, h.store.loadOutbox().size)
    }

    @Test
    fun `SB33_acceptedAckClearsAQueuedRetry`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect(pollMs = 1000)
        h.conn.serverSends(pushMessage("m1"))
        h.conn.serverSends(ackFor("m1", ReportStatus.DELIVERED, accepted = false, error = "upstream_forward_failed"))
        h.conn.serverSends(ackFor("m1", ReportStatus.DELIVERED, accepted = true))
        h.scheduler.advanceBy(5000)
        assertEquals(1, h.reportsFor("m1", ReportStatus.DELIVERED))
        assertEquals(0, h.store.loadOutbox().size)
    }

    // ----------------------------------------------------------- the outbox

    @Test
    fun `SB35_reportRaisedWhileDisconnectedIsQueuedPersistedAndFlushedAfterHelloAck`() {
        val store = InMemorySocketStateStore()
        val offline = Harness(store = store)
        offline.start() // never connects
        offline.client.reportStatus("m1", ReportStatus.DISMISSED)
        assertEquals(1, store.loadOutbox().size)

        val restarted = Harness(store = store) // a process restart
        restarted.start()
        restarted.conn.serverOpens()
        assertTrue("nothing flushed before HelloAck", restarted.conn.reports.isEmpty())
        restarted.conn.serverSends(helloAck())
        val report = restarted.conn.reports.single()
        assertEquals("m1", report.message_id)
        assertEquals(DeliveryReport.Status.DISMISSED, report.status)
        val order = restarted.conn.sent.map { it.javaClass.simpleName }
        assertTrue("Poll goes first, then the outbox", order.indexOf("Poll") < order.indexOf("DeliveryReport"))
        assertEquals(0, store.loadOutbox().size)
    }

    @Test
    fun `SB35_outboxIsBoundedAt200DroppingTheOldestWithALog`() {
        val store = InMemorySocketStateStore()
        val h = Harness(store = store)
        h.start() // not connected: every report queues
        for (i in 1..201) h.client.reportStatus("m$i", ReportStatus.DISMISSED)
        val queued = store.loadOutbox()
        assertEquals(SocketSpec.OUTBOX_CAPACITY, queued.size)
        assertEquals("m2", queued.first().messageId)
        assertEquals("m201", queued.last().messageId)
        assertTrue(h.logger.any("outbox full"))
    }

    @Test
    fun `SB35_aSocketThatRefusesTheFrameKeepsTheReportQueued`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect(pollMs = 1000)
        h.conn.acceptSends = false
        h.client.reportStatus("m1", ReportStatus.DISMISSED)
        assertEquals(1, h.store.loadOutbox().size)
        h.conn.acceptSends = true
        h.scheduler.advanceBy(1000)
        assertEquals(1, h.reportsFor("m1", ReportStatus.DISMISSED))
    }

    // ------------------------------------------------------ message content

    @Test
    fun `SB36_emptyProto3StringsMapToAbsent`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSends(ServerMessage(message = pooled("m1", title = "", body = "", imageUrl = "", trigger = "")))
        val m = h.messages.single()
        assertNull(m.title)
        assertNull(m.body)
        assertNull(m.imageUrl)
        assertNull(m.trigger)
    }

    @Test
    fun `SB36_populatedStringsArriveIntactIncludingAstralText`() {
        val h = Harness()
        h.startAndConnect()
        val text = "héllo 🚀 世界"
        h.conn.serverSends(ServerMessage(message = pooled("m1", title = text, body = text, imageUrl = "https://x/y.png", trigger = "go")))
        val m = h.messages.single()
        assertEquals(text, m.title)
        assertEquals(text, m.body)
        assertEquals("https://x/y.png", m.imageUrl)
        assertEquals("go", m.trigger)
    }

    @Test
    fun `SB37_channelMessageIdIsThePooledIdAndNothingElse`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect()
        h.conn.serverSends(ServerMessage(ack_token = "tok-xyz", message = pooled("pooled-1", sinchId = "sinch-1")))
        val r = h.conn.reports.single()
        assertTrue("present and non-empty", r.message_id.isNotEmpty())
        assertEquals("equals the pooled id the client deduped on", "pooled-1", r.message_id)
        assertNotEquals("not the sinch id", "sinch-1", r.message_id)
        assertNotEquals("not the Ack token", "pooled-1:1", r.message_id)
        assertNotEquals("not the message's own ack_token", "tok-xyz", r.message_id)
    }

    // ------------------------------------------------------- failures

    private fun messageFrame(pooledBytes: ByteArray): ByteArray =
        envelope(FrameCodec.SERVER_TAG_MESSAGE, bytesOf(0x12, pooledBytes.size, pooledBytes))

    @Test
    fun `SB40_messageWithoutAPooledMessageIsDroppedNotReportedWithAnEmptyId`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSends(ServerMessage(ack_token = "t", message = null))
        assertTrue(h.messages.isEmpty())
        assertTrue(h.conn.reports.isEmpty())
        assertEquals("connected", h.status)
    }

    @Test
    fun `SB40_undecodablePayloadWithARecoverableIdIsReportedFailedWithDecodeReason`() {
        val h = Harness()
        h.startAndConnect()
        // PooledMessage { message_id = "x1", push_notification = <wire type 7: invalid> }
        val pooledBytes = bytesOf(0x0A, 2, 'x'.code, '1'.code, 0x1A, 1, 0x07)
        h.conn.serverSendsRaw(messageFrame(pooledBytes))
        val r = h.conn.reports.single()
        assertEquals("x1", r.message_id)
        assertEquals(DeliveryReport.Status.FAILED, r.status)
        assertTrue("reason is 'decode: ...' but was '${r.reason}'", r.reason.startsWith("decode: ") && r.reason.length > "decode: ".length)
        assertTrue(h.messages.isEmpty())
        assertEquals("connected", h.status)
    }

    @Test
    fun `SB40_failedIsReportedOncePerMessageId`() {
        val h = Harness()
        h.startAndConnect()
        val frame = messageFrame(bytesOf(0x0A, 2, 'x'.code, '1'.code, 0x1A, 1, 0x07))
        h.conn.serverSendsRaw(frame)
        h.conn.serverSendsRaw(frame)
        assertEquals(1, h.conn.reports.size)
    }

    @Test
    fun `SB40_undecodablePayloadWithNoRecoverableIdSendsNoReportAtAll`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSendsRaw(messageFrame(bytesOf(0x1A, 1, 0x07)))
        assertTrue("never a report with an empty message_id", h.conn.reports.isEmpty())
        assertEquals("connected", h.status)
    }

    @Test
    fun `SB17_illFormedUtf8InAnAlertIsRefusedNotSubstituted`() {
        val h = Harness()
        h.startAndConnect()
        // Alert { title = 0xFF } inside PushNotification inside PooledMessage { id "u1" }
        val alert = bytesOf(0x0A, 1, 0xFF)
        val push = bytesOf(0x12, alert.size, alert)
        val pooledBytes = bytesOf(0x0A, 2, 'u'.code, '1'.code, 0x1A, push.size, push)
        h.conn.serverSendsRaw(messageFrame(pooledBytes))
        assertTrue("no notification content invented from bytes the protocol never encoded", h.messages.none { it.title?.contains('�') == true })
    }
}
