package com.sinchpush.socket

import android.content.Context
import com.sinchpush.SinchPushEmitter
import sinch.push.v1beta1.resources.BackgroundServiceState

/**
 * Tells JS when `background_service` changes (SB-61).
 *
 * `Subscribe` carries the value, and unlike the other device facts it moves while
 * the app runs: the service comes up, is killed, is refused its foreground
 * status, or the host starts/stops the socket with a different
 * `backgroundService` setting. JS re-reads `getDeviceInfo()` and subscribes
 * again if its fingerprint differs, so this only has to say *that something may
 * have changed* - and say it once per change, not once per callback.
 *
 * Pure: the value comes from [current] and goes to [sink], so a JVM test needs
 * neither a `Context` nor a React context.
 *
 * @param current the value now (SB-60), recomputed on every [check].
 * @param sink delivers a change; returns whether it was delivered. `false` (no
 *   React context to emit on) leaves the change pending, so it is offered again
 *   on the next [check] rather than lost - and a change that is never delivered
 *   is still caught by the fingerprint check on the next app start.
 */
internal class DeviceInfoChangeNotifier(
    private val current: () -> BackgroundServiceState,
    private val sink: (BackgroundServiceState) -> Boolean,
) {
    private var lastNotified: BackgroundServiceState? = null

    /**
     * Records the current value as the one JS already knows, without emitting.
     * Called when JS attaches: its `initialize` runs the fingerprint check
     * itself, so a change that happened before then needs no event.
     */
    @Synchronized
    fun prime() {
        lastNotified = readCurrent()
    }

    /**
     * Emits iff the value differs from the last one delivered (or primed).
     *
     * Runs on the caller's thread - the main thread for the service lifecycle,
     * the bridge thread for start/stop - and [current] may read `SharedPreferences`
     * there (the persisted socket config), but only on a transition: while an
     * in-process config is live the value is computed from memory.
     */
    @Synchronized
    fun check() {
        val now = readCurrent() ?: return
        if (now == lastNotified) return
        if (sink(now)) lastNotified = now
    }

    private fun readCurrent(): BackgroundServiceState? = try {
        current()
    } catch (t: Throwable) {
        // A state that cannot be computed right now is not a change.
        null
    }
}

/**
 * The production wiring of [DeviceInfoChangeNotifier]: SB-60's value, from the
 * same provider `Hello` and `getDeviceInfo()` use, emitted as
 * `SinchPush:onDeviceInfoChanged`.
 *
 * [check] is called wherever the inputs of that value change - the service's
 * lifecycle ([SocketServiceState]), the controller's start/stop, and the relay
 * off switch ([applyRelaySwitch]: off moves the value to `RELAY_DISABLED` on
 * both platforms).
 */
internal object DeviceInfoChanges {

    @Volatile
    private var notifier: DeviceInfoChangeNotifier? = null

    /**
     * Called when the module is constructed, i.e. when JS attaches - which is
     * also when a reloaded JS context starts over. Creates the notifier once per
     * process; every call re-primes it, because a JS that has just started runs
     * its own fingerprint check at `initialize` and so already knows the value.
     */
    @Synchronized
    fun attach(context: Context) {
        val existing = notifier
        if (existing != null) {
            existing.prime()
            return
        }
        val appContext = context.applicationContext
        val provider = SystemDeviceInfoProvider(
            AndroidDeviceEnvironment(appContext),
            AndroidSocketLogger,
            RelaySwitchController.switch(appContext),
        )
        val created = DeviceInfoChangeNotifier(
            current = {
                provider.backgroundServiceState(SinchPushSocketController.currentConfig(appContext))
            },
            sink = { state -> SinchPushEmitter.onDeviceInfoChanged(state.jsName()) },
        )
        created.prime()
        notifier = created
        SocketServiceState.changeListener = { check() }
    }

    /** No-op until [attach]: a process with no JS has nobody to tell. */
    fun check() {
        notifier?.check()
    }
}
