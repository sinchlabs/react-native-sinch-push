package com.sinchpush.socket

import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/**
 * The persisted Sinch message id map of the socket state store (SB-31).
 *
 * The map pairs a pooled `message_id` with the id of the message it came from,
 * so a report the host triggers long after the delivery can name the Sinch
 * message. It has to survive a process restart, which means the writer and the
 * reader have to agree on the record format.
 */
class SocketStateStoreSinchIdsTest {
    private lateinit var prefs: FakeSharedPreferences
    private lateinit var store: SharedPreferencesSocketStateStore

    @Before
    fun setUp() {
        prefs = FakeSharedPreferences()
        store = SharedPreferencesSocketStateStore(FakePrefsContext(prefs))
    }

    @Test
    fun `SB31_sinchMessageIdsRoundTripThroughThePreferencesStore`() {
        store.saveSinchMessageIds(mapOf("pooled-1" to "sinch-1", "pooled-2" to "sinch-2"))

        assertEquals(mapOf("pooled-1" to "sinch-1", "pooled-2" to "sinch-2"), store.loadSinchMessageIds())
    }

    @Test
    fun `SB31_aRecordWrittenByAnOlderBuildStillDecodes`() {
        // The legacy record shape: an empty first field, then the pair.
        prefs.edit().putString("sinch_message_ids", "\u001Fpooled-1\u001Fsinch-1\u001Epooled-2\u001Fsinch-2\u001E").commit()

        assertEquals(mapOf("pooled-1" to "sinch-1", "pooled-2" to "sinch-2"), store.loadSinchMessageIds())
    }
}
