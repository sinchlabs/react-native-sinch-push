package com.sinchpush.socket

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * RN-034 Part 1: what `reportPushMessageStatus` and `setSocketHandlerRegistered`
 * reach. The bridge methods are one-line adapters over these.
 */
class HostEntryPointTest {

    @Before
    fun reset() {
        SinchPushSocketStore.clear()
        SinchPushSocketStore.handlerRegistered = false
    }

    @After
    fun detach() = SinchPushSocketController.installClientForTest(null)

    @Test
    fun `reportFromHost rejects with NOT_RUNNING when there is no socket owner`() {
        SinchPushSocketController.installClientForTest(null)
        assertEquals(
            SinchPushSocketController.HostReport.NOT_RUNNING,
            SinchPushSocketController.reportFromHost("m1", "displayed"),
        )
    }

    @Test
    fun `reportFromHost rejects an unknown status even with an owner`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect()
        SinchPushSocketController.installClientForTest(h.client)
        for (bad in listOf("delivered", "failed", "", "nonsense")) {
            assertEquals(SinchPushSocketController.HostReport.INVALID_STATUS, SinchPushSocketController.reportFromHost("m1", bad))
        }
        assertEquals(SinchPushSocketController.HostReport.INVALID_STATUS, SinchPushSocketController.reportFromHost("m1", null))
        assertTrue(h.conn.reports.isEmpty())
    }

    @Test
    fun `reportFromHost sends DISPLAYED and DISMISSED through the owner`() {
        val h = Harness(testConfig(displayNotifications = false))
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))
        SinchPushSocketController.installClientForTest(h.client)
        assertEquals(SinchPushSocketController.HostReport.ACCEPTED, SinchPushSocketController.reportFromHost("m1", "displayed"))
        assertEquals(SinchPushSocketController.HostReport.ACCEPTED, SinchPushSocketController.reportFromHost("m1", "dismissed"))
        assertEquals(
            listOf(ReportStatus.DELIVERED.wire, ReportStatus.DISPLAYED.wire, ReportStatus.DISMISSED.wire),
            h.conn.reports.map { it.status },
        )
    }

    @Test
    fun `whenUnhandled posts without a handler and stays quiet with one`() {
        val quiet = Harness(testConfig(displayRule = DisplayRule.WHEN_UNHANDLED), handlerRegistered = true, appVisible = true)
        quiet.startAndConnect()
        quiet.conn.serverSends(pushMessage("m1"))
        assertTrue(quiet.notifications.shown.isEmpty())
        assertEquals(1, quiet.messages.size)

        val loud = Harness(testConfig(displayRule = DisplayRule.WHEN_UNHANDLED))
        loud.startAndConnect()
        loud.conn.serverSends(pushMessage("m2"))
        assertEquals(1, loud.notifications.shown.size)
        assertEquals(1, loud.conn.reports.count { it.status == ReportStatus.DISPLAYED.wire })
    }

    @Test
    fun `whenUnhandled reads the flag per message so a late handler takes effect`() {
        val h = Harness(testConfig(displayRule = DisplayRule.WHEN_UNHANDLED), appVisible = true)
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))
        h.handlerRegistered = true
        h.conn.serverSends(pushMessage("m2"))
        assertEquals(listOf("m1"), h.notifications.shown.map { it.id })
    }

    @Test
    fun `whenUnhandled posts in the background even with a handler`() {
        val h = Harness(testConfig(displayRule = DisplayRule.WHEN_UNHANDLED), handlerRegistered = true, appVisible = false)
        h.startAndConnect()
        h.conn.serverSends(pushMessage("m1"))
        h.appVisible = true
        h.conn.serverSends(pushMessage("m2"))
        assertEquals(listOf("m1"), h.notifications.shown.map { it.id })
    }

    @Test
    fun `always and never ignore the handler flag`() {
        val always = Harness(testConfig(displayRule = DisplayRule.ALWAYS), handlerRegistered = true)
        always.startAndConnect()
        always.conn.serverSends(pushMessage("m1"))
        assertEquals(1, always.notifications.shown.size)

        val never = Harness(testConfig(displayRule = DisplayRule.NEVER))
        never.startAndConnect()
        never.conn.serverSends(pushMessage("m1"))
        assertTrue(never.notifications.shown.isEmpty())
    }

    @Test
    fun `setHandlerRegistered writes the flag the dependencies read`() {
        SinchPushSocketController.setHandlerRegistered(true)
        assertTrue(SinchPushSocketStore.handlerRegistered)
        SinchPushSocketController.setHandlerRegistered(false)
        assertEquals(false, SinchPushSocketStore.handlerRegistered)
    }

    @Test
    fun `DisplayRule parses the JS spellings and defaults to whenUnhandled`() {
        assertEquals(DisplayRule.ALWAYS, DisplayRule.fromWire("always"))
        assertEquals(DisplayRule.NEVER, DisplayRule.fromWire("never"))
        assertEquals(DisplayRule.WHEN_UNHANDLED, DisplayRule.fromWire("whenUnhandled"))
        assertEquals(DisplayRule.WHEN_UNHANDLED, DisplayRule.fromWire(null))
        assertEquals(DisplayRule.WHEN_UNHANDLED, DisplayRule.fromWire("bogus"))
    }
}
