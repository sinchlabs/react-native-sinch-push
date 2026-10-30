package com.sinchpush.socket

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The transport callbacks arrive on OkHttp's thread; the client's state belongs
 * to the scheduler's thread (SB-51).
 *
 * Every callback is therefore hopped onto the scheduler and checked against
 * its epoch there, so the client's own ordering - one thread, one order - holds
 * whichever thread the relay's socket speaks on.
 */
class TransportCallbackSchedulingTest {

    @Test
    fun `SB51_anOpenCallbackIsHandledOnTheScheduler`() {
        val h = Harness()
        h.scheduler.deferExecute = true
        h.start()
        h.scheduler.drain()
        val conn = h.conn

        conn.serverOpens()

        assertTrue("nothing is sent before the scheduler runs", conn.sentBytes.isEmpty())
        h.scheduler.drain()
        assertEquals(1, conn.hellos.size)
    }

    @Test
    fun `SB51_anInboundFrameIsHandledOnTheScheduler`() {
        val h = Harness()
        h.scheduler.deferExecute = true
        h.start()
        h.scheduler.drain()
        val conn = h.conn
        conn.serverOpens()
        h.scheduler.drain()

        conn.serverSends(pushMessage("m-1"))

        assertTrue("no message is delivered before the scheduler runs", h.messages.isEmpty())
        h.scheduler.drain()
        assertEquals(1, h.messages.size)
        assertEquals("m-1", h.messages.single().id)
    }

    @Test
    fun `SB51_aCallbackFromARetiredEpochIsIgnored`() {
        val h = Harness()
        h.scheduler.deferExecute = true
        h.start()
        h.scheduler.drain()
        val conn = h.conn
        conn.serverOpens()
        h.scheduler.drain()

        // The frame arrives while this attempt is still the live one, and the
        // stop retires the attempt before the scheduler runs the callback.
        conn.serverSends(pushMessage("m-2"))
        h.scheduler.deferExecute = false
        h.client.stop()
        h.scheduler.deferExecute = true
        h.scheduler.drain()

        assertTrue("a callback from a retired epoch changes nothing", h.messages.isEmpty())
        assertEquals(1, conn.hellos.size)
    }
}
