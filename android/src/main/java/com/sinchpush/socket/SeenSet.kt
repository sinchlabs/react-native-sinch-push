package com.sinchpush.socket

import android.content.Context

/**
 * The bounded, persisted set of processed `message_id`s (SB-28).
 *
 * One instance per process ([SharedSeenSet]) is shared by the socket client (the
 * foreground service or the in-process client) and the FCM service, so every
 * method is synchronized: the socket thread, FCM's binder thread and the
 * host's main thread all reach it.
 *
 * Two things the previous `linkedSetOf` was not:
 *
 *  - **bounded** - an unbounded set of message ids in a foreground service that
 *    runs for days is a slow leak, and the cost of the bound is exactly the
 *    documented one: an evicted id can be re-delivered and re-reported;
 *  - **persisted** - the service is restarted by the OS (SB-55), and a dedupe
 *    set that empties on restart turns every message the relay re-offers into a
 *    second presentation; whether a `DELIVERED` report is sent twice is
 *    [ReportTracker]'s decision, not this set's.
 *
 * The key is `PooledMessage.message_id` and never `Message.ack_token` (SB-25).
 */
internal class SeenSet(
    private val store: SocketStateStore,
    private val capacity: Int = SocketSpec.SEEN_SET_CAPACITY,
) {

    private val ids = BoundedLru<String, Boolean>(capacity).apply {
        // Restored oldest-first, so a reload keeps the eviction order rather than
        // treating the whole set as new.
        store.loadSeen().forEach { put(it, true) }
    }

    /**
     * Records [messageId] as processed.
     *
     * Synchronized with the rest of the set, and the new id is written to the
     * store before the call returns, so a restart does not forget it.
     *
     * @return true for a newly recorded non-empty ID. False suppresses
     *   presentation; socket acknowledgement policy is handled by the caller.
     */
    @Synchronized
    fun add(messageId: String): Boolean {
        if (messageId.isEmpty()) return false
        val fresh = ids.put(messageId, true)
        if (fresh) store.saveSeen(ids.keys())
        return fresh
    }

    @Synchronized
    fun contains(messageId: String): Boolean = ids.containsKey(messageId)

    @Synchronized
    fun size(): Int = ids.size()

    /** Oldest first, which is the order [store] keeps them in. */
    @Synchronized
    fun snapshot(): List<String> = ids.keys()

    /** Test and diagnostics seam: what a restart would restore. */
    fun persisted(): List<String> = store.loadSeen()
}

/**
 * The process-wide [SeenSet] (SB-64).
 *
 * Over the same `sinch_push_socket_state` / `seen` key the socket client has
 * always persisted to, so an existing set loads into the current capacity
 * unchanged. Everything that dedupes in this process goes through this one
 * instance - a second instance over the same key would overwrite the first's
 * writes.
 */
internal object SharedSeenSet {

    @Volatile private var instance: SeenSet? = null

    fun get(context: Context): SeenSet =
        getOrCreate { SeenSet(SharedPreferencesSocketStateStore(context)) }

    /**
     * The instance, built by [factory] on first use only. Context-free so a JVM
     * test can exercise the "one instance per process" rule that [get] gives its
     * two callers (`androidSocketDependencies`, the FCM service).
     */
    fun getOrCreate(factory: () -> SeenSet): SeenSet =
        instance ?: synchronized(this) {
            instance ?: factory().also { instance = it }
        }

    /** Test seam: install [set] (or clear with null) as the process-wide instance. */
    fun setForTesting(set: SeenSet?) {
        synchronized(this) { instance = set }
    }
}
