package com.sinchpush.socket

import android.content.Context

/**
 * Everything about the delivery channel that has to survive a process restart.
 *
 * The seen set, the report sent-set, the report outbox and
 * `last_seen_message_id` are the four things that are worthless in memory on
 * Android, where the foreground service is killed and restarted by the OS as a
 * matter of course (SB-55).
 *
 * **The auth token is deliberately not here.** The token is credential material
 * and is moving into `EncryptedSharedPreferences`; this store is plain
 * `SharedPreferences` until then and must not become a second place the token
 * lands. Message ids are not credentials: they are already visible to the relay
 * and to the host app.
 */
internal interface SocketStateStore {

    /** Processed `message_id`s, oldest first (SB-28). */
    fun loadSeen(): List<String>

    fun saveSeen(ids: List<String>)

    /**
     * The `(message_id, status)` keys already reported, as Ack correlation
     * tokens `"<message_id>:<status>"` (SB-30).
     *
     * Keys rather than whole reports on purpose: the set is what has to survive,
     * and a reload must not be able to re-send something the relay already took.
     */
    fun loadSentKeys(): List<String>

    fun saveSentKeys(keys: List<String>)

    /** Reports that could not be sent, oldest first (SB-35). */
    fun loadOutbox(): List<PendingReport>

    fun saveOutbox(entries: List<PendingReport>)

    /** Newest processed `message_id`, for `Hello.last_seen_message_id` (SB-29). */
    fun loadLastSeenMessageId(): String

    fun saveLastSeenMessageId(id: String)

    /**
     * `enqueued_at_unix_millis` of the message [loadLastSeenMessageId] names, 0
     * when unknown. It is what keeps an older replayed message from moving the
     * cursor back (SB-29).
     */
    fun loadLastSeenEnqueuedAtMs(): Long

    fun saveLastSeenEnqueuedAtMs(ms: Long)

    /** Both cursor halves in one write; a real store commits them together (SB-29). */
    fun saveLastSeen(id: String, enqueuedAtMs: Long) {
        saveLastSeenMessageId(id)
        saveLastSeenEnqueuedAtMs(enqueuedAtMs)
    }

    /** Pooled id -> the original message's id, for reports the host triggers. */
    fun loadSinchMessageIds(): Map<String, String>

    fun saveSinchMessageIds(ids: Map<String, String>)

    /** Provider-push reports waiting to be flushed, oldest first. */
    fun loadReportOutbox(): List<ReportOutboxEntry>

    fun saveReportOutbox(entries: List<ReportOutboxEntry>)
}

/**
 * The in-memory implementation every JVM test uses.
 *
 * Backed by a map rather than by Android's `SharedPreferences` so the whole
 * client can be exercised off-device; the semantics that matter (persistence
 * across a client restart, bounded contents, no token) are the same ones the
 * production store has to hold.
 */
internal class InMemorySocketStateStore : SocketStateStore {

    @Volatile private var seen: List<String> = emptyList()
    @Volatile private var sentKeys: List<String> = emptyList()
    @Volatile private var outbox: List<PendingReport> = emptyList()
    @Volatile private var lastSeenMessageId: String = ""
    @Volatile private var lastSeenEnqueuedAtMs: Long = 0L
    @Volatile private var sinchMessageIds: Map<String, String> = emptyMap()
    @Volatile private var reportOutbox: List<ReportOutboxEntry> = emptyList()

    /** Counts the writes, so a test can prove the state is persisted, not cached. */
    @Volatile var saveCount: Int = 0
        private set

    override fun loadSeen(): List<String> = seen

    override fun saveSeen(ids: List<String>) {
        seen = ids
        saveCount++
    }

    override fun loadSentKeys(): List<String> = sentKeys

    override fun saveSentKeys(keys: List<String>) {
        sentKeys = keys
        saveCount++
    }

    override fun loadOutbox(): List<PendingReport> = outbox

    override fun saveOutbox(entries: List<PendingReport>) {
        outbox = entries
        saveCount++
    }

    override fun loadLastSeenMessageId(): String = lastSeenMessageId

    override fun saveLastSeenMessageId(id: String) {
        lastSeenMessageId = id
        saveCount++
    }

    override fun loadLastSeenEnqueuedAtMs(): Long = lastSeenEnqueuedAtMs

    override fun saveLastSeenEnqueuedAtMs(ms: Long) {
        lastSeenEnqueuedAtMs = ms
        saveCount++
    }

    override fun loadSinchMessageIds(): Map<String, String> = sinchMessageIds

    override fun saveSinchMessageIds(ids: Map<String, String>) {
        sinchMessageIds = ids
        saveCount++
    }

    override fun loadReportOutbox(): List<ReportOutboxEntry> = reportOutbox

    override fun saveReportOutbox(entries: List<ReportOutboxEntry>) {
        reportOutbox = entries
        saveCount++
    }
}

/**
 * `SharedPreferences` implementation of [SocketStateStore].
 *
 * Plain on purpose: this is swapped for `EncryptedSharedPreferences` (and the
 * existing plaintext preferences migrated), which is why the store is an
 * interface rather than a pile of static calls. Nothing secret is written here -
 * see the interface comment - so the window in which this is readable by a
 * rooted device is the same one `SharedPreferences` already has for the rest of
 * the SDK, and closing it does not require re-plumbing the client.
 *
 * Every write is `apply()`, never `commit()`: none of these are on a path the
 * caller waits on, and the socket callback thread must not block on disk. The one
 * exception is [saveReportOutbox], which the FCM thread writes right before the
 * process may die.
 */
