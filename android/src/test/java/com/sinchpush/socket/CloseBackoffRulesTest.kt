package com.sinchpush.socket

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import sinch.push.delivery.v1beta1.ws.CloseReason

/** SB-34, SB-41 .. SB-53: close reasons, full-jitter backoff and the HelloAck reset. */
class CloseBackoffRulesTest {

    @Before
    fun resetPresentationBuffer() = SinchPushSocketStore.clear()

    /** Connects, optionally does real work, then closes with [reason]. */
    private fun Harness.sessionThenClose(
        reason: CloseReason,
        detail: String = "rate_limited",
        doWork: Boolean = false,
        connectionId: String = "c",
    ) {
        connect(connectionId)
        if (doWork) conn.serverSends(pushMessage("w-${clock.now}-${transport.connections.size}"))
        conn.serverSends(closeFrame(reason, detail))
    }

    private fun Harness.reconnect(afterMs: Long) {
        scheduler.advanceBy(afterMs)
    }

    // ------------------------------------------------------------ SB-41

    @Test
    fun `SB41_retryableReasonsAreHandledIdentically`() {
        for (reason in listOf(CloseReason.POOL_FULL, CloseReason.SHUTDOWN, CloseReason.INTERNAL, CloseReason.CLOSE_REASON_UNSPECIFIED)) {
            val h = Harness(random = 0.5)
            h.start()
            h.sessionThenClose(reason, detail = "", doWork = true)
            assertEquals("$reason", "reconnecting", h.status)
            assertEquals("$reason", 1, h.state.reconnectAttempts)
            assertEquals("$reason", 1, h.scheduler.pendingTimers)
            h.scheduler.advanceBy(500)
            assertEquals("$reason redials after the jitter delay", 2, h.transport.connections.size)
        }
    }

    @Test
    fun `SB41_poolFullWithRateLimitedDetailIsIndistinguishableFromOtherPressure`() {
        val full = Harness(random = 0.5).apply { start(); sessionThenClose(CloseReason.POOL_FULL, "rate_limited", doWork = true) }
        val internal = Harness(random = 0.5).apply { start(); sessionThenClose(CloseReason.INTERNAL, "", doWork = true) }
        assertEquals(full.status, internal.status)
        assertEquals(full.state.reconnectAttempts, internal.state.reconnectAttempts)
    }

    // ------------------------------------------------------------ SB-42/43

    @Test
    fun `SB42_delayIsFullJitterUpToThe30sCap`() {
        val h = Harness(random = 1.0)
        h.start()
        val expected = listOf(1000L, 2000L, 4000L, 8000L, 16000L, 30000L, 30000L)
        for ((i, ceiling) in expected.withIndex()) {
            h.conn.listener.onFailure(RuntimeException("down"))
            assertEquals(i + 1, h.state.reconnectAttempts)
            val sockets = h.transport.connections.size
            h.scheduler.advanceBy(ceiling - 1)
            assertEquals("not before $ceiling ms (attempt ${i + 1})", sockets, h.transport.connections.size)
            h.scheduler.advanceBy(1)
            assertEquals("at $ceiling ms (attempt ${i + 1})", sockets + 1, h.transport.connections.size)
        }
    }

    @Test
    fun `SB42_firstRetryMayBeImmediateAndNothingIsAdditive`() {
        val h = Harness(random = 0.0)
        h.start()
        h.conn.listener.onFailure(RuntimeException("down"))
        h.scheduler.advanceBy(0)
        assertEquals("random 0 means retry now, no base + jitter floor", 2, h.transport.connections.size)
    }

    @Test
    fun `SB42_delayDistributionIsFullJitterWithinTheWindow`() {
        val rnd = java.util.Random(7)
        val delays = List(1000) { SinchPushSocketClient.reconnectDelayMs(5) { rnd.nextDouble() } }
        val ceiling = SinchPushSocketClient.reconnectCeilingMs(5)
        assertEquals(16_000L, ceiling)
        assertTrue(delays.all { it in 0..ceiling })
        assertTrue(delays.max() > ceiling / 2)
        assertTrue(delays.count { it < ceiling / 10 } <= 250)
        assertEquals(30_000L, SinchPushSocketClient.reconnectCeilingMs(10_000))
    }

