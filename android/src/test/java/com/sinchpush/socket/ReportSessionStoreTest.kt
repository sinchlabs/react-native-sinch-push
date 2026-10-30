package com.sinchpush.socket

import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** SB-67: the mirrored JWT lives in one file outside Auto Backup, and the first version's prefs are emptied. */
class ReportSessionStoreTest {

    private lateinit var dir: File
    private val session = SharedReportSession("t.o.k", "https://h.example.com", "u", "a")

    @Before
    fun makeDir() {
        dir = File(System.getProperty("java.io.tmpdir"), "sinch-session-${System.nanoTime()}")
        dir.mkdirs()
    }

    @After
    fun removeDir() {
        dir.deleteRecursively()
    }

    @Test
    fun `SB67_aSavedSessionIsLoadedAgainByANewStore`() {
        assertNull(FileReportSessionStore(dir).load())

        assertTrue(FileReportSessionStore(dir).save(session))

        assertEquals(session, FileReportSessionStore(dir).load())
    }

    @Test
    fun `SB67_saveReplacesAndLeavesNoTempFile`() {
        val store = FileReportSessionStore(dir)
        store.save(session)
        val newer = session.copy(accessToken = "n.e.w", userId = "")

        assertTrue(store.save(newer))

        assertEquals(newer, store.load())
        assertEquals(listOf(FileReportSessionStore.FILE_NAME), dir.list()!!.toList())
    }

    @Test
    fun `SB67_valuesWithSpecialCharactersSurviveTheFile`() {
        val odd = SharedReportSession("a=b:c\\d eé", "https://h/p?x=1#y", "u\nv", "")
        FileReportSessionStore(dir).save(odd)

        assertEquals(odd, FileReportSessionStore(dir).load())
    }

    @Test
    fun `SB67_clearRemovesTheFile`() {
        val store = FileReportSessionStore(dir)
        store.save(session)

        assertTrue(store.clear())

        assertNull(FileReportSessionStore(dir).load())
        assertTrue(dir.list()!!.isEmpty())
        assertTrue("clearing nothing is fine", store.clear())
    }

    @Test
    fun `SB67_aCorruptFileIsNoSession`() {
        File(dir, FileReportSessionStore.FILE_NAME).writeText("access_token=\\uZZZZ")
        assertNull(FileReportSessionStore(dir).load())

        File(dir, FileReportSessionStore.FILE_NAME).writeBytes(byteArrayOf(0, 1, 2))
        assertNull(FileReportSessionStore(dir).load())
    }

    @Test
    fun `SB67_aRecordInTheOldPreferencesMovesToTheFileAndTheOldOneIsEmptied`() {
        val prefs = FakeSharedPreferences()
        prefs.edit().putString("access_token", "old.t.k").putString("report_base_url", "https://old")
            .putString("user_id", "u").putString("app_id", "a").commit()
        var fileDeleted = false

        val store = FileReportSessionStore(dir, prefs) { fileDeleted = true }

        assertEquals(SharedReportSession("old.t.k", "https://old", "u", "a"), store.load())
        assertTrue("the token no longer sits in a backed-up file", prefs.all.isEmpty())
        assertTrue(fileDeleted)
        assertEquals(SharedReportSession("old.t.k", "https://old", "u", "a"), FileReportSessionStore(dir).load())
    }

    @Test
    fun `SB67_theFileWinsOverAnOldPreferencesRecord`() {
        val prefs = FakeSharedPreferences()
        prefs.edit().putString("access_token", "old").putString("report_base_url", "https://old").commit()
        FileReportSessionStore(dir).save(session)

        assertEquals(session, FileReportSessionStore(dir, prefs).load())
        assertTrue(prefs.all.isEmpty())
    }

    @Test
    fun `SB67_saveAndClearAlsoEmptyTheOldPreferences`() {
        val prefs = FakeSharedPreferences()
        prefs.edit().putString("access_token", "old").putString("report_base_url", "https://old").commit()
        FileReportSessionStore(dir, prefs).save(session)
        assertTrue(prefs.all.isEmpty())

        prefs.edit().putString("access_token", "old").commit()
        FileReportSessionStore(dir, prefs).clear()
        assertTrue(prefs.all.isEmpty())
        assertFalse(File(dir, FileReportSessionStore.FILE_NAME).exists())
    }

    @Test
    fun `SB67_aClearThroughOneStoreIsNotUndoneByALaterLoadThroughAnother`() {
        val prefs = FakeSharedPreferences()
        prefs.edit().putString("access_token", "old.t.k").putString("report_base_url", "https://old").commit()

        // JS logs out (its own store instance) while the FCM thread's has not loaded yet.
        assertTrue(FileReportSessionStore(dir, prefs).clear())

        assertNull(FileReportSessionStore(dir, prefs).load())
        assertFalse(File(dir, FileReportSessionStore.FILE_NAME).exists())
    }

    @Test
    fun `SB67_storeInstancesOfOneProcessSerializeAgainstEachOther`() {
        val prefs = FakeSharedPreferences()
        prefs.edit().putString("access_token", "old.t.k").putString("report_base_url", "https://old").commit()
        val newer = session.copy(accessToken = "n.e.w")
        val failures = java.util.concurrent.atomic.AtomicInteger()
        val start = java.util.concurrent.CountDownLatch(1)

        val threads = (1..8).map { i ->
            Thread {
                start.await()
                repeat(50) {
                    val store = FileReportSessionStore(dir, prefs)
                    val ok = when (i % 3) {
                        0 -> store.save(newer)
                        1 -> store.load().let { true }
                        else -> store.save(session)
                    }
                    if (!ok) failures.incrementAndGet()
                }
            }.also { it.start() }
        }
        start.countDown()
        threads.forEach { it.join() }

        assertEquals(0, failures.get())
        val loaded = FileReportSessionStore(dir).load()
        assertTrue(loaded == session || loaded == newer)
        assertEquals(listOf(FileReportSessionStore.FILE_NAME), dir.list()!!.toList())
    }
}