internal class SharedPreferencesSocketStateStore(context: Context) : SocketStateStore {

    private val prefs = context.applicationContext
        .getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    override fun loadSeen(): List<String> = prefs.getString(KEY_SEEN, null).decodeList()

    override fun saveSeen(ids: List<String>) {
        prefs.edit().putString(KEY_SEEN, ids.encodeList()).apply()
    }

    override fun loadSentKeys(): List<String> = prefs.getString(KEY_SENT, null).decodeList()

    override fun saveSentKeys(keys: List<String>) {
        prefs.edit().putString(KEY_SENT, keys.encodeList()).apply()
    }

    override fun loadOutbox(): List<PendingReport> =
        OutboxCodec.decode(prefs.getString(KEY_OUTBOX, null).orEmpty())

    override fun saveOutbox(entries: List<PendingReport>) {
        prefs.edit().putString(KEY_OUTBOX, OutboxCodec.encode(entries)).apply()
    }

    override fun loadLastSeenMessageId(): String = prefs.getString(KEY_LAST_SEEN, "").orEmpty()

    override fun saveLastSeenMessageId(id: String) {
        prefs.edit().putString(KEY_LAST_SEEN, id).apply()
    }

    override fun loadLastSeenEnqueuedAtMs(): Long = prefs.getLong(KEY_LAST_SEEN_ENQUEUED_AT, 0L)

    override fun saveLastSeenEnqueuedAtMs(ms: Long) {
        prefs.edit().putLong(KEY_LAST_SEEN_ENQUEUED_AT, ms).apply()
    }

    override fun saveLastSeen(id: String, enqueuedAtMs: Long) {
        prefs.edit().putString(KEY_LAST_SEEN, id).putLong(KEY_LAST_SEEN_ENQUEUED_AT, enqueuedAtMs).apply()
    }

    override fun loadSinchMessageIds(): Map<String, String> =
        prefs.getString(KEY_SINCH_IDS, null).decodeList().associatePairs()

    override fun saveSinchMessageIds(ids: Map<String, String>) {
        prefs.edit().putString(KEY_SINCH_IDS, ids.map { (k, v) -> "$k$FIELD_SEP$v" }.joinToString(RECORD_SEP)).apply()
    }

    override fun loadReportOutbox(): List<ReportOutboxEntry> =
        decodeReportOutbox(prefs.getString(KEY_REPORT_OUTBOX, null).orEmpty())

    /**
     * `commit()`, not `apply()`: the FCM callback that queues a report can be the
     * last thing the process does, and an `apply()` still in flight is lost with
     * it. Callers are the FCM thread and the bridge, never the socket thread.
     */
    override fun saveReportOutbox(entries: List<ReportOutboxEntry>) {
        prefs.edit().putString(KEY_REPORT_OUTBOX, encodeReportOutbox(entries)).commit()
    }

    private fun encodeReportOutbox(entries: List<ReportOutboxEntry>): String =
        entries.joinToString(RECORD_SEP) { entry ->
            listOf(entry.messageId, entry.subscriberId, entry.enqueuedAtMs.toString())
                .joinToString(FIELD_SEP)
        }

    /** A record that cannot be read is dropped rather than thrown on. */
    private fun decodeReportOutbox(text: String): List<ReportOutboxEntry> {
        if (text.isEmpty()) return emptyList()
        return text.split(RECORD_SEP).mapNotNull { record ->
            if (record.isEmpty()) return@mapNotNull null
            val fields = record.split(FIELD_SEP)
            if (fields.size < 3) return@mapNotNull null
            if (fields[0].isEmpty()) return@mapNotNull null
            ReportOutboxEntry(fields[0], fields[1], fields[2].toLongOrNull() ?: 0L)
        }
    }

    /**
     * The pairs of the records [saveSinchMessageIds] wrote.
     *
     * A record written by an older build carries an empty first field, so the
     * pair sits in the last two fields of it; both shapes decode to the same
     * map.
     */
    private fun List<String>.associatePairs(): Map<String, String> =
        mapNotNull { line ->
            val parts = line.split(FIELD_SEP)
            when {
                parts.size >= 3 && parts[0].isEmpty() -> parts[1] to parts[2]
                parts.size >= 2 -> parts[0] to parts[1]
                else -> null
            }
        }.toMap()

    private fun List<String>.encodeList(): String = joinToString(RECORD_SEP)

    private fun String?.decodeList(): List<String> =
        if (this.isNullOrEmpty()) emptyList() else split(RECORD_SEP).filter { it.isNotEmpty() }

    companion object {
        /**
         * A separate preferences file from `PushSocketConfig`'s, so *this* file
         * can move to `EncryptedSharedPreferences` without dragging the config's
         * migration (and its token) along with it.
         */
        const val PREFS = "sinch_push_socket_state"

        private const val KEY_SEEN = "seen"
        private const val KEY_SENT = "sent_keys"
        private const val KEY_OUTBOX = "outbox"
        private const val KEY_LAST_SEEN = "last_seen_message_id"
        private const val KEY_LAST_SEEN_ENQUEUED_AT = "last_seen_enqueued_at_ms"
        private const val KEY_SINCH_IDS = "sinch_message_ids"
        private const val KEY_REPORT_OUTBOX = "report_outbox"

        /** ASCII record/unit separators: they cannot occur in a proto string id. */
        private const val RECORD_SEP = "\u001E"
        private const val FIELD_SEP = "\u001F"
    }
}