    @Test
    fun `SB43_noRedialInTheSameTickAfterAShed`() {
        val h = Harness(random = 0.5)
        h.start()
        h.sessionThenClose(CloseReason.POOL_FULL, doWork = true)
        h.scheduler.advanceBy(0)
        assertEquals("advancing the clock by zero opens no socket", 1, h.transport.connections.size)
        h.scheduler.advanceBy(499)
        assertEquals(1, h.transport.connections.size)
        h.scheduler.advanceBy(1)
        assertEquals(2, h.transport.connections.size)
    }

    // ------------------------------------------------------------ SB-44..46

    @Test
    fun `SB44_helloAckZeroesTheAttemptCount`() {
        val h = Harness(random = 0.0)
        h.start()
        repeat(3) {
            h.conn.listener.onFailure(RuntimeException("down"))
            h.scheduler.advanceBy(0)
        }
        assertEquals(3, h.state.reconnectAttempts)
        h.connect()
        assertEquals(0, h.state.reconnectAttempts)
    }

    @Test
    fun `SB45_helloAckThenPoolFullClimbsToTheCapInsteadOfRestartingAtOne`() {
        val h = Harness(random = 1.0)
        h.start()
        val expectedAttempts = listOf(1, 2, 3, 4, 5, 6, 7)
        val ceilings = listOf(1000L, 2000L, 4000L, 8000L, 16000L, 30000L, 30000L)
        for ((i, attempts) in expectedAttempts.withIndex()) {
            h.sessionThenClose(CloseReason.POOL_FULL) // HelloAck, no work, shed
            assertEquals(attempts, h.state.reconnectAttempts)
            h.scheduler.advanceBy(ceilings[i])
        }
    }

    @Test
    fun `SB45_forfeitIsKeyedOnTheReasonNotTheDetailString`() {
        val renamed = Harness(random = 1.0)
        renamed.start()
        renamed.sessionThenClose(CloseReason.POOL_FULL, detail = "budget_exhausted")
        renamed.reconnect(1000)
        renamed.sessionThenClose(CloseReason.POOL_FULL, detail = "budget_exhausted")
        assertEquals("detail renamed: still forfeits", 2, renamed.state.reconnectAttempts)

        val other = Harness(random = 1.0)
        other.start()
        other.sessionThenClose(CloseReason.INTERNAL, detail = "rate_limited")
        other.reconnect(1000)
        other.sessionThenClose(CloseReason.INTERNAL, detail = "rate_limited")
        assertEquals("a rate_limited detail on another reason does not forfeit", 1, other.state.reconnectAttempts)
    }

    @Test
    fun `SB45_forfeitRestoresTheRecordedCountItDoesNotInventOne`() {
        val h = Harness(random = 1.0)
        h.start()
        repeat(4) {
            h.conn.listener.onFailure(RuntimeException("down"))
            h.scheduler.advanceBy(30_000)
        }
        assertEquals(4, h.state.reconnectAttempts)
        h.connect()
        h.conn.serverSends(closeFrame(CloseReason.POOL_FULL, "rate_limited"))
        assertEquals("4 before the handshake, +1 for this denial", 5, h.state.reconnectAttempts)
    }

    @Test
    fun `SB44_healthyHandshakeStillStartsFromAttemptOne_theControl`() {
        val h = Harness(random = 1.0)
        h.start()
        repeat(4) {
            h.sessionThenClose(CloseReason.POOL_FULL, doWork = true)
            assertEquals("session did real work, so the reset was earned", 1, h.state.reconnectAttempts)
            h.scheduler.advanceBy(1000)
        }
    }

    @Test
    fun `SB46_aBarePollDoesNotSpendTheReset`() {
        val h = Harness(random = 1.0)
        h.start()
        h.connect()
        h.scheduler.advanceBy(20_000) // many polls, nothing drained
        h.conn.serverSends(closeFrame(CloseReason.POOL_FULL, "rate_limited"))
        h.scheduler.advanceBy(1000)
        h.sessionThenClose(CloseReason.POOL_FULL)
        assertEquals(2, h.state.reconnectAttempts)
    }

