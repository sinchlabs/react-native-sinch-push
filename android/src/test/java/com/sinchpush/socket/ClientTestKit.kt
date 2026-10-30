package com.sinchpush.socket

import sinch.push.delivery.v1beta1.ws.Ack
import sinch.push.delivery.v1beta1.ws.Close
import sinch.push.delivery.v1beta1.ws.CloseReason
import sinch.push.delivery.v1beta1.ws.DeliveryReport
import sinch.push.delivery.v1beta1.ws.Hello
import sinch.push.delivery.v1beta1.ws.HelloAck
import sinch.push.delivery.v1beta1.ws.Message as ServerMessage
import sinch.push.delivery.v1beta1.ws.Poll
import sinch.push.delivery.v1beta1.ws.Pong
import sinch.push.delivery.v1beta1.ws.PooledMessage
import sinch.push.v1beta1.resources.Alert
import sinch.push.v1beta1.resources.PushNotification

/**
 * Fakes for driving [SinchPushSocketClient] without a network, a thread or a
 * wall clock. Every rule from SB-18 down is a statement about time, randomness
 * or I/O, so all three are under the test's control.
 */
internal class FakeClock(var now: Long = 1_700_000_000_000L) : Clock {
    override fun nowMs(): Long = now
}

/**
 * Virtual-time scheduler. `execute` runs inline (the client's single thread
 * collapses to the test thread); `advanceBy(0)` runs what is due *now* and
 * nothing else, which is what SB-43 needs to be meaningful.
 */
internal class FakeScheduler(private val clock: FakeClock) : SocketScheduler {

    private class Timer(var due: Long, val period: Long?, val task: () -> Unit) : Cancellable {
        var cancelled = false
        override fun cancel() {
            cancelled = true
        }
    }

    private val timers = mutableListOf<Timer>()

    val pendingTimers: Int get() = timers.count { !it.cancelled }

    /**
     * When true, `execute` queues instead of running inline - the real client's
     * async thread hop - until [drain]. Needed where the order of an
     * asynchronous `stop()` against a synchronous caller matters (SB-60).
     */
    var deferExecute = false
    private val queued = ArrayDeque<() -> Unit>()

    override fun execute(task: () -> Unit) {
        if (deferExecute) queued.addLast(task) else task()
    }

    fun drain() {
        while (queued.isNotEmpty()) queued.removeFirst()()
    }

    override fun schedule(delayMs: Long, task: () -> Unit): Cancellable =
        Timer(clock.now + delayMs, null, task).also { timers.add(it) }

    override fun scheduleAtFixedRate(initialDelayMs: Long, periodMs: Long, task: () -> Unit): Cancellable =
        Timer(clock.now + initialDelayMs, periodMs, task).also { timers.add(it) }

    fun advanceBy(ms: Long) {
        val target = clock.now + ms
        while (true) {
            val next = timers.filter { !it.cancelled && it.due <= target }.minByOrNull { it.due } ?: break
            clock.now = maxOf(clock.now, next.due)
            if (next.period != null) next.due += next.period else next.cancelled = true
            next.task()
        }
        timers.removeAll { it.cancelled }
        clock.now = target
    }
}

internal class RecordingLogger : SocketLogger {
    val lines = mutableListOf<String>()
    override fun debug(line: String) { lines.add("D $line") }
    override fun info(line: String) { lines.add("I $line") }
    override fun warn(line: String, t: Throwable?) { lines.add("W $line") }
    fun any(text: String) = lines.any { it.contains(text) }
}

internal class FakeConnection(val url: String, val listener: TransportListener) : WebSocketConnection {
    val sentBytes = mutableListOf<ByteArray>()
    val closes = mutableListOf<Pair<Int, String>>()
    var acceptSends = true

    override fun send(bytes: ByteArray): Boolean {
        if (!acceptSends) return false
        sentBytes.add(bytes)
        return true
    }

    override fun close(code: Int, reason: String) {
        closes.add(code to reason)
    }

    /** Everything the client wrote, decoded as client->server frames. */
    val sent: List<WireMessage>
        get() = sentBytes.map { FrameCodec.decode(FrameCodec.readFrame(it, FrameDirection.CLIENT), FrameDirection.CLIENT) }

    val hellos get() = sent.filterIsInstance<Hello>()
    val polls get() = sent.filterIsInstance<Poll>()
    val reports get() = sent.filterIsInstance<DeliveryReport>()
    val pongs get() = sent.filterIsInstance<Pong>()

    fun serverOpens() = listener.onOpen()

    fun serverSends(message: WireMessage) = listener.onMessage(FrameCodec.encode(message, FrameDirection.SERVER))

    fun serverSendsRaw(bytes: ByteArray) = listener.onMessage(bytes)
}

internal class FakeTransport : WebSocketTransport {
    val connections = mutableListOf<FakeConnection>()
    var failNextConnect: Throwable? = null

    override fun connect(url: String, listener: TransportListener): WebSocketConnection {
        failNextConnect?.let { failNextConnect = null; throw it }
        return FakeConnection(url, listener).also { connections.add(it) }
    }

    val last get() = connections.last()
}

internal class FakeNotifications(var posts: Boolean = true) : NotificationPresenter {
    val shown = mutableListOf<SinchPushSocketStore.SocketMessage>()

    /** `alert` of each show, parallel to [shown] (SB-63). */
    val shownAlerting = mutableListOf<Boolean>()

