package com.sinchpush.socket

import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.util.Log
import com.sinchpush.BuildConfig

/**
 * The relay off switch (SB-66).
 *
 * The relay is **opt-in**: the push socket (and the foreground service that owns
 * it) only exists in a build whose integrator set `SinchPush_relay=true`
 * (`BuildConfig.RELAY_AVAILABLE`), and even then it stays off until the host
 * calls `setRelayEnabled(true)`. Provider push (FCM) is the default channel.
 *
 * "Is the relay on for this install?" is a fact native code has to answer
 * without JS: a foreground service that comes back after process death, a
 * `Hello` built for a reconnect and `getDeviceInfo()` for a `Subscribe` all have
 * to agree with it. So the value is persisted here rather than being carried in
 * the JS config, and every native entry point reads this one.
 *
 * Persisted in plain `SharedPreferences` (not the Keystore-encrypted slot of
 * [InstallationIdStore]) because the value is a **policy**, not a secret: there
 * is nothing to steal, it only ever reads back as a boolean, and a preference
 * file is readable by the service even before the Keystore has warmed up.
 */
internal interface RelaySwitch {
    /** Whether the relay may run at all. `false` until the host turned it on. */
    fun isEnabled(): Boolean

    /**
     * Persists the switch; visible to every later read in this process.
     *
     * `false` when the value did **not** reach storage: it still applies to
     * this process, but a restarted one will not see it.
     */
    fun setEnabled(enabled: Boolean): Boolean
}

/**
 * The value a graph with no switch in it reports: on.
 *
 * The default for [SystemDeviceInfoProvider] only. A provider built without a
 * switch has nothing that could turn the relay off, so it must not pretend the
 * relay is off. This is not the install default: every production graph passes
 * [RelaySwitchController.switch], whose persisted default is *off*
 * ([SharedPreferencesRelaySwitch.DEFAULT_ENABLED]).
 */
internal object RelayAlwaysOn : RelaySwitch {
    override fun isEnabled(): Boolean = true
    /** Nothing is stored, so there is nothing that can fail to be stored. */
    override fun setEnabled(enabled: Boolean): Boolean = true
}

/**
 * The production switch: `SharedPreferences("sinch_push_relay")`, key `enabled`.
 *
 * Default `false` — a missing key means "never switched on", which is the same
 * answer as every install that has not called `setRelayEnabled(true)`.
 */
internal class SharedPreferencesRelaySwitch(private val prefs: SharedPreferences) : RelaySwitch {

    constructor(context: Context) : this(
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE),
    )

    override fun isEnabled(): Boolean = prefs.getBoolean(KEY_ENABLED, DEFAULT_ENABLED)

    /**
     * `commit()`, not `apply()`: this value is the one thing a restarted process
     * has to agree with, and `apply()`'s asynchronous write is lost when the
     * host kills the app right after switching the relay off — which is exactly
     * the moment "off" has to hold. The in-memory map is still updated
     * synchronously, so the next read in this process (`Hello`,
     * `getDeviceInfo()`) sees it either way.
     *
     * The result is reported: `commit()` answers whether the value reached
     * the disk, and a caller that ignored it would promise a durability the
     * switch may not have.
     */
    override fun setEnabled(enabled: Boolean): Boolean =
        prefs.edit().putBoolean(KEY_ENABLED, enabled).commit()

    companion object {
        /** Its own file: this value outlives the socket config, which is cleared on stop. */
        const val PREFS = "sinch_push_relay"

        const val KEY_ENABLED = "enabled"

        const val DEFAULT_ENABLED = false
    }
}

/**
 * The relay is off, so there is no socket to start (SB-66).
 *
 * A typed failure rather than a `start` that silently does nothing, because the
 * caller has already been promised a socket by the time it can know; the bridge
 * maps this to `E_RELAY_DISABLED`, the same code JS already produces from the
 * url-resolution path, so a host has one error to handle either way.
 *
 * Distinct from [ForegroundServiceRefusedException]: nothing was refused by the
 * platform here — the host asked for something the SDK is not doing.
 */
internal class RelayDisabledException(
    message: String = TURNED_OFF_MESSAGE,
) : RuntimeException(message) {

    companion object {
        const val TURNED_OFF_MESSAGE =
            "the relay is turned off in the SDK; call setRelayEnabled(true) first"

        /** The build opted out of the relay: no service, no permissions, nothing to switch on. */
        const val NOT_AVAILABLE_MESSAGE =
            "the push socket relay is not part of this build; set SinchPush_relay=true in " +
                "android/gradle.properties (or rootProject.ext.SinchPush_relay) and rebuild"
    }
}