    @Test
    fun `SB46_anAcceptedReportAnswerSpendsTheReset`() {
        val h = Harness(testConfig(displayNotifications = false), random = 1.0)
        h.start()
        h.connect()
        h.client.reportStatus("m1", ReportStatus.DISMISSED)
        h.conn.serverSends(ackFor("m1", ReportStatus.DISMISSED, accepted = true))
        h.conn.serverSends(closeFrame(CloseReason.POOL_FULL, "rate_limited"))
        assertEquals(1, h.state.reconnectAttempts)
    }

    @Test
    fun `SB34_aRejectedAckDoesNotSpendTheResetOrCountAsHealthy`() {
        val h = Harness(testConfig(displayNotifications = false), random = 1.0)
        h.start()
        h.connect()
        h.client.reportStatus("m1", ReportStatus.DISMISSED)
        h.conn.serverSends(ackFor("m1", ReportStatus.DISMISSED, accepted = false, error = "rate_limited"))
        assertTrue(h.state.lastError!!.contains("rate_limited"))
        h.conn.serverSends(closeFrame(CloseReason.POOL_FULL, "rate_limited"))
        assertEquals("reset forfeited: the rejection was not work", 1, h.state.reconnectAttempts)
        h.scheduler.advanceBy(1000)
        h.sessionThenClose(CloseReason.POOL_FULL)
        assertEquals("climbs", 2, h.state.reconnectAttempts)
    }

    // ------------------------------------------------------------ SB-47..49

    @Test
    fun `SB47_staleReconnectsImmediatelyWithAFreshHelloAndNoTimerAndZeroAttempts`() {
        val h = Harness(random = 1.0)
        h.start()
        repeat(2) {
            h.conn.listener.onFailure(RuntimeException("down"))
            h.scheduler.advanceBy(30_000)
        }
        h.connect()
        val sockets = h.transport.connections.size
        h.conn.serverSends(closeFrame(CloseReason.STALE))
        assertEquals("a new socket is open by the time the call returns", sockets + 1, h.transport.connections.size)
        assertEquals(0, h.state.reconnectAttempts)
        assertEquals(0, h.scheduler.pendingTimers)
        h.conn.serverOpens()
        assertEquals(1, h.conn.hellos.size)
        assertNotEquals("not terminal", "stopped", h.status)
    }

    @Test
    fun `SB48_unauthorizedIsTerminalAuthRequiredAndAsksTheHostOnce`() {
        val h = Harness(random = 0.0)
        h.start()
        h.connect()
        val socket = h.conn
        h.conn.serverSends(closeFrame(CloseReason.UNAUTHORIZED, "token expired"))
        assertEquals("auth_required", h.status)
        assertEquals("token expired", h.state.lastError)
        assertEquals(1, h.authRequiredCalls)
        assertFalse(socket.closes.isEmpty())
        h.scheduler.advanceBy(10 * 60_000)
        assertEquals("never reconnects", 1, h.transport.connections.size)
        socket.listener.onClosed(1000, "late")
        assertEquals("trailing onClosed does not overwrite the state", "auth_required", h.status)
        assertEquals(0, h.scheduler.pendingTimers)
    }

