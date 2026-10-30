package com.sinchpush.socket

import android.content.Context

/** One provider-push delivery report waiting to be flushed. */
internal data class ReportOutboxEntry(
    val messageId: String,
    val subscriberId: String,
    val enqueuedAtMs: Long,
)

/** Who is flushing: the leases below keep the two from sending the same entry. */
internal enum class ReportFlusher { NATIVE, JS }

/**
 * The provider-push reports waiting to be flushed, oldest first, persisted in
 * the socket state store; every method is synchronized.
 *
 * Two flushers share it: the JS flusher (through the bridge) and the native
 * uploader that runs on the FCM thread when no JS runtime is alive. Neither
 * deletes anything it was not acknowledged for, and a **lease** keeps them off
 * each other's entries: [claim] hands out only entries nobody else holds, so an
 * entry is on the wire from one flusher at a time. A lease is only in-memory
 * and only advisory; it expires on its own (a flusher that died holds nothing)
 * and [remove] ends it. A lost lease costs at worst a duplicate `DELIVERED`
 * report, never a lost one.
 */
internal class ReportOutbox(
    private val store: SocketStateStore,
    private val clock: Clock = SystemClock,
    private val capacity: Int = CAPACITY,
) {

    private val entries = ArrayDeque<ReportOutboxEntry>()

    private class Lease(val owner: ReportFlusher, val expiresAtMs: Long)

    private val leases = HashMap<Pair<String, String>, Lease>()

    /**
     * Every key queued in this process, kept after the entry is acknowledged and
     * removed: the FCM service sees one message twice when it is a
     * notification + data message in the foreground (`handleIntent` and
     * `onMessageReceived`), and the second sight must not queue a second report
     * for a delivery already reported.
     */
    private val handled = BoundedLru<Pair<String, String>, Boolean>(HANDLED_CAPACITY)

    init {
        store.loadReportOutbox().forEach {
            entries.addLast(it)
            handled.put(it.messageId to it.subscriberId, true)
        }
    }

    /**
     * Queues the report for `(messageId, subscriberId)`.
     *
     * @return the queued entry, or null when the key is already queued or was
     *   queued earlier in this process - a re-enqueue is a no-op and keeps the
     *   original stamp.
     */
    @Synchronized
    fun enqueue(messageId: String, subscriberId: String): ReportOutboxEntry? {
        if (messageId.isEmpty() || subscriberId.isEmpty()) return null
        val key = messageId to subscriberId
        if (!handled.put(key, true)) return null
        if (entries.any { it.messageId == messageId && it.subscriberId == subscriberId }) return null
        if (capacity > 0 && entries.size >= capacity) entries.removeFirst()
        val entry = ReportOutboxEntry(messageId, subscriberId, clock.nowMs())
        entries.addLast(entry)
        // Written through before this returns: the process can die right after an
        // FCM callback, and the store commits this key rather than applying it.
        store.saveReportOutbox(entries.toList())
        return entry
    }

    /** The queued entries, oldest first. */
    @Synchronized
    fun snapshot(): List<ReportOutboxEntry> = entries.toList()

    /**
     * Leases up to [max] entries, oldest first, that no other flusher holds, to
     * [owner] for [leaseMs]. Entries [owner] already holds are returned again and
     * their lease renewed, so a flusher that asks twice sees what it asked for.
     */
    @Synchronized
    fun claim(owner: ReportFlusher, leaseMs: Long, max: Int = Int.MAX_VALUE): List<ReportOutboxEntry> {
        val now = clock.nowMs()
        leases.values.removeAll { it.expiresAtMs <= now }
        val claimed = ArrayList<ReportOutboxEntry>()
        for (entry in entries) {
            if (claimed.size >= max) break
            val key = entry.messageId to entry.subscriberId
            val held = leases[key]
            if (held != null && held.owner != owner) continue
            leases[key] = Lease(owner, now + leaseMs)
            claimed.add(entry)
        }
        return claimed
    }

    /** Ends [owner]'s lease on [keys] without removing them: they go back to whoever asks next. */
    @Synchronized
    fun release(owner: ReportFlusher, keys: List<Pair<String, String>>) {
        for (key in keys) {
            if (leases[key]?.owner == owner) leases.remove(key)
        }
    }

    /**
     * Drops the entries named by [keys]; the rest keep their place. Naming an
     * entry that is already gone is a no-op, so two flushers acknowledging the
     * same entry cannot remove anything but that entry.
     */
    @Synchronized
    fun remove(keys: List<Pair<String, String>>) {
        if (keys.isEmpty()) return
        keys.forEach { leases.remove(it) }
        val dropped = entries.removeAll { entry ->
            keys.any { it.first == entry.messageId && it.second == entry.subscriberId }
        }
        if (dropped) store.saveReportOutbox(entries.toList())
    }

    /** Drops every queued entry. */
    @Synchronized
    fun clear() {
        entries.clear()
        leases.clear()
        store.saveReportOutbox(entries.toList())
    }

    companion object {
        /** The bound: the oldest entry is dropped when the outbox is full. */
        const val CAPACITY = 500

        /** Keys remembered after they are acknowledged; see [handled]. */
        const val HANDLED_CAPACITY = 1000
    }
}

/** The process-wide [ReportOutbox], shared by the FCM service and the bridge. */
internal object SharedReportOutbox {

    @Volatile private var instance: ReportOutbox? = null

    fun get(context: Context): ReportOutbox =
        getOrCreate { ReportOutbox(SharedPreferencesSocketStateStore(context)) }

    /** The instance, built by [factory] on first use only. */
    fun getOrCreate(factory: () -> ReportOutbox): ReportOutbox =
        instance ?: synchronized(this) {
            instance ?: factory().also { instance = it }
        }

    /** Test seam: install [outbox] (or clear with null) as the process-wide instance. */
    fun setForTesting(outbox: ReportOutbox?) {
        synchronized(this) { instance = outbox }
    }
}
