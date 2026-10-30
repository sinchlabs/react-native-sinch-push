package com.sinchpush

import com.sinchpush.socket.FakeClock
import com.sinchpush.socket.InMemorySocketStateStore
import com.sinchpush.socket.ReportOutbox
import com.sinchpush.socket.SeenSet
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** SB-67: which intents `handleIntent` records, and in what order. */
class ProviderPushIntentTest {

    private val seen = SeenSet(InMemorySocketStateStore())
    private val outbox = ReportOutbox(InMemorySocketStateStore(), FakeClock())
    private val steps = mutableListOf<String>()

    private val flow = ProviderPushIntent(
        seen = seen,
        outbox = outbox,
        onReportQueued = { steps.add("notify") },
        flush = { steps.add("flush") },
        ensureChannel = { steps.add("channel") },
    )

    private val receive = ProviderPushIntent.ACTION_RECEIVE

    private fun push(messageId: String? = "m1", subscriberId: String? = "s-1", vararg more: Pair<String, String>) =
        listOfNotNull(
            messageId?.let { PushDedupe.MESSAGE_ID_KEY to it },
            subscriberId?.let { PushDedupe.SUBSCRIBER_ID_KEY to it },
        ).plus(more)

    private fun handle(
        action: String? = receive,
        extras: List<Pair<String, String>>,
        superHandle: () -> Unit = { steps.add("super") },
    ) = flow.handle(action, extras.toMap()::get, superHandle)

    @Test
    fun `SB67_aMessageIsQueuedThenDisplayedThenMarkedSeenThenUploaded`() {
        var seenDuringSuper: Boolean? = null
        var queuedDuringSuper: Int? = null

        handle(extras = push()) {
            steps.add("super")
            seenDuringSuper = seen.contains("m1")
            queuedDuringSuper = outbox.snapshot().size
        }

        assertEquals(listOf("channel", "notify", "super", "flush"), steps)
        assertEquals("queued before the system displays it", 1, queuedDuringSuper)
        assertEquals("not seen while super runs, or onMessageReceived would drop it", false, seenDuringSuper)
        assertTrue("seen once super is done", seen.contains("m1"))
        assertEquals(listOf("m1" to "s-1"), outbox.snapshot().map { it.messageId to it.subscriberId })
    }

    @Test
    fun `SB67_aMessageTypeOfGcmIsAMessageToo`() {
        handle(extras = push(more = arrayOf("message_type" to "gcm")))

        assertEquals(1, outbox.snapshot().size)
    }

    @Test
    fun `SB67_tokenAndDeletedMessagesIntentsNeverQueue`() {
        handle(extras = push(more = arrayOf("message_type" to "deleted_messages")))
        handle(extras = push("m2", more = arrayOf("message_type" to "send_event")))
        handle(extras = push("m3", more = arrayOf("message_type" to "send_error")))
        handle(extras = listOf("message_type" to "deleted_messages"))

        assertTrue(outbox.snapshot().isEmpty())
        assertFalse(seen.contains("m1"))
        assertEquals("each one is still passed to super", List(4) { "super" }, steps)
    }

    @Test
    fun `SB67_anIntentThatIsNotTheC2dmReceiveActionNeverQueues`() {
        handle(action = "com.google.firebase.messaging.NEW_TOKEN", extras = push())
        handle(action = "com.google.android.c2dm.intent.REGISTRATION", extras = push("m2"))
        handle(action = null, extras = push("m3"))

        assertTrue(outbox.snapshot().isEmpty())
        assertTrue(seen.snapshot().isEmpty())
        assertEquals(listOf("super", "super", "super"), steps)
    }

    @Test
    fun `SB67_aMessageWithoutASubscriberIsMarkedSeenButNotReported`() {
        handle(extras = push(subscriberId = null))

        assertTrue(outbox.snapshot().isEmpty())
        assertTrue(seen.contains("m1"))
        assertEquals(listOf("channel", "super"), steps)
    }

    @Test
    fun `SB67_aMessageWithoutAnIdIsPassedThroughUntouched`() {
        handle(extras = push(messageId = null))
        handle(extras = push(messageId = ""))

        assertTrue(outbox.snapshot().isEmpty())
        assertTrue(seen.snapshot().isEmpty())
    }

    @Test
    fun `SB67_aMessageTheSocketAlreadyDeliveredIsNotReportedAgain`() {
        seen.add("m1")

        handle(extras = push())

        assertTrue(outbox.snapshot().isEmpty())
        assertEquals(listOf("channel", "super"), steps)
    }

    @Test
    fun `SB67_theSecondSightOfAQueuedMessageQueuesAndUploadsNothing`() {
        handle(extras = push())
        steps.clear()

        handle(extras = push())

        assertEquals(1, outbox.snapshot().size)
        assertEquals(listOf("channel", "super"), steps)
    }

    @Test
    fun `SB67_aFailureWhileQueueingStillLetsTheSystemDisplayTheMessage`() {
        val broken = ProviderPushIntent(
            seen = seen,
            outbox = outbox,
            onReportQueued = {},
            flush = {},
            ensureChannel = { throw IllegalStateException("no channel") },
        )

        broken.handle(receive, push().toMap()::get) { steps.add("super") }

        assertEquals(listOf("super"), steps)
        assertTrue("the message is still marked seen", seen.contains("m1"))
    }

    @Test
    fun `SB67_whenSuperThrowsTheBookkeepingStillRunsAndTheErrorPropagates`() {
        try {
            handle(extras = push()) { throw IllegalStateException("boom") }
            fail("super's exception is not swallowed")
        } catch (e: IllegalStateException) {
            assertEquals("boom", e.message)
        }

        assertTrue(seen.contains("m1"))
        assertEquals(listOf("channel", "notify", "flush"), steps)
    }

    @Test
    fun `SB67_aFailingUploadDoesNotEscape`() {
        val failing = ProviderPushIntent(seen, outbox, onReportQueued = {}, flush = { throw RuntimeException("net") })

        failing.handle(receive, push().toMap()::get) { steps.add("super") }

        assertEquals(listOf("super"), steps)
        assertEquals("the report stays queued for the JS flusher", 1, outbox.snapshot().size)
    }

    @Test
    fun `SB67_theMessageActionAndTypeRules`() {
        assertTrue(ProviderPushIntent.isMessage(receive, null))
        assertTrue(ProviderPushIntent.isMessage(receive, "gcm"))
        assertFalse(ProviderPushIntent.isMessage(receive, "deleted_messages"))
        assertFalse(ProviderPushIntent.isMessage(receive, "GCM"))
        assertFalse(ProviderPushIntent.isMessage(null, null))
        assertFalse(ProviderPushIntent.isMessage("x", "gcm"))
    }
}