    @Test
    fun `SB48_unauthorizedWithoutDetailUsesTheReasonForm`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSends(closeFrame(CloseReason.UNAUTHORIZED))
        assertEquals("server closed (reason=1)", h.state.lastError)
    }

    @Test
    fun `SB49_bgResumedStopsAsReplacedAndNeverReconnects`() {
        val h = Harness(random = 0.0)
        h.startAndConnect()
        val socket = h.conn
        h.conn.serverSends(closeFrame(CloseReason.BG_RESUMED))
        assertEquals("replaced", h.status)
        assertFalse(socket.closes.isEmpty())
        h.scheduler.advanceBy(10 * 60_000)
        assertEquals(1, h.transport.connections.size)
        assertEquals(0, h.scheduler.pendingTimers)
        assertEquals(0, h.authRequiredCalls)
    }

    // ------------------------------------------------------------ SB-50..53

    @Test
    fun `SB50_aFailureBeforeTheSocketEverConnectedIsRetryableFromAttemptOne`() {
        val h = Harness(random = 1.0)
        h.start()
        h.conn.listener.onFailure(java.net.SocketException("1006"))
        assertEquals("reconnecting", h.status)
        assertEquals(1, h.state.reconnectAttempts)
        h.scheduler.advanceBy(1000)
        assertEquals(2, h.transport.connections.size)
    }

    @Test
    fun `SB50_aThrowingConnectIsRetryableToo`() {
        val h = Harness(random = 1.0)
        h.transport.failNextConnect = IllegalStateException("tls")
        h.start()
        assertEquals("reconnecting", h.status)
        assertEquals(1, h.state.reconnectAttempts)
        h.scheduler.advanceBy(1000)
        assertEquals(1, h.transport.connections.size)
        h.conn.serverOpens()
        assertEquals(1, h.conn.hellos.size)
    }

    @Test
    fun `SB51_reconnectSchedulingIsIdempotentAndReplacedSocketsAreInert`() {
        val h = Harness(random = 1.0)
        h.start()
        val first = h.conn
        first.listener.onFailure(RuntimeException("a"))
        first.listener.onFailure(RuntimeException("b")) // same dead socket calling again
        first.listener.onClosed(1006, "c")
        assertEquals("one retry timer, one attempt", 1, h.scheduler.pendingTimers)
        assertEquals(1, h.state.reconnectAttempts)
        h.scheduler.advanceBy(1000)
        assertEquals(2, h.transport.connections.size)
    }

    @Test
    fun `SB51_staleSocketCallbacksAfterAReplacementAreIgnored`() {
        val h = Harness(random = 1.0)
        h.startAndConnect()
        val old = h.conn
        old.serverSends(closeFrame(CloseReason.STALE))
        val replacement = h.conn
        assertNotEquals(old, replacement)
        old.listener.onClosed(1000, "trailing")
        old.listener.onFailure(RuntimeException("trailing"))
        old.serverSends(pushMessage("ghost"))
        assertEquals(2, h.transport.connections.size)
        assertEquals(0, h.state.reconnectAttempts)
        assertTrue(h.messages.isEmpty())
        assertEquals(0, h.scheduler.pendingTimers)
    }

    @Test
    fun `SB51_theSocketIsClosedBeforeTheReferenceIsDropped`() {
        val h = Harness(random = 1.0)
        h.startAndConnect()
        val socket = h.conn
        socket.listener.onFailure(RuntimeException("half-dead"))
        assertEquals("the orphan is shut down, not just forgotten", 1, socket.closes.size)
    }

    @Test
    fun `SB52_shutdownIsRetryableAndTheNextSessionHasAFreshConnectionId`() {
        val h = Harness(random = 0.0)
        h.startAndConnect("conn-A")
        h.conn.serverSends(closeFrame(CloseReason.SHUTDOWN))
        assertNotEquals("no terminal latch", "stopped", h.status)
        assertNotEquals("error", h.status)
        h.scheduler.advanceBy(0)
        h.connect("conn-B")
        assertEquals("connected", h.status)
        assertEquals("conn-B", h.state.connectionId)
    }

    @Test
    fun `SB52_aBareSocketCloseWithoutACloseFrameAlsoRecovers`() {
        val h = Harness(random = 0.0)
        h.startAndConnect("conn-A")
        h.conn.listener.onClosed(1001, "going away")
        h.scheduler.advanceBy(0)
        h.connect("conn-B")
        assertEquals("conn-B", h.state.connectionId)
    }

    @Test
    fun `SB53_stopClearsPollAndReconnectTimersAndLeavesNothingThatCanOpenASocket`() {
        val h = Harness(random = 1.0)
        h.startAndConnect()
        h.conn.listener.onFailure(RuntimeException("down")) // reconnect pending
        assertEquals(1, h.scheduler.pendingTimers)
        h.client.stop()
        assertEquals("stopped", h.status)
        assertEquals(0, h.scheduler.pendingTimers)
        h.scheduler.advanceBy(120_000)
        assertEquals(1, h.transport.connections.size)
    }

    @Test
    fun `SB53_staleAndTerminalClosesCancelThePollTimerFirst`() {
        for (reason in listOf(CloseReason.UNAUTHORIZED, CloseReason.BG_RESUMED)) {
            val h = Harness()
            h.startAndConnect()
            assertEquals("poll timer armed", 1, h.scheduler.pendingTimers)
            h.conn.serverSends(closeFrame(reason))
            assertEquals("$reason", 0, h.scheduler.pendingTimers)
        }
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSends(closeFrame(CloseReason.STALE))
        assertEquals("STALE leaves no stale poll timer behind", 0, h.scheduler.pendingTimers)
    }
}
