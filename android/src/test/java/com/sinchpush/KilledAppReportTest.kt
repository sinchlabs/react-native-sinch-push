package com.sinchpush

import com.sinchpush.socket.FakeClock
import com.sinchpush.socket.FakePrefsContext
import com.sinchpush.socket.FakeSharedPreferences
import com.sinchpush.socket.FileReportSessionStore
import com.sinchpush.socket.NativeReportUploader
import com.sinchpush.socket.ReportFlusher
import com.sinchpush.socket.ReportHttp
import com.sinchpush.socket.ReportHttpResponse
import com.sinchpush.socket.ReportOutbox
import com.sinchpush.socket.SeenSet
import com.sinchpush.socket.SharedPreferencesSocketStateStore
import com.sinchpush.socket.SharedReportSession
import java.io.File
import java.net.URL
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * SB-67: a push that reaches a killed app. FCM starts a new process for the
 * service; there is no React context, so the JS flusher never runs and the
 * report must leave natively, with the session an earlier process mirrored at
 * `setIdentity`. Every object here is built fresh from what is on disk, the way
 * a cold-started process sees it.
 */
class KilledAppReportTest {

    private lateinit var dir: File
    /** The app's SharedPreferences file: it outlives every process. */
    private val prefs = FakeSharedPreferences()
    private val clock = FakeClock()
    private val http = RecordingHttp()

    private val session = SharedReportSession("jwt-1", "https://push.example.com/", "u-1", "a-1")

    @Before
    fun makeDir() {
        dir = File(System.getProperty("java.io.tmpdir"), "sinch-killed-${System.nanoTime()}")
        dir.mkdirs()
    }

    @After
    fun removeDir() {
        dir.deleteRecursively()
    }

    private class RecordingHttp : ReportHttp {
        val authorizations = mutableListOf<String?>()
        var up = true

        override fun post(url: URL, headers: Map<String, String>, body: ByteArray, timeoutMs: Int): ReportHttpResponse? {
            authorizations.add(headers["authorization"])
            return if (up) ReportHttpResponse(200, "application/grpc-web+proto", "0", ByteArray(0)) else null
        }
    }

    /** A new process: nothing in memory, only what the previous one wrote. */
    private inner class Process {
        val store = SharedPreferencesSocketStateStore(FakePrefsContext(prefs))
        val outbox = ReportOutbox(store, clock)
        val sessions = FileReportSessionStore(dir)
        var jsNotified = 0

        /** `SinchPushFirebaseMessagingService.handleIntent` with no React context. */
        fun receivePush(messageId: String) = ProviderPushIntent(
            seen = SeenSet(store),
            outbox = outbox,
            onReportQueued = { jsNotified++ }, // SinchPushEmitter drops it: no React context.
            flush = { NativeReportUploader(outbox, sessions, http, clock).flush() },
            ensureChannel = {},
        ).handle(
            ProviderPushIntent.ACTION_RECEIVE,
            mapOf(PushDedupe.MESSAGE_ID_KEY to messageId, PushDedupe.SUBSCRIBER_ID_KEY to "s-1")::get,
        ) {}
    }

    @Test
    fun `SB67_aPushToAKilledAppIsReportedNativelyWithTheMirroredSession`() {
        // The app ran once: setIdentity mirrored the session, then the process died.
        FileReportSessionStore(dir).save(session)

        val fcm = Process()
        fcm.receivePush("m1")

        assertEquals("one upload, with the mirrored JWT", listOf<String?>("jwt-1"), http.authorizations)
        assertTrue(fcm.outbox.snapshot().isEmpty())

        // The user opens the app later: the JS flusher finds nothing to send twice.
        assertTrue(Process().outbox.claim(ReportFlusher.JS, leaseMs = 120_000).isEmpty())
    }

    @Test
    fun `SB67_aKilledAppOfflineLeavesTheReportForTheJsFlusherOnTheNextOpen`() {
        FileReportSessionStore(dir).save(session)
        http.up = false

        Process().receivePush("m1")

        // Next launch: the entry is on disk and not leased, so JS sends it.
        val claimed = Process().outbox.claim(ReportFlusher.JS, leaseMs = 120_000)
        assertEquals(listOf("m1" to "s-1"), claimed.map { it.messageId to it.subscriberId })
    }

    @Test
    fun `SB67_afterRemoveIdentityAKilledAppSendsNothing`() {
        FileReportSessionStore(dir).save(session)
        FileReportSessionStore(dir).clear() // removeIdentity

        val fcm = Process()
        fcm.receivePush("m1")

        assertTrue("no session, no upload", http.authorizations.isEmpty())
        assertEquals(1, fcm.outbox.snapshot().size)
    }

    @Test
    fun `SB67_theSamePushSeenAgainByANewProcessIsNotReportedTwice`() {
        FileReportSessionStore(dir).save(session)

        Process().receivePush("m1")
        Process().receivePush("m1") // FCM redelivery after the process was killed again

        assertEquals(1, http.authorizations.size)
    }
}