/**
 * The persisted switch with the build's opt-in in front of it.
 *
 * A build without `SinchPush_relay=true` has no [SinchPushSocketService] in its
 * manifest and no foreground-service permissions, so the relay cannot run there
 * whatever a stored `true` says (a stale value from an earlier build, or
 * `setRelayEnabled(true)` from a host that forgot the property). Every native
 * reader — the service, the controller, `Hello`, `getDeviceInfo()` — goes
 * through this, so they all report `RELAY_DISABLED` there.
 */
internal class BuildGatedRelaySwitch(
    private val delegate: RelaySwitch,
    private val available: () -> Boolean = { BuildConfig.RELAY_AVAILABLE },
) : RelaySwitch {
    override fun isEnabled(): Boolean = available() && delegate.isEnabled()
    override fun setEnabled(enabled: Boolean): Boolean = delegate.setEnabled(enabled)
}

/**
 * Enables and disables [SinchPushSocketService] as a *component*.
 *
 * Stopping the socket is not enough on Android: `START_STICKY` (SB-55) means a
 * service the platform kills brings itself back with a null Intent, and it will
 * do that without asking. Disabling the component is what makes "off" hold — the
 * platform cannot start a disabled component at all, so a restart has nothing to
 * restart and `onStartCommand` is never reached.
 */
internal interface SocketServiceComponentToggler {
    /**
     * `true` puts the component back to its manifest state
     * (`COMPONENT_ENABLED_STATE_DEFAULT`); `false` disables it
     * (`COMPONENT_ENABLED_STATE_DISABLED`).
     */
    fun setSocketServiceEnabled(enabled: Boolean)
}

/**
 * The production toggler, over `PackageManager.setComponentEnabledSetting`.
 *
 * `DONT_KILL_APP` rather than the killing flags: the service is being taken away
 * on purpose and [SinchPushSocketController.stop] has already closed the socket,
 * so there is nothing to preserve and killing the host app over a policy switch
 * would be the SDK's business rather than the host's.
 */
internal class PackageManagerSocketServiceToggler(context: Context) : SocketServiceComponentToggler {

    private val appContext = context.applicationContext

    override fun setSocketServiceEnabled(enabled: Boolean) {
        // No such component in a build without `SinchPush_relay=true`.
        if (!BuildConfig.RELAY_AVAILABLE) return
        try {
            appContext.packageManager.setComponentEnabledSetting(
                ComponentName(appContext, SinchPushSocketService::class.java),
                if (enabled) {
                    PackageManager.COMPONENT_ENABLED_STATE_DEFAULT
                } else {
                    PackageManager.COMPONENT_ENABLED_STATE_DISABLED
                },
                PackageManager.DONT_KILL_APP,
            )
        } catch (t: Throwable) {
            // A host that merged this library's manifest into a component it
            // declares itself can make the lookup fail. The switch itself is
            // already persisted, so the relay stays off either way; only the
            // belt-and-braces component state is lost, and `onStartCommand`
            // refuses the same start (SB-66).
            Log.w(TAG, "could not ${if (enabled) "enable" else "disable"} the socket service component", t)
        }
    }
}

/**
 * Applying the switch (SB-66), with the collaborators as parameters.
 *
 * The order is the rule: **off: persist, stop, clear config, disable
 * component, notify. On: persist and enable; do not start.**
 *
 * Off stops the socket while it can still be closed and disables the component
 * afterwards, because a disabled component cannot be stopped by an intent.
 * On enables the component and starts nothing: the host calls
 * `startPushSocket`, exactly as it does after any other stop, so turning the
 * relay back on never silently opens a socket.
 *
 * Both directions finish with [DeviceInfoChanges.check]: `background_service`
 * just moved to or from `RELAY_DISABLED`, and that is a `Subscribe` fact (SB-61).
 *
 * Nothing in the off path throws. A stop the platform refused — a background
 * `startService` for `ACTION_STOP` throws on API 26+ — is no reason to leave the
 * relay on or to reject the bridge's promise: the client is closed before that
 * start is sent (see [SinchPushSocketController.stopForRelayOff]), and the
 * disable is what makes "off" hold across a `START_STICKY` restart.
 *
 * The return value says whether the value reached storage. `false` means the
 * switch holds for this process only — the in-memory map was updated either
 * way — and the caller has to tell the host so.
 */
