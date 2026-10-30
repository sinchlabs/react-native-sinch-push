package com.sinchpush.socket

import android.content.Context
import android.util.Log
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Wall clock, injected.
 *
 * `System.currentTimeMillis()` appears in three places that decide observable
 * behaviour - `reported_at_unix_millis`, the outbox's "not before" stamp and the
 * message's `receivedAt` - and a test that cannot set them can only assert that
 * two of them are "about now".
 */
internal interface Clock {
    fun nowMs(): Long
}

internal object SystemClock : Clock {
    override fun nowMs(): Long = System.currentTimeMillis()
}

/** A handle on something scheduled, so it can be cancelled before it fires. */
internal interface Cancellable {
    fun cancel()
}

/**
 * The client's timers, injected (SB-51).
 *
 * Reconnect and poll timing are most of what the close-handling rules are
 * about, and none of them are testable against a real clock without either
 * sleeping or accepting a 30-second test suite. `advanceBy(0)` proving that a
 * `POOL_FULL` shed did *not* redial (SB-43) is only meaningful against a clock
 * that does not move on its own.
 */
internal interface SocketScheduler {
    /** Runs [task] on the client's own single thread. */
    fun execute(task: () -> Unit)

    /** Runs [task] once, [delayMs] from now. */
    fun schedule(delayMs: Long, task: () -> Unit): Cancellable

    /** Runs [task] every [periodMs], first after [initialDelayMs]. */
    fun scheduleAtFixedRate(initialDelayMs: Long, periodMs: Long, task: () -> Unit): Cancellable
}

/** Where the client's log lines go. SB-16 needs them separable, not just present. */
internal interface SocketLogger {
    fun debug(line: String)
    fun info(line: String)
    fun warn(line: String, t: Throwable? = null)
}

internal object AndroidSocketLogger : SocketLogger {
    private const val TAG = "SinchPushSocket"

    override fun debug(line: String) {
        Log.d(TAG, line)
    }

    override fun info(line: String) {
        Log.i(TAG, line)
    }

    override fun warn(line: String, t: Throwable?) {
        if (t != null) Log.w(TAG, line, t) else Log.w(TAG, line)
    }
}

/**
 * One WebSocket connection, behind an interface.
 *
 * OkHttp's `WebSocket` is a final class whose callbacks carry the socket
 * instance; both of those are awkward to fake, and "close, then deliver a
 * trailing `onClosed` anyway" is a behaviour the rules actually depend on
 * (SB-51), so it has to be reachable from a test.
 */
internal interface WebSocketConnection {
    /** @return false when the frame could not be handed to the transport. */
    fun send(bytes: ByteArray): Boolean

    fun close(code: Int, reason: String)
}

/** Transport callbacks for one connection. Binary frames only - see [WebSocketTransport]. */
internal interface TransportListener {
    fun onOpen()
    fun onMessage(bytes: ByteArray)
    fun onFailure(t: Throwable)
    fun onClosed(code: Int, reason: String)
}

/**
 * Opens sockets, behind an interface.
 *
 * SB-01 is why the listener has no text callback: a text frame is not part of
 * the protocol and must be ignored without error, and the cheapest way to
 * guarantee that is for there to be nowhere to deliver one.
 */
internal interface WebSocketTransport {
    fun connect(url: String, listener: TransportListener): WebSocketConnection
}

/**
 * Posts the notification for a delivered message.
 *
 * @return whether a system notification was actually posted. SB-30 makes the
 *   `DISPLAYED` report conditional on this: a notification the platform refused
 *   (no `POST_NOTIFICATIONS`, a throwing `NotificationManager`) was never
 *   displayed, and reporting it as displayed would be a false record of what the
 *   user saw.
 */
internal interface NotificationPresenter {
    /**
     * @param alert false is the silent post of the replay-burst rule (SB-63):
     *   still posted and still grouped, with no sound, vibration or heads-up.
     */
    fun show(message: SinchPushSocketStore.SocketMessage, alert: Boolean): Boolean
}

/**
 * Everything the client needs from the world, in one injectable bag.
 *
 * The point is not tidiness: it is that every rule from SB-18 down is a
 * statement about time, randomness or I/O, and none of the three can be
 * observed in a JVM test while the client builds its own.
 */
internal class SocketDependencies(
    val clock: Clock,
    val scheduler: SocketScheduler,
    val random: () -> Double,
    val transport: WebSocketTransport,
    val store: SocketStateStore,
    val logger: SocketLogger,
    val notifications: NotificationPresenter,
    /**
     * The process-wide seen set, shared with the FCM service (SB-64).
     * Null builds a private one over [store], which is what a test or an
     * embedder with no other channel wants.
     */
    val seen: SeenSet? = null,
    /**
     * Called once when the relay closes with `UNAUTHORIZED` (SB-49).
     *
     * The identity layer owns the refresh itself - this is the seam it calls
     * through, and the client's own obligation ends at asking. The client stops
     * afterwards either way: `auth_required` is terminal until an identity-layer
     * action revives it.
     */
    val onAuthRequired: () -> Unit = {},
    /**
     * Whether the host registered an in-app handler; the `whenUnhandled` display
     * rule keys on it. Read per message, so a handler added after `start` takes
     * effect on the next delivery.
     */
    val handlerRegistered: () -> Boolean = { false },
    /**
     * The device facts of `Hello` fields 5, 8-12 (SB-59). The default carries
     * no device info, which is what a client built without one (a test, an
     * embedder that does not care about routing) should send;
     * [androidSocketDependencies] installs the real provider.
     *
     * See [LEGACY_DEVICE_INFO] for the default's invariant.
     */
    val deviceInfo: DeviceInfoProvider = LEGACY_DEVICE_INFO,
    /**
     * Whether the app has visible UI, read once per `Hello` on the service path
     * to compute `Hello.background = !visible` (SB-57). Unused in-process.
     */
    val appVisible: AppVisibility = AppVisibility { false },
) {
    companion object {
        /**
         * The device-info provider a client built without one gets: production's
         * own default, i.e. a legacy client that carries no device facts
         * (SB-59).
         *
         * The invariant: [DeviceInfo.sdkVersion] is clamped like the system
         * provider's - it is the one value here that JS supplies, so it is the
         * only one that can be over the relay's 128-byte cap. The other two are
         * the empty strings.
         */
        internal val LEGACY_DEVICE_INFO: DeviceInfoProvider = DeviceInfoProvider { config, _ ->
            DeviceInfo(
                installationId = "",
                platform = sinch.push.delivery.v1beta1.ws.Platform.ANDROID,
                osVersion = "",
                sdkVersion = clampUtf8(config?.resolvedSdkVersion ?: SocketSpec.DEFAULT_SDK_VERSION),
                bundleId = "",
                backgroundService = sinch.push.v1beta1.resources.BackgroundServiceState.BACKGROUND_SERVICE_STATE_UNSPECIFIED,
            )
        }
    }
}

