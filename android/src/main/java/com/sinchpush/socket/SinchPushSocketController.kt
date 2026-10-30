package com.sinchpush.socket

import android.content.Context
import android.util.Log
import com.sinchpush.BuildConfig
import com.sinchpush.SinchPushEmitter

/**
 * Chooses the socket's owner (SB-54).
 *
 * Android's default is the foreground service: an in-process socket dies with
 * the app, which is the whole reason the service exists. `backgroundService:
 * false` runs the *same* client in-process instead. Either way there is one
 * owner at a time - the relay closes the loser of a race with `BG_RESUMED`,
 * and holding two live sockets for one `(app_id, user_id)` is worse than losing
 * one of them.
 */
internal enum class SocketOwner {
    SERVICE,
    IN_PROCESS,
}

internal fun ownerFor(config: PushSocketConfig): SocketOwner =
    if (config.backgroundService) SocketOwner.SERVICE else SocketOwner.IN_PROCESS

internal object SinchPushSocketController {

    @Volatile
    private var client: SinchPushSocketClient? = null

    /**
     * The config the socket was last started with, in memory. It is what `Hello`
     * was built from, so it is the right input for the `Subscribe`-side
     * `background_service` too: the persisted copy is written only by the
     * service owner, so an in-process start would otherwise be judged against a
     * stale or absent file. Cleared by [stop]; a restarted process (the service
     * coming back with a null intent) falls back to the persisted one.
     */
    @Volatile
    private var activeConfig: PushSocketConfig? = null

    /**
     * The one ordering of everything that can change the socket's state: every
     * [start], [begin] (via [newListener]) and published service error moves it
     * forward.
     *
     * Listeners: a client's `stop()` is asynchronous (it runs on the client's
     * scheduler thread) and publishes `stopped` through whatever listener is
     * attached when it runs, so a `stopped` queued by an earlier `stop()` can
     * land after a later error and overwrite it. Ignore callbacks from
     * superseded clients; check generation and publish state under stateLock.
     *
     * Stops: [stop] hands the generation to the service's `ACTION_STOP`, which
     * comes back through [onServiceStopRequested] (see [activeConfigGeneration]).
     */
    private val generation = java.util.concurrent.atomic.AtomicInteger(0)

    /**
     * The [generation] of the [start] that set [activeConfig]. Tag queued STOP
     * requests with the active-config generation so an older STOP cannot clear
     * a newer config. Not the live [generation] itself, because [begin] and a
     * published service error move that too, and neither makes a queued STOP
     * stale - the STOP still stops the client they left behind, and must forget
     * its config.
     */
    @Volatile
    private var activeConfigGeneration = 0

    /**
     * Makes the generation check and the store write + emit one step, so a
     * listener's stale state cannot land on top of a published error. Never held
     * while calling into the client, so a client lock cannot deadlock with it;
     * the emitter only posts to RN.
     */
    private val stateLock = Any()

    /**
     * The one lock that decides who owns the socket (SB-66).
     *
     * [begin] and the relay-off path run on different threads - the service's
     * `onStartCommand` on the main thread, `setRelayEnabled(false)` on the
     * native-modules thread - so they have to meet here: `begin` reads the
     * switch and installs a client, the off path stops one. Without the lock
     * they interleave: `begin` reads "on", the off path finds no client to
     * stop, and `begin` installs one - a socket while the relay is off.
     *
     * The off path persists the switch before it stops, so holding the lock
     * makes the outcome right in both orders: if `begin` wins, the off path
     * waits and stops the client `begin` installed; if the off path wins,
     * `begin`'s re-check reads the switch off and creates nothing.
     *
     * Lock order: `ownerLock` before [stateLock]. Nothing holds [stateLock]
     * while asking for `ownerLock`, so the two cannot deadlock.
     */
    private val ownerLock = Any()

    /** Test seam: the config [currentConfig] reports while a socket is considered started. */
    internal fun activeConfigForTest(): PushSocketConfig? = activeConfig

    internal fun generationForTest(): Int = generation.get()

    /** The config SB-60 is evaluated against: the live one, else the persisted one. */
    fun currentConfig(context: Context): PushSocketConfig? =
        activeConfig ?: PushSocketConfig.load(context.applicationContext)