internal fun applyRelaySwitch(
    enabled: Boolean,
    relaySwitch: RelaySwitch,
    componentToggler: SocketServiceComponentToggler,
    stopSocket: () -> Unit,
    clearSocketConfig: () -> Unit = {},
    onChanged: () -> Unit = { DeviceInfoChanges.check() },
): Boolean {
    val persisted = try {
        if (enabled) {
            val stored = relaySwitch.setEnabled(true)
            componentToggler.setSocketServiceEnabled(true)
            stored
        } else {
            val stored = relaySwitch.setEnabled(false)
            try {
                stopSocket()
            } catch (t: Throwable) {
                Log.w(TAG, "the socket did not stop cleanly; the relay is still being turned off", t)
            } finally {
                clearSocketConfigQuietly(clearSocketConfig)
                // In a `finally`: a stop that threw (the platform refusing the
                // STOP start from the background, say) must not leave the
                // component enabled, because that is the part that makes "off"
                // hold across a `START_STICKY` restart.
                componentToggler.setSocketServiceEnabled(false)
            }
            stored
        }
    } finally {
        // In a `finally` for the same reason: JS is told the value moved even
        // when the stop was refused, or it keeps reporting the old
        // `background_service` and never re-subscribes (SB-61).
        onChanged()
    }
    if (!persisted) {
        // The switch is applied — the client is closed, the component disabled,
        // the change notified — but a restarted process will not see it.
        Log.w(TAG, "the relay switch was applied but not persisted; it holds for this process only")
    }
    return persisted
}

/**
 * Drops the persisted socket config, whatever the stop did.
 *
 * Clearing it is normally the service's `ACTION_STOP` handler's job, and that
 * start is exactly the one a background `startService` can refuse — so the off
 * path clears it itself. A config that outlives "off" is a trap for the next
 * start.
 */
private fun clearSocketConfigQuietly(clearSocketConfig: () -> Unit) {
    try {
        clearSocketConfig()
    } catch (t: Throwable) {
        Log.w(TAG, "could not clear the persisted socket config while turning the relay off", t)
    }
}

private const val TAG = "SinchPushRelaySwitch"

/** The one entry point native code asks, and the one [applyRelaySwitch] drives. */
internal object RelaySwitchController {

    @Volatile
    private var relaySwitch: RelaySwitch? = null

    @Volatile
    private var componentToggler: SocketServiceComponentToggler? = null

    /** The persisted switch behind the build's opt-in, one instance per process. */
    fun switch(context: Context): RelaySwitch {
        relaySwitch?.let { return it }
        return synchronized(this) {
            relaySwitch ?: BuildGatedRelaySwitch(SharedPreferencesRelaySwitch(context.applicationContext))
                .also { relaySwitch = it }
        }
    }

    /** Whether the relay may run at all right now (SB-66). */
    fun isEnabled(context: Context): Boolean = switch(context).isEnabled()

    /**
     * Applies and persists the switch. Idempotent — the component state is
     * (re)applied on every call, so turning the relay on also repairs a
     * component that was left disabled.
     *
     * `false` when the value did not reach storage: the switch is applied for
     * this process, and the caller has to tell the host so.
     */
    fun setEnabled(context: Context, enabled: Boolean): Boolean {
        val appContext = context.applicationContext
        if (enabled && !BuildConfig.RELAY_AVAILABLE) {
            // Stored, but inert: the switch reads off until the build opts in.
            Log.w(TAG, "setRelayEnabled(true) has no effect: ${RelayDisabledException.NOT_AVAILABLE_MESSAGE}")
        }
        return applyRelaySwitch(
            enabled = enabled,
            relaySwitch = switch(appContext),
            componentToggler = toggler(appContext),
            stopSocket = { SinchPushSocketController.stopForRelayOff(appContext) },
            clearSocketConfig = { PushSocketConfig.clear(appContext) },
        )
    }

    /**
     * Re-asserts `COMPONENT_ENABLED_STATE_DEFAULT`, for a `start` that arrives
     * while the relay is on (SB-66).
     *
     * The self-heal for a switch and a component that drifted apart: the
     * component can only have been disabled by the switch, so a start that got
     * past the relay check is entitled to undo it.
     */
    fun enableComponent(context: Context) {
        toggler(context.applicationContext).setSocketServiceEnabled(true)
    }

    private fun toggler(context: Context): SocketServiceComponentToggler {
        componentToggler?.let { return it }
        return synchronized(this) {
            componentToggler ?: PackageManagerSocketServiceToggler(context)
                .also { componentToggler = it }
        }
    }

    /** Test seam: drops the memoised Android collaborators. */
    internal fun resetForTest() {
        synchronized(this) {
            relaySwitch = null
            componentToggler = null
        }
    }
}
