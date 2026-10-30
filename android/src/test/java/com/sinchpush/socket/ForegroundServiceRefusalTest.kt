package com.sinchpush.socket

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * SB-60: what a refused foreground-service start does at the controller, with
 * the service starter as a seam. `Context` and the React emitter are not needed.
 * The service's own `startForeground` / `onTimeout` paths need an instrumented
 * test on API 31/34/35 and are not covered here.
 */
class ForegroundServiceRefusalTest {

    private val emitted = mutableListOf<SinchPushSocketStore.SocketState>()

    @Before
    fun setUp() {
        SocketServiceState.resetForTest()
        SinchPushSocketStore.clear()
        SinchPushSocketController.setStateSinkForTest { emitted.add(it) }
    }

    @After
    fun tearDown() {
        SinchPushSocketController.setStateSinkForTest(null)
        SinchPushSocketController.installClientForTest(null)
        SocketServiceState.resetForTest()
    }

    private fun refusal() = ForegroundServiceRefusedException(
        IllegalStateException("startForegroundService() not allowed due to mAllowStartForeground false"),
    )

    @Test
    fun `SB60_aRefusedServiceStartPublishesAnErrorStateAndRethrows`() {
        val refused = refusal()
        var inProcessStarted = false

        try {
            SinchPushSocketController.start(
                testConfig(backgroundService = true),
                startService = { throw refused },
                startInProcess = { inProcessStarted = true },
            )
            fail("a refused start must propagate so the bridge can reject")
        } catch (e: ForegroundServiceRefusedException) {
            assertSame(refused, e)
        }

        assertFalse("no in-process fallback: one owner only (SB-54)", inProcessStarted)
        val expected = "foreground service start refused: IllegalStateException: " +
            "startForegroundService() not allowed due to mAllowStartForeground false"
        val stored = SinchPushSocketStore.state()
        assertEquals("error", stored.status)
        assertEquals(expected, stored.lastError)
        assertEquals(0, stored.reconnectAttempts)
        assertNull(stored.connectionId)
        assertEquals("the refusal is the only emission - no connecting is emitted", stored, emitted.single())
    }

    @Test
    fun `SB60_aSuccessfulServiceStartLeavesTheConnectingStateAlone`() {
        SinchPushSocketController.start(
            testConfig(backgroundService = true),
            startService = {},
            startInProcess = { fail("service owner expected") },
        )
        assertEquals("connecting", SinchPushSocketStore.state().status)
        assertTrue(emitted.isEmpty())
    }

    @Test
    fun `SB60_inProcessModeNeverTouchesTheServiceStarter`() {
        var inProcessStarted = false
        SinchPushSocketController.start(
            testConfig(backgroundService = false),
            startService = { fail("in-process mode must not start the service") },
            startInProcess = { inProcessStarted = true },
        )
        assertTrue(inProcessStarted)
    }

    @Test
    fun `SB60_aServiceSideFailurePublishesTheErrorStateKeepingThePollInterval`() {
        SinchPushSocketStore.setState(
            SinchPushSocketStore.SocketState("connecting", null, 15_000, 3, null),
        )

        SinchPushSocketController.publishServiceError(SinchPushSocketService.FOREGROUND_TIMEOUT_REASON)

        val stored = SinchPushSocketStore.state()
        assertEquals("error", stored.status)
        assertEquals("foreground service timeout", stored.lastError)
        assertEquals(0, stored.reconnectAttempts)
        assertEquals(15_000, stored.pollIntervalMs)
        assertEquals(stored, emitted.single())
    }

    @Test
    fun `SB60_theReasonNamesTheExceptionClassAndMessage`() {
        assertEquals(
            "foreground service start refused: SecurityException: no FGS permission",
            ForegroundServiceRefusedException.reasonFor(SecurityException("no FGS permission")),
        )
    }