    /**
     * @throws RelayDisabledException when the build does not include the relay
     *   (`SinchPush_relay` unset) or the relay is off in the SDK
     *   (SB-66). Nothing is started and no state is written: the bridge
     *   rejects `startPushSocket` with `E_RELAY_DISABLED`.
     * @throws ForegroundServiceRefusedException when the service owner could not
     *   be started. The error state has already been stored and emitted, and
     *   nothing else owns the socket (SB-54): the bridge rejects
     *   `startPushSocket` with `E_FGS_START_REFUSED`.
     */
    fun start(context: Context, config: PushSocketConfig) {
        val appContext = context.applicationContext
        start(
            config,
            relayAvailable = { BuildConfig.RELAY_AVAILABLE },
            // Read before anything is written: a refused start must leave the
            // socket state exactly as it was.
            relayEnabled = { RelaySwitchController.isEnabled(appContext) },
            // Self-heal (SB-66): a start that got past the relay check re-enables
            // the component, which only the switch can disable. Idempotent, and
            // after the relay check so a start refused as E_RELAY_DISABLED
            // touches nothing.
            enableComponent = { RelaySwitchController.enableComponent(appContext) },
            startService = { SinchPushSocketService.start(appContext, config) },
            startInProcess = { begin(appContext, config) },
        )
    }

    /** [start] with the two owners, the switch and the toggler as seams, so a JVM test needs no `Context`. */
    internal fun start(
        config: PushSocketConfig,
        relayAvailable: () -> Boolean = { true },
        relayEnabled: () -> Boolean = { true },
        enableComponent: () -> Unit = {},
        startService: () -> Unit,
        startInProcess: () -> Unit,
    ) {
        if (!relayAvailable()) throw RelayDisabledException(RelayDisabledException.NOT_AVAILABLE_MESSAGE)
        if (!relayEnabled()) throw RelayDisabledException()
        enableComponent()
        // A previous owner's late `stopped` (stopPushSocket, then start) must not
        // land on top of this start's state - in particular not on top of the
        // refusal published below.
        activeConfigGeneration = generation.incrementAndGet()
        activeConfig = config
        SinchPushSocketStore.setState(
            SinchPushSocketStore.SocketState(
                status = "connecting",
                connectionId = null,
                pollIntervalMs = config.pollIntervalMs,
                reconnectAttempts = 0,
                lastError = null,
            ),
        )
        // Only the presentation buffer is cleared. The client's dedupe memory is
        // durable and outlives the process (SB-28), so a restart does not
        // re-report everything the relay already offered.
        SinchPushSocketStore.clear()
        try {
            startOwner(config, startService, startInProcess)
        } finally {
            // The inputs of `background_service` just moved: a new
            // `backgroundService` setting, or a service about to come up.
            DeviceInfoChanges.check()
        }
    }

    private fun startOwner(
        config: PushSocketConfig,
        startService: () -> Unit,
        startInProcess: () -> Unit,
    ) {
        when (ownerFor(config)) {
            SocketOwner.SERVICE -> try {
                startService()
            } catch (e: ForegroundServiceRefusedException) {
                // No in-process fallback: two owners for one (app_id, user_id) is
                // the race SB-54 forbids. Say so instead of leaving JS in
                // "connecting" for a socket that will never open.
                publishServiceError(e.message.orEmpty())
                throw e
            }
            SocketOwner.IN_PROCESS -> startInProcess()
        }
    }

    /**
     * Stores and emits `status = "error"` for a service that could not be
     * started, or could not stay up (SB-60). Callable from the service's own
     * callbacks, hence no `Context`.
     */
    fun publishServiceError(reason: String) {
        // Mute every listener still attached to a client that is stopping, so its
        // asynchronous `stopped` cannot overwrite this error.
        synchronized(stateLock) {
            generation.incrementAndGet()
            val errored = SinchPushSocketStore.state().copy(
                status = "error",
                connectionId = null,
                reconnectAttempts = 0,
                lastError = reason,
            )
            SinchPushSocketStore.setState(errored)
            stateSink(errored)
        }
    }