/**
 * The production scheduler: one daemon thread, as the pre-seam client had.
 *
 * Single-threaded on purpose. The socket callbacks arrive on OkHttp's reader
 * thread and the reconnect/poll work is queued here, so every mutation of the
 * client's state happens in one order.
 */
internal class ExecutorSocketScheduler(
    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "SinchPushSocket").apply { isDaemon = true }
    },
) : SocketScheduler {

    override fun execute(task: () -> Unit) {
        executor.execute { task() }
    }

    override fun schedule(delayMs: Long, task: () -> Unit): Cancellable =
        Future(executor.schedule({ task() }, delayMs, TimeUnit.MILLISECONDS))

    override fun scheduleAtFixedRate(
        initialDelayMs: Long,
        periodMs: Long,
        task: () -> Unit,
    ): Cancellable = Future(
        executor.scheduleAtFixedRate({ task() }, initialDelayMs, periodMs, TimeUnit.MILLISECONDS),
    )

    private class Future(private val future: ScheduledFuture<*>) : Cancellable {
        override fun cancel() {
            future.cancel(false)
        }
    }
}

/**
 * OkHttp, behind [WebSocketTransport].
 *
 * The timeouts are the ones the client has always used: a 20 s protocol-level
 * ping, a 15 s connect and write timeout, and no read timeout because the read
 * side of a WebSocket is the relay's cadence, not ours.
 */
internal class OkHttpWebSocketTransport(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .build(),
) : WebSocketTransport {

    override fun connect(url: String, listener: TransportListener): WebSocketConnection {
        val socket = client.newWebSocket(
            Request.Builder().url(url).build(),
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = listener.onOpen()

                // Binary only: a text frame is not part of the protocol and is
                // not delivered anywhere (SB-01).
                override fun onMessage(webSocket: WebSocket, bytes: ByteString) =
                    listener.onMessage(bytes.toByteArray())

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                    listener.onFailure(t)

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) =
                    listener.onClosed(code, reason)
            },
        )
        return object : WebSocketConnection {
            override fun send(bytes: ByteArray): Boolean = socket.send(ByteString.of(*bytes))

            override fun close(code: Int, reason: String) {
                socket.close(code, reason)
            }
        }
    }
}

/** Posts through [SinchPushSocketNotifications]; the production presenter. */
internal class AndroidNotificationPresenter(context: Context) : NotificationPresenter {

    private val context = context.applicationContext

    override fun show(message: SinchPushSocketStore.SocketMessage, alert: Boolean): Boolean {
        // SB-65: tag = message_id, one constant id - the identity the FCM
        // rendering uses too, so a second copy replaces this one.
        val identity = SinchNotificationIdentity.of(message.id)
        return SinchPushSocketNotifications.show(
            context, message.title, message.body, identity.id, alert, tag = identity.tag,
        )
    }
}

/**
 * The dependencies a real Android host gives the client.
 *
 * Note what is *not* here: the auth token. It reaches the client through
 * `PushSocketConfig`, which is what keeps it out of [SocketStateStore].
 */
internal fun androidSocketDependencies(context: Context): SocketDependencies {
    val appContext = context.applicationContext
    return SocketDependencies(
        clock = SystemClock,
        scheduler = ExecutorSocketScheduler(),
        random = { Math.random() },
        transport = OkHttpWebSocketTransport(),
        store = SharedPreferencesSocketStateStore(appContext),
        logger = AndroidSocketLogger,
        notifications = AndroidNotificationPresenter(appContext),
        seen = SharedSeenSet.get(appContext),
        handlerRegistered = { SinchPushSocketStore.handlerRegistered },
        deviceInfo = SystemDeviceInfoProvider(
            AndroidDeviceEnvironment(appContext),
            AndroidSocketLogger,
            RelaySwitchController.switch(appContext),
        ),
        appVisible = ActivityManagerAppVisibility(),
    )
}

/**
 * Where a Sinch message's system notification lives (SB-65): `tag = message_id`,
 * `id` = [SocketSpec.SINCH_MESSAGE_NOTIFICATION_ID]. One function, used by the
 * socket presenter and by the FCM rendering, so the two cannot drift apart.
 */
internal data class SinchNotificationIdentity(val tag: String, val id: Int) {
    companion object {
        fun of(messageId: String) = SinchNotificationIdentity(messageId, SocketSpec.SINCH_MESSAGE_NOTIFICATION_ID)
    }
}
