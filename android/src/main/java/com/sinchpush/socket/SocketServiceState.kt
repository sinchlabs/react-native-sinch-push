package com.sinchpush.socket

/**
 * Process-wide record of [SinchPushSocketService], so the state in `Hello` can
 * be answered without a binder round trip (SB-60).
 *
 * A plain object rather than service state because the service is created and
 * destroyed by the platform, and because the answer has to be readable from the
 * in-process owner too, where the service does not exist.
 *
 * Only the service writes [running]: `onCreate` / `onDestroy` and its own failed
 * `startForeground` or `onTimeout` ([onPromotionFailed]). The caller-side
 * refusal of `startForegroundService` ([recordStartFailure]) only records why,
 * because at that point no service instance exists and a service that is
 * already running (a second `start` while the first is up) must keep saying so.
 */
internal object SocketServiceState {

    /** True between the service's `onCreate` and its `onDestroy`, or until its foreground promotion fails. */
    @Volatile
    var running: Boolean = false
        private set

    /** The last reason the foreground service could not be started or kept, for diagnostics. */
    @Volatile
    var lastStartFailure: String? = null
        private set

    fun onCreated() {
        running = true
        lastStartFailure = null
        notifyChanged()
    }

    fun onDestroyed() {
        running = false
        notifyChanged()
    }

    /**
     * `startForegroundService` was refused in the caller (API 31+
     * `ForegroundServiceStartNotAllowedException`, a missing FGS permission).
     * Records the reason only; it does not touch [running].
     */
    fun recordStartFailure(t: Throwable) {
        lastStartFailure = describe(t)
    }

    /**
     * The service is alive but the platform refused (`startForeground`) or
     * withdrew (`onTimeout`) its foreground status. A service that is not in the
     * foreground is not the dependable channel `ENABLED_RUNNING` promises,
     * whether or not the process still hosts it.
     */
    fun onPromotionFailed(t: Throwable) {
        running = false
        lastStartFailure = describe(t)
        notifyChanged()
    }

    /**
     * Told after every write to [running] (SB-61): the background-service value
     * in `Subscribe` is derived from it, so a transition is when JS may need to
     * subscribe again. Set once by [DeviceInfoChanges]; a listener that throws
     * must not take the service down with it.
     */
    @Volatile
    internal var changeListener: (() -> Unit)? = null

    private fun notifyChanged() {
        try {
            changeListener?.invoke()
        } catch (t: Throwable) {
            // Best effort: the next app start's fingerprint check covers a miss.
        }
    }

    private fun describe(t: Throwable) = "${t.javaClass.simpleName}: ${t.message}"

    /** Test seam. */
    internal fun resetForTest() {
        running = false
        lastStartFailure = null
    }
}