    /**
     * The service's `onTimeout` (API 35 `dataSync` budget ran out): clears the
     * running flag (SB-60), stops the client and tells JS why. The socket does
     * not continue in-process (SB-54). Main thread, no `Context`.
     */
    fun onServiceTimeout() {
        SocketServiceState.onPromotionFailed(ForegroundServiceTimeoutException())
        generation.incrementAndGet() // before stopClient(): its queued `stopped` must find the listener silent
        stopClient()
        publishServiceError(SinchPushSocketService.FOREGROUND_TIMEOUT_REASON)
    }

    /**
     * The service's own `startForeground` was refused (SB-60 path 2): clears the
     * running flag, stops the client and tells JS why.
     */
    fun onServicePromotionRefused(t: Throwable) {
        SocketServiceState.onPromotionFailed(t)
        generation.incrementAndGet() // before stopClient(): its queued `stopped` must find the listener silent
        stopClient()
        publishServiceError(ForegroundServiceRefusedException.reasonFor(t))
    }

    private var stateSink: (SinchPushSocketStore.SocketState) -> Unit = { state ->
        SinchPushEmitter.onSocketState(state.toWritableMap())
    }

    /** Test seam: where emitted states go instead of the React emitter. */
    internal fun setStateSinkForTest(sink: ((SinchPushSocketStore.SocketState) -> Unit)?) {
        stateSink = sink ?: { state -> SinchPushEmitter.onSocketState(state.toWritableMap()) }
    }

    fun stop(context: Context) {
        activeConfig = null
        SinchPushSocketService.stop(context.applicationContext, generation.get())
        stopClient()
        DeviceInfoChanges.check()
    }

    /**
     * The stop the relay-off switch makes (SB-66) — not [stop].
     *
     * Close the client before attempting the platform STOP; always clear config
     * and disable the component. Closing the client is a call into the client
     * and not into the platform, so it cannot be refused; the platform STOP is
     * sent only when a service is actually running, so a switch flipped with
     * nothing running never makes a background start at all. A refusal is
     * logged, never rethrown — the component is about to be disabled, which is
     * what stops the platform from restarting it.
     */
    fun stopForRelayOff(context: Context) {
        val appContext = context.applicationContext
        stopForRelayOff(
            serviceRunning = SocketServiceState.running,
            stopService = { SinchPushSocketService.stop(appContext, generation.get()) },
        )
    }

    /** [stopForRelayOff] with the platform start as a seam, so a JVM test needs no `Context`. */
    internal fun stopForRelayOff(serviceRunning: Boolean, stopService: () -> Unit) {
        // The client stop shares [ownerLock] with `begin`: the switch is
        // already persisted off, so either this stop finds the client `begin`
        // installed, or `begin`'s re-check finds the switch off and installs
        // nothing (SB-66). The platform STOP is sent outside the lock - it is
        // a platform call and must not block the other owners.
        synchronized(ownerLock) {
            activeConfig = null
            stopClient()
        }
        if (serviceRunning) {
            try {
                stopService()
            } catch (t: Throwable) {
                Log.w(TAG, "the socket service refused the stop while turning the relay off", t)
            }
        }
        DeviceInfoChanges.check()
    }

    /**
     * The service's `ACTION_STOP`: the service owner stops the client, and the
     * config this process considers started goes with it, so `background_service`
     * is not judged against a socket that no longer exists.
     * [stopGeneration] is the [generation] [stop] saw ([ANY_GENERATION] when the
     * sender did not say); a newer [start] since then keeps its config.
     */
    fun onServiceStopRequested(stopGeneration: Int) {
        stopClient()
        if (activeConfigGeneration <= stopGeneration) {
            activeConfig = null
        }
    }

    /** A [stopGeneration] that no start is newer than: the stop always forgets the config. */
    const val ANY_GENERATION = Int.MAX_VALUE

    /**
     * Opens the socket, but only while the relay is on (SB-66).
     *
     * The switch is read again here, before a client is created, because the
     * callers that already read it do not run on the same thread as the switch:
     * the service's `onStartCommand` checks it on the main thread, while
     * `setRelayEnabled(false)` applies it on the native-modules thread.
     *
     * The read and the installation happen under [ownerLock], which the
     * relay-off path takes to stop the client: a relay-off can therefore not
     * leave a client behind.
     */
    fun begin(context: Context, config: PushSocketConfig) {
        val appContext = context.applicationContext
        begin(
            config = config,
            relayEnabled = { RelaySwitchController.isEnabled(appContext) },
            createClient = { SinchPushSocketClient(config, androidSocketDependencies(appContext)) },
        )
    }

    /** [begin] with the switch and the client as seams, so a JVM test needs no `Context`. */
    internal fun begin(
        config: PushSocketConfig,
        relayEnabled: () -> Boolean,
        createClient: () -> SinchPushSocketClient,
    ) {
        // One lock with the relay-off path: the re-check and the installation
        // are one step, or an off that lands between them leaves a client
        // behind (SB-66). `start()` hands the work to the client's own thread,
        // so nothing here blocks on the socket.
        synchronized(ownerLock) {
            if (!relayEnabled()) {
                Log.w(TAG, "not opening a socket: the relay is turned off in the SDK")
                return
            }
            stopClient()
            activeConfig = config
            val newClient = createClient().apply { setListener(newListener()) }
            client = newClient
            newClient.start()
        }
    }

    fun stopClient() {
        client?.stop()
        client = null
    }

    fun isActive(): Boolean = client != null

    /**
     * The host entry point behind `reportPushMessageStatus`.
     *
     * `DISPLAYED` / `DISMISSED` are reported once per `(message_id, status)` by
     * the client, whether there is a live socket or not - with no socket the
     * report waits in the persisted outbox and goes out after the next
     * `HelloAck` (SB-35). Doing nothing when the socket is absent is exactly the
     * failure the outbox exists to remove: a `DISMISSED` raised in the background
     * would otherwise be lost until the device produced another message.
     */
    fun reportStatus(messageId: String, status: ReportStatus) {
        client?.reportStatus(messageId, status)
    }

    enum class HostReport { ACCEPTED, INVALID_STATUS, NOT_RUNNING }

    /**
     * `reportPushMessageStatus` as the bridge sees it: validates the host
     * spelling and refuses when nothing owns a socket, so the JS facade never
     * mistakes a dropped report for a delivered one.
     */
    fun reportFromHost(messageId: String, status: String?): HostReport {
        val parsed = status?.let { ReportStatus.fromHostString(it) } ?: return HostReport.INVALID_STATUS
        val owner = client ?: return HostReport.NOT_RUNNING
        owner.reportStatus(messageId, parsed)
        return HostReport.ACCEPTED
    }

    /** Whether the host has an in-app handler; read by the display rule. */
    fun setHandlerRegistered(registered: Boolean) {
        SinchPushSocketStore.handlerRegistered = registered
    }

    /** Test seam: installs an owner without building Android dependencies. */
    internal fun installClientForTest(c: SinchPushSocketClient?) {
        client = c
    }

    /** Test seam: [installClientForTest] with the controller's own listener attached, as [begin] does. */
    internal fun installClientWithControllerListenerForTest(c: SinchPushSocketClient) {
        c.setListener(newListener())
        client = c
    }

    fun state(): SinchPushSocketStore.SocketState = SinchPushSocketStore.state()

    fun messages(): List<SinchPushSocketStore.SocketMessage> = SinchPushSocketStore.messages()

    fun clearMessages() = SinchPushSocketStore.clear()

    private const val TAG = "SinchPushSocketCtrl"

    private fun newListener(): SinchPushSocketClient.Listener {
        val mine = generation.incrementAndGet()
        return object : SinchPushSocketClient.Listener {
            override fun onMessage(message: SinchPushSocketStore.SocketMessage) {
                synchronized(stateLock) {
                    if (generation.get() == mine) SinchPushEmitter.onSocketMessage(message.toWritableMap())
                }
            }

            override fun onState(state: SinchPushSocketStore.SocketState) {
                synchronized(stateLock) {
                    if (generation.get() != mine) return
                    SinchPushSocketStore.setState(state)
                    stateSink(state)
                }
            }
        }
    }
}
