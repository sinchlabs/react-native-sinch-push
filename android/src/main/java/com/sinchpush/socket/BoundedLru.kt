package com.sinchpush.socket

import java.util.LinkedHashMap

/**
 * An insertion-ordered map with a hard capacity.
 *
 * The spec's two bounded collections are both this: the 500-entry seen set
 * (SB-28) and the sent-set / report-lookup map behind it (SB-30). Neither is
 * unbounded - a long-lived Android foreground service is exactly where an
 * unbounded set of message ids becomes a slow leak that no one notices until the
 * process is killed and everything is re-delivered.
 *
 * Eviction is **least-recently-inserted**, as SB-28 words it. Re-inserting an
 * existing key updates the value and keeps the key's original position, so a
 * hot id does not pin the tail of the map the way an access-ordered cache would;
 * the bound exists to stop growth, not to be clever.
 */
internal class BoundedLru<K, V>(val capacity: Int) {

    private val entries = object : LinkedHashMap<K, V>(16, 0.75f, false) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?): Boolean =
            size > this@BoundedLru.capacity
    }

    /**
     * Inserts or replaces [value] under [key].
     *
     * @return true when the key was not already present, which is how both
     *   callers ask "was this new?": the seen set's dedupe decision and the
     *   tracker's once-per-`(message_id, status)` decision are the same question.
     */
    fun put(key: K, value: V): Boolean {
        val fresh = !entries.containsKey(key)
        entries[key] = value
        return fresh
    }

    operator fun get(key: K): V? = entries[key]

    fun containsKey(key: K): Boolean = entries.containsKey(key)

    operator fun contains(key: K): Boolean = entries.containsKey(key)

    /** The keys, oldest first - the order they are persisted and evicted in. */
    fun keys(): List<K> = entries.keys.toList()

    /** The entries, oldest first. */
    fun values(): List<V> = entries.values.toList()

    fun pairs(): List<Pair<K, V>> = entries.map { (k, v) -> k to v }

    fun size(): Int = entries.size

    fun clear() = entries.clear()

    /** Restores persisted order: [keys] must arrive oldest-first. */
    fun restore(keys: List<K>, valueFor: (K) -> V) {
        entries.clear()
        for (key in keys) put(key, valueFor(key))
    }
}