    /**
     * `startForegroundService` returns the `ComponentName` it started, and
     * `null` means the platform started nothing. Nothing is thrown, so this used
     * to fail silently: JS sat in "connecting" for a socket that would never
     * open. It is the same refusal as the exception, from the same seam.
     */
    @Test
    fun `SB60_aStartThatStartedNoComponentIsARefusalAndNotASilentSuccess`() {
        var saved = false

        val refusal = try {
            SinchPushSocketService.start(
                saveConfig = { saved = true },
                startPlatform = { null },
            )
            null
        } catch (e: ForegroundServiceRefusedException) {
            e
        }

        assertTrue("the platform started nothing", saved)
        assertEquals(
            "foreground service start refused: IllegalStateException: " +
                SinchPushSocketService.NO_COMPONENT_REASON,
            refusal?.message,
        )
        // The same record a thrown refusal leaves, for the same diagnostics.
        assertEquals(
            "IllegalStateException: " + SinchPushSocketService.NO_COMPONENT_REASON,
            SocketServiceState.lastStartFailure,
        )
    }

    private fun errored(reason: String) = SinchPushSocketStore.state().let {
        assertEquals("error", it.status)
        assertEquals(reason, it.lastError)
        it
    }

    @Test
    fun `SB60_aTimeoutErrorIsNotOverwrittenByTheClientsAsyncStopped`() {
        val h = Harness()
        h.scheduler.deferExecute = true
        h.client.start()
        h.scheduler.drain()
        h.connect()
        SinchPushSocketController.installClientWithControllerListenerForTest(h.client)
        emitted.clear()

        SinchPushSocketController.onServiceTimeout()
        h.scheduler.drain()

        assertEquals("foreground service timeout", emitted.last().lastError)
        assertEquals("error", emitted.last().status)
        errored("foreground service timeout")
        assertFalse(SinchPushSocketController.isActive())
    }

    @Test
    fun `SB60_aPromotionRefusalErrorIsNotOverwrittenByTheClientsAsyncStopped`() {
        val h = Harness()
        h.scheduler.deferExecute = true
        h.client.start()
        h.scheduler.drain()
        h.connect()
        SinchPushSocketController.installClientWithControllerListenerForTest(h.client)
        emitted.clear()

        SinchPushSocketController.onServicePromotionRefused(SecurityException("no FGS permission"))
        h.scheduler.drain()

        val reason = "foreground service start refused: SecurityException: no FGS permission"
        assertEquals("error", emitted.last().status)
        assertEquals(reason, emitted.last().lastError)
        errored(reason)
    }

    @Test
    fun `SB60_aStopThenARefusedStartKeepsTheRefusalAsTheLastState`() {
        val h = Harness()
        h.scheduler.deferExecute = true
        h.client.start()
        h.scheduler.drain()
        h.connect()
        SinchPushSocketController.installClientWithControllerListenerForTest(h.client)
        emitted.clear()

        SinchPushSocketController.stopClient() // stopPushSocket: stop queued, not yet run
        try {
            SinchPushSocketController.start(
                testConfig(backgroundService = true),
                startService = { throw refusal() },
                startInProcess = { fail("service owner expected") },
            )
            fail("a refused start must propagate")
        } catch (_: ForegroundServiceRefusedException) {
        }
        h.scheduler.drain() // the previous client's `stopped` lands now

        assertEquals("error", emitted.last().status)
        assertTrue(emitted.last().lastError!!.startsWith("foreground service start refused"))
    }

    @Test
    fun `SB60_aClientInstalledAfterATimeoutIsNotMuted`() {
        val h = Harness()
        h.scheduler.deferExecute = true
        h.client.start()
        h.scheduler.drain()
        h.connect()
        SinchPushSocketController.installClientWithControllerListenerForTest(h.client)
        SinchPushSocketController.onServiceTimeout()
        h.scheduler.drain()
        emitted.clear()

        val h2 = Harness()
        h2.client.start()
        SinchPushSocketController.installClientWithControllerListenerForTest(h2.client)
        h2.connect()

        assertEquals("connected", SinchPushSocketStore.state().status)
        assertEquals("connected", emitted.last().status)
        assertTrue(SinchPushSocketController.isActive())
    }
}