    /** Runs inside `show`, before it answers - for asserting what had already happened (SB-62). */
    var onShow: ((SinchPushSocketStore.SocketMessage) -> Unit)? = null

    override fun show(message: SinchPushSocketStore.SocketMessage, alert: Boolean): Boolean {
        shown.add(message)
        shownAlerting.add(alert)
        onShow?.invoke(message)
        return posts
    }
}

internal fun testConfig(
    sdkVersion: String = "",
    pollIntervalMs: Int = 0,
    displayNotifications: Boolean = true,
    backgroundService: Boolean = true,
    displayRule: DisplayRule? = null,
) = PushSocketConfig(
    url = "wss://relay.test/ws",
    authToken = "jwt-secret-token",
    projectId = "proj-1",
    appId = "app-1",
    userId = "user-1",
    sdkVersion = sdkVersion,
    pollIntervalMs = pollIntervalMs,
    displayNotifications = displayRule ?: if (displayNotifications) DisplayRule.ALWAYS else DisplayRule.NEVER,
    backgroundService = backgroundService,
)

internal fun pooled(
    id: String,
    sinchId: String = "sinch-$id",
    title: String = "T",
    body: String = "B",
    imageUrl: String = "",
    trigger: String = "",
    enqueuedAt: Long = 42L,
) = PooledMessage(
    message_id = id,
    sinch_message_id = sinchId,
    push_notification = PushNotification(
        alert = Alert(title = title, message = body, image_url = imageUrl),
        trigger = trigger,
    ),
    enqueued_at_unix_millis = enqueuedAt,
)

internal fun pushMessage(id: String, ackToken: String = id, sinchId: String = "sinch-$id") =
    ServerMessage(ack_token = ackToken, message = pooled(id, sinchId))

internal fun helloAck(connectionId: String = "conn-1", pollMs: Int = 5000, vararg messages: PooledMessage) =
    HelloAck(connection_id = connectionId, poll_interval_ms = pollMs, messages = messages.toList())

internal fun closeFrame(reason: CloseReason, detail: String = "") = Close(reason = reason, detail = detail)

internal fun ackFor(messageId: String, status: ReportStatus, accepted: Boolean, error: String = "") =
    Ack(ack_token = "$messageId:${status.code}", accepted = accepted, error = error)

/** One client wired to fakes. [random] is what every full-jitter delay multiplies. */
internal class Harness(
    val config: PushSocketConfig = testConfig(),
    val store: SocketStateStore = InMemorySocketStateStore(),
    var random: Double = 0.5,
    notificationsPost: Boolean = true,
    var handlerRegistered: Boolean = false,
    var appVisible: Boolean = false,
    val environment: FakeDeviceEnvironment = FakeDeviceEnvironment(),
    seen: SeenSet? = null,
) {
    val clock = FakeClock()
    val scheduler = FakeScheduler(clock)
    val transport = FakeTransport()
    val logger = RecordingLogger()
    val notifications = FakeNotifications(notificationsPost)
    var authRequiredCalls = 0

    val states = mutableListOf<SinchPushSocketStore.SocketState>()
    val messages = mutableListOf<SinchPushSocketStore.SocketMessage>()

    val client = SinchPushSocketClient(
        config,
        SocketDependencies(
            clock = clock,
            scheduler = scheduler,
            random = { random },
            transport = transport,
            store = store,
            logger = logger,
            notifications = notifications,
            seen = seen,
            onAuthRequired = { authRequiredCalls++ },
            handlerRegistered = { handlerRegistered },
            deviceInfo = SystemDeviceInfoProvider(environment, logger),
            appVisible = AppVisibility { appVisible },
        ),
    ).apply {
        setListener(object : SinchPushSocketClient.Listener {
            override fun onMessage(message: SinchPushSocketStore.SocketMessage) { messages.add(message) }
            override fun onState(state: SinchPushSocketStore.SocketState) { states.add(state) }
        })
    }

    val status get() = states.last().status
    val state get() = states.last()
    val conn get() = transport.last

    fun start() = client.start()

    /** Opens the newest socket and answers the Hello. */
    fun connect(connectionId: String = "conn-1", pollMs: Int = 5000, vararg messages: PooledMessage) {
        conn.serverOpens()
        conn.serverSends(helloAck(connectionId, pollMs, *messages))
    }

    fun startAndConnect(connectionId: String = "conn-1", pollMs: Int = 5000, vararg messages: PooledMessage) {
        start()
        connect(connectionId, pollMs, *messages)
    }
}


/** [DeviceEnvironment] with every Android answer settable, and a log of how often the store was asked. */
internal class FakeDeviceEnvironment(
    var osVersion: String = "14",
    var bundleId: String = "com.example.host",
    var installationId: String? = "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11",
    var serviceRunning: Boolean = true,
    var notificationPermissionGranted: Boolean = true,
    /**
     * When set, [serviceRunning] is read from it on every call instead of from
     * the field - the way `AndroidDeviceEnvironment` reads `SocketServiceState`
     * at each Hello.
     */
    var serviceRunningSource: (() -> Boolean)? = null,
) : DeviceEnvironment {
    var installationIdCalls = 0

    override fun osVersion() = osVersion
    override fun bundleId() = bundleId
    override fun installationId(): String {
        installationIdCalls++
        return installationId ?: throw InstallationIdUnavailableException("keystore unavailable")
    }
    override fun serviceRunning() = serviceRunningSource?.invoke() ?: serviceRunning
    override fun notificationPermissionGranted() = notificationPermissionGranted
}
