package com.sinchpush.socket

/**
 * A map instead of `SharedPreferences`, so the whole store can be exercised
 * off-device — and so a second store over the same instance stands in for a
 * relaunch.
 *
 * Lives in the test source set on purpose: the library ships the interface and
 * the `SharedPreferences` implementation, not this.
 */
internal class InMemoryInstallationIdPrefs(initial: String? = null) : InstallationIdPrefs {

    @Volatile
    private var stored: String? = initial

    /** Set to `false` to stand in for a full disk or a failing `commit()`. */
    @Volatile
    var acceptsWrites: Boolean = true

    /** Counts writes, so a test can prove a value was persisted, not cached. */
    @Volatile
    var writeCount: Int = 0
        private set

    override fun read(): String? = stored

    override fun write(value: String): Boolean {
        writeCount++
        if (!acceptsWrites) return false
        stored = value
        return true
    }
}
