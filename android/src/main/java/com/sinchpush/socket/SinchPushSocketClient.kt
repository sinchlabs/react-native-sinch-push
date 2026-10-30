package com.sinchpush.socket

import com.squareup.wire.ProtoReader
import okio.Buffer
import sinch.push.delivery.v1beta1.ws.Ack
import sinch.push.delivery.v1beta1.ws.AuthChallenge
import sinch.push.delivery.v1beta1.ws.Close
import sinch.push.delivery.v1beta1.ws.CloseReason
import sinch.push.delivery.v1beta1.ws.DeliveryReport
import sinch.push.delivery.v1beta1.ws.Hello
import sinch.push.delivery.v1beta1.ws.HelloAck
import sinch.push.delivery.v1beta1.ws.Message as ServerMessage
import sinch.push.delivery.v1beta1.ws.Ping
import sinch.push.delivery.v1beta1.ws.Poll
import sinch.push.delivery.v1beta1.ws.Pong
import sinch.push.delivery.v1beta1.ws.PooledMessage

/**
 * The WebSocket delivery client (the Kotlin half of SB-18 … SB-57).
 *
 * Behaviour is pinned by `docs/socket-behaviour-spec.md`; each rule this class
 * implements says so in the comment beside it. Everything the client needs from
 * the world - clock, timers, randomness, transport, storage, logging, the
 * notification surface - arrives through [SocketDependencies], which is what
 * makes the close/backoff/report rules observable from a JVM test instead of
 * from a device log.
 *
 * The reference implementation of the same behaviour is the TypeScript snapshot
 * at tag `ts-socket-client-snapshot` (`src/pushSocket/client.ts`). Android and
 * iOS must not shed, defer or report differently on the same relay, so a change
 * here wants a matching change there.
 */
internal class SinchPushSocketClient(
    private val config: PushSocketConfig,
    private val deps: SocketDependencies,
) {

    interface Listener {
        fun onMessage(message: SinchPushSocketStore.SocketMessage)
        fun onState(state: SinchPushSocketStore.SocketState)
    }

    private val clock = deps.clock
    private val logger = deps.logger
    private val scheduler = deps.scheduler
    // SB-64: the process-wide set when the host supplies it (FCM dedupes through
    // the same instance); a private one over the store otherwise.
    private val seen = deps.seen ?: SeenSet(deps.store, SocketSpec.SEEN_SET_CAPACITY)
    private val tracker = ReportTracker(
        store = deps.store,
        clock = clock,
        logger = logger,
        // SB-33: a rate-limited report waits out the backoff this client is
        // already honouring, so a throttled relay is not hit from two sides.
        serverPressureCeilingMs = { serverPressureCeilingMs() },
    )

    private var pollFuture: Cancellable? = null
    private var reconnectFuture: Cancellable? = null

    @Volatile private var socket: WebSocketConnection? = null
    @Volatile private var connected: Boolean = false
    @Volatile private var connectionId: String? = null
    @Volatile private var pollIntervalMs: Int = 0
    @Volatile private var reconnectAttempts: Int = 0
    @Volatile private var lastError: String? = null
    @Volatile private var stopped: Boolean = false

    /** SB-44: `reconnectAttempts` before this session's handshake zeroed it. */
    @Volatile private var reconnectAttemptsBeforeHelloAck: Int = 0

    /** SB-44: the handshake's reset is a claim the session has not yet backed up. */
    @Volatile private var helloAckResetArmed: Boolean = false

    @Volatile private var currentListener: Listener? = null

    /** Which connection attempt is live; bumped to retire one (SB-51). */
    private val epochs = java.util.concurrent.atomic.AtomicInteger(0)

    fun setListener(listener: Listener) {
        currentListener = listener
    }

    fun start() {
        scheduler.execute {
            stopped = false
            reconnectAttempts = 0
            openSocket()
        }
    }

    fun stop() {
        scheduler.execute {
            stopped = true
            cancelTimers()
            closeSocket(1000, "client stop")
            publishState(STATUS_STOPPED)
        }
    }

    /**
     * SB-30: the host entry point behind `reportPushMessageStatus`.
     *
     * Routed through the scheduler like every other state mutation, and safe
     * when no socket exists - the report goes to the outbox and goes out after
     * the next `HelloAck` (SB-35), which is the whole reason a `DISMISSED`
     * raised while the app was in the background still reaches the relay.
     */
    fun reportStatus(messageId: String, status: ReportStatus) {
        scheduler.execute {
            tracker.report(messageId, "", status, reason = "", reportTransport())
        }
    }

    // ---------------------------------------------------------------- open

    /**
     * The backoff ceiling a rate-limited report defers against (SB-33).
     *
     * The same ceiling the reconnect path is using right now: while the relay is
     * shedding, a report and a reconnect both waiting inside one jitter window
     * is exactly the two-direction pressure the deferral exists to avoid.
     */
    private fun serverPressureCeilingMs(): Long =
        reconnectCeilingMs(maxOf(reconnectAttempts, 1))

    /**
     * SB-20: publish `connecting` or `reconnecting`, then dial.
     *
     * `lastError` is cleared here, before the state is published, so a previous
     * failure cannot survive into a fresh attempt (SB-24).
     */
    private fun openSocket() {
        if (stopped) return
        lastError = null
        publishState(if (reconnectAttempts == 0) STATUS_CONNECTING else STATUS_RECONNECTING)
        try {
            // Each attempt gets a fresh epoch. OkHttp has no equivalent of
            // nulling a socket's handlers, so a replaced socket keeps delivering
            // callbacks; the epoch is what makes those inert (SB-51).
            val attempt = epochs.incrementAndGet()
            socket = deps.transport.connect(config.url, SocketListener(attempt))
        } catch (t: Throwable) {
            handleDisconnect("open failed: ${t.message ?: t.javaClass.simpleName}")
        }
    }

    /**
     * One transport callback set per socket, tied to the attempt that opened it.
     *
     * OkHttp delivers the callbacks on its own thread, so every one of them is
     * hopped onto the scheduler and checks its epoch there: an attempt that is
     * no longer current is dropped, which is what stops one `Close` from
     * becoming two reconnects. [closeSocket] bumps the epoch before it closes,
     * so the `onClosed` / `onFailure` the close provokes fail the check instead
     * of scheduling a second retry and re-incrementing the attempt counter.
     *
     * The TypeScript client gets this from `closeSocket()` nulling its handlers
     * before closing; OkHttp offers no equivalent, so this stands in for it.
     */
    private inner class SocketListener(
        private val attempt: Int,
    ) : TransportListener {

        override fun onOpen() {
            onScheduler { sendFrame(hello()) }
        }

        override fun onMessage(bytes: ByteArray) {
            onScheduler { onBinaryMessage(bytes) }
        }

        override fun onFailure(t: Throwable) {
            onScheduler { handleDisconnect(t.message ?: t.javaClass.simpleName) }
        }

        override fun onClosed(code: Int, reason: String) {
            onScheduler { handleDisconnect("socket closed (code=$code, reason=$reason)") }
        }

        private fun onScheduler(task: () -> Unit) {
            scheduler.execute {
                if (!isCurrent()) return@execute
                task()
            }
        }

        private fun isCurrent(): Boolean = epochs.get() == attempt
    }

    /**
     * SB-18: the first frame on an open socket, with every field the relay reads.
     *
     * `platform` is `ANDROID` because that is the OS - never because
     * `background` is set (SB-19). `last_seen_message_id` is the newest id this
     * installation has processed (SB-29), which is why it is read from the store
     * rather than written as `""`. Fields 9-12 come from the device-info
     * provider on every Hello, not once per client, so an installation id that
     * was unavailable on one connect is asked for again on the next (SB-59),
     * and `background_service` reflects the service as it is *now*.
     */
    private fun hello(): Hello {
        val device = deps.deviceInfo.current(config, DeviceInfoPurpose.HELLO)
        return Hello(
            auth_token = config.authToken,
            project_id = config.projectId,
            app_id = config.appId,
            user_id = config.userId,
            platform = device.platform,
            background = helloBackground(),
            last_seen_message_id = deps.store.loadLastSeenMessageId(),
            sdk_version = device.sdkVersion,
            installation_id = device.installationId,
            os_version = device.osVersion,
            bundle_id = device.bundleId,
            background_service = device.backgroundService,
        )
    }

    /**
     * SB-57: `false` in-process, `!appVisible` at connect on the service path.
     *
     * Computed here, from the owner the config selects, instead of being read
     * from a config flag: the flag defaulted to `true`, so an in-process socket
     * told the relay it was the background service and the relay routed to it
     * accordingly.
     */
    private fun helloBackground(): Boolean =
        ownerFor(config) == SocketOwner.SERVICE && !deps.appVisible.isVisible()

    // -------------------------------------------------------------- inbound

    /**
     * SB-16: an undecodable frame is dropped, never fatal - but the two failure
     * classes are logged separately, because they mean different things.
     *
     * An unknown tag is a peer ahead of this build and the bytes around it are
     * fine. A malformed envelope means the bytes are wrong whoever reads them.
     * Logging the two separately is what makes the first one diagnosable from a
     * bug report.
     */
    private fun onBinaryMessage(bytes: ByteArray) {
        val frame = try {
            FrameCodec.readFrame(bytes, FrameDirection.SERVER)
        } catch (e: UnknownFrameTagException) {
            logger.info("ignoring ${e.message}")
            return
        } catch (e: MalformedFrameException) {
            logger.warn("dropping malformed server frame (${e.reason.name}): ${e.message}")
            return
        } catch (t: Throwable) {
            logger.warn("frame decode failed", t)
            return
        }
        val payload = try {
            FrameCodec.decode(frame, FrameDirection.SERVER)
        } catch (t: Throwable) {
            onPayloadDecodeFailure(frame, t)
            return
        }
        handleFrame(payload)
    }

    /**
     * SB-40: a payload that will not decode is a `FAILED` report, not silence.
     *
     * The id is salvaged from the raw bytes with the library's own reader so the
     * report is not empty - `FAILED` with no `message_id` would be refused as
     * `missing_message_id`, and a report that never reaches the relay records
     * nothing. When no id can be recovered the frame is dropped with a log line,
     * which is SB-31 winning over SB-40 rather than either being violated.
     */
    private fun onPayloadDecodeFailure(frame: FrameCodec.DecodedFrame, t: Throwable) {
        val reason = "decode: ${t.message ?: t.javaClass.simpleName}"
        if (frame.tag != FrameCodec.SERVER_TAG_MESSAGE) {
            logger.warn("dropping undecodable ${frame.payloadType} frame ($reason)", t)
            return
        }
        val ids = salvagePooledMessageIds(frame.payload)
        if (ids == null || ids.first.isEmpty()) {
            logger.warn("dropping undecodable message frame with no recoverable message_id ($reason)", t)
            return
        }
        logger.warn("reporting ${ids.first} as FAILED ($reason)")
        tracker.report(ids.first, ids.second, ReportStatus.FAILED, reason, reportTransport())
    }

    /**
     * Reads `message_id` / `sinch_message_id` out of an undecodable `Message`.
     *
     * `PooledMessage` field numbers, walked with `ProtoReader` - the same reader
     * the generated code uses - and every field that is not one of those two is
     * skipped without being interpreted. That is what makes it possible to
     * recover the id from a frame whose *alert* is what failed to decode.
     *
     * This is a salvage path, never a decision: nothing is delivered or reported
     * on the strength of what comes out of here except a `FAILED` whose id the
     * relay can match. Any doubt (an exception, an absent field) returns null and
     * the frame is dropped.
     */
    private fun salvagePooledMessageIds(payload: ByteArray): Pair<String, String>? {
        return try {
            var messageId = ""
            var sinchMessageId = ""
            val reader = ProtoReader(Buffer().write(payload))
            val outer = reader.beginMessage()
            while (true) {
                val tag = reader.nextTag()
                if (tag == -1) break
                if (tag != MESSAGE_FIELD_POOLED_MESSAGE) {
                    reader.skip()
                    continue
                }
                val inner = reader.beginMessage()
                while (true) {
                    val innerTag = reader.nextTag()
                    if (innerTag == -1) break
                    when (innerTag) {
                        POOLED_MESSAGE_FIELD_MESSAGE_ID -> messageId = reader.readString()
                        POOLED_MESSAGE_FIELD_SINCH_MESSAGE_ID -> sinchMessageId = reader.readString()
                        else -> reader.skip()
                    }
                }
                reader.endMessageAndGetUnknownFields(inner)
            }
            reader.endMessageAndGetUnknownFields(outer)
            if (messageId.isEmpty()) null else (messageId to sinchMessageId)
        } catch (t: Throwable) {
            logger.debug("could not salvage a message id from an undecodable frame: ${t.message}")
            null
        }
    }

    private fun handleFrame(payload: WireMessage) {
        when (payload) {
            is HelloAck -> onHelloAck(payload)
            is ServerMessage -> onMessage(payload)
            is Ack -> onAck(payload)
            is Ping -> {
                // SB-38: echo `correlation_id` verbatim, on the same connection,
                // without touching the poll timer or the backoff budget.
                sendFrame(Pong(correlation_id = payload.correlation_id))
            }
            is AuthChallengeFrame -> {
                // SB-39: reserved for a future handshake step. Logged, and the
                // connection is left alone - this is a known frame type, not an
                // error.
                logger.info("AuthChallenge received; reserved for a future handshake step, keeping the connection")
            }
            is Close -> handleClose(payload)
            else -> logger.debug("ignoring unhandled frame ${payload.javaClass.simpleName}")
        }
    }

    /**
     * SB-21: everything a `HelloAck` owes the client.
     *
     * Publish `connected`, resolve the poll interval, emit the pooled messages
     * it carries (with an empty `ack_token` - the `HelloAck` carries no
     * per-message token), arm the backoff reset, send one immediate `Poll`
     * (SB-23) and flush the outbox (SB-35).
     *
     * The order of the last two is the rule: the poll is the handshake's own
     * request for work, and the outbox is what the previous session could not
     * send.
     */
    private fun onHelloAck(ack: HelloAck) {
        connected = true
        connectionId = ack.connection_id
        lastError = null
        noteHelloAck()
        pollIntervalMs = resolvePollIntervalMs(ack.poll_interval_ms)
        publishState(STATUS_CONNECTED)
        for (pooled in ack.messages) {
            deliverMessage(pooled, ackToken = "")
        }
        sendFrame(Poll())
        schedulePoll()
        tracker.flushOutbox(reportTransport())
    }

    /**
     * SB-22: config > server > default, then raised to the 1000 ms floor.
     *
     * The floored value is what is published *and* what the timer uses.
     */
    private fun resolvePollIntervalMs(serverPollIntervalMs: Int): Int {
        val requested = when {
            config.pollIntervalMs > 0 -> config.pollIntervalMs
            serverPollIntervalMs > 0 -> serverPollIntervalMs
            else -> SocketSpec.DEFAULT_POLL_MS
        }
        return maxOf(requested, SocketSpec.MIN_POLL_MS)
    }

    /** SB-46: a pooled message arrived, so the session is doing real work. */
    private fun onMessage(message: ServerMessage) {
        noteSessionWork()
        val pooled = message.message
        if (pooled == null) {
            // SB-40: the frame carried no pooled message. There is no id to
            // report against, and an empty one is refused by the relay, so this
            // is a drop with a log line rather than a report.
            logger.warn("message frame without a pooled message; nothing to deliver or report")
            return
        }
        deliverMessage(pooled, message.ack_token)
    }

    /**
     * SB-25 … SB-31: one delivered message.
     *
     * The dedupe key is `message_id` and never `ack_token` (SB-25): the relay
     * mints the two separately on at least one path, so a token-shaped key is
     * not safe - and the report Ack's `:<status>` suffix makes it doubly so.
     *
     * A dedupe hit suppresses *presentation* only: no event, no notification
     * (SB-27). The report still goes out, because the relay handed this
     * message to this socket and is waiting for the ack - staying silent records
     * an `ACK_TIMEOUT` and sinch-push answers it with a duplicate push. The
     * tracker keeps that at one `DELIVERED` per `(message_id, status)` (SB-30), so
     * the relay re-offering the same message on the next `Poll` - or a restart
     * replaying an id already acked - sends nothing further.
     */
    private fun deliverMessage(pooled: PooledMessage, ackToken: String) {
        val id = pooled.message_id
        if (id.isEmpty()) {
            // SB-31: nothing is reported against an empty id; the relay refuses
            // such a report as `missing_message_id`.
            logger.warn("dropping a pooled message with an empty message_id")
            return
        }
        if (!seen.add(id)) {
            // SB-64: the set is shared with FCM, so a hit may be an id another
            // channel processed first. The cursor still advances (same
            // never-regress rule): some channel has processed this id, so the
            // relay has no reason to replay it (SB-29). But a hit moves it only on
            // a known, strictly newer timestamp.
            advanceLastSeen(id, pooled.enqueued_at_unix_millis, onHit = true)
            // The dedupe is about presentation, not about the ack. This socket
            // was handed the message and the relay is waiting for its DELIVERED
            // - staying silent on a cross-channel hit records an ACK_TIMEOUT and
            // sinch-push sends the push again. `report` is once per
            // `(message_id, status)` (SB-30), so a socket duplicate, or a restart
            // replaying an id already acked, sends nothing. No event, no
            // notification below this line: a message another channel already
            // showed must not be shown twice.
            tracker.report(id, pooled.sinch_message_id, ReportStatus.DELIVERED, reason = "", reportTransport())
            logger.debug("duplicate message $id; acked, no event, no notification")
            return
        }
        // SB-62: the relay waits 5 s (Android) for DELIVERED before it falls back
        // to FCM, so nothing but the two writes that make the report honest -
        // the seen set (persisted by `add`) and the replay cursor - runs ahead of
        // it. A crash after the ack must not turn the replay into a second
        // DELIVERED. Everything below, including the host listener and the
        // notification, runs after the report has been handed to the socket.
        advanceLastSeen(id, pooled.enqueued_at_unix_millis)
        tracker.report(id, pooled.sinch_message_id, ReportStatus.DELIVERED, reason = "", reportTransport())

        val pn = pooled.push_notification
        val alert = pn?.alert
        val message = SinchPushSocketStore.SocketMessage(
            id = id,
            sinchMessageId = pooled.sinch_message_id,
            ackToken = ackToken,
            // SB-36: proto3 has no presence for a scalar string, so an empty
            // field and an absent one are the same value. Mapping `""` to null
            // here - at the model, not only at the notification - is what keeps
            // the two transports showing the same thing for the same message.
            title = alert?.title?.takeIf { it.isNotEmpty() },
            body = alert?.message?.takeIf { it.isNotEmpty() },
            imageUrl = alert?.image_url?.takeIf { it.isNotEmpty() },
            metadata = pn?.metadata ?: emptyMap(),
            importance = pn?.importance?.value ?: 0,
            trigger = pn?.trigger?.takeIf { it.isNotEmpty() },
            enqueuedAt = pooled.enqueued_at_unix_millis,
            receivedAt = clock.nowMs(),
            background = config.backgroundService,
            shown = false,
        )
        // A host listener that throws must not take the notification (or the
        // service's socket thread) down with it; the DELIVERED is already out.
        runCatching {
            SinchPushSocketStore.recordMessage(message)
            currentListener?.onMessage(message)
        }.onFailure { logger.warn("message listener failed for $id: ${it.message}") }
        // SB-30: a notification that was actually posted is a DISPLAYED. One
        // the platform refused was never shown, and saying otherwise writes a
        // record of a screen the user never saw.
        if (shouldDisplayNotification() && showNotification(message)) {
            tracker.report(id, pooled.sinch_message_id, ReportStatus.DISPLAYED, reason = "", reportTransport())
        }
    }

    /**
     * SB-29: `last_seen_message_id` is the newest *received* id, persisted on
     * every dedupe miss and on a hit (an id any channel has processed).
     *
     * Relay ids are opaque (random hex), so "newest" is decided by the message's
     * own `enqueued_at_unix_millis`: the cursor only advances when this message
     * was enqueued at or after the one it names, so an older message that arrives
     * after a newer one (a `Poll` drain or a replay overtaking a live push) does
     * not walk it back and make the next replay re-send everything in between.
     * A message with no timestamp, or a cursor with none, falls back to arrival
     * order. Either way the seen set - never the cursor - is what dedupes (SB-27).
     *
     * A dedupe hit ([onHit]) is stricter: it moves the cursor only when its
     * timestamp is known and strictly newer than the stored one (or nothing is
     * stored), never on a tie or an unknown timestamp.
     */
    private fun advanceLastSeen(id: String, enqueuedAtMs: Long, onHit: Boolean = false) {
        val stored = deps.store.loadLastSeenEnqueuedAtMs()
        if (onHit && !(enqueuedAtMs > 0 && (stored == 0L || enqueuedAtMs > stored))) return
        val known = enqueuedAtMs > 0 && stored > 0
        if (known && enqueuedAtMs < stored) return
        deps.store.saveLastSeen(id, maxOf(enqueuedAtMs, 0L))
    }

    /** When the last alerting notification was posted; null before the first (SB-63). */
    private var lastAlertAtMs: Long? = null

    /**
     * SB-63: posts [message], alerting only if no alerting notification was
     * posted within `NOTIFICATION_ALERT_WINDOW_MS`. The slot is taken when the
     * post is attempted, not when it is accepted, so a burst cannot all alert
     * because the first completion had not run yet.
     */
    private fun showNotification(message: SinchPushSocketStore.SocketMessage): Boolean {
        val now = clock.nowMs()
        val last = lastAlertAtMs
        val alert = last == null || now - last >= SocketSpec.NOTIFICATION_ALERT_WINDOW_MS
        if (alert) lastAlertAtMs = now
        return runCatching { deps.notifications.show(message, alert) }
            .onFailure { logger.warn("notification failed for ${message.id}: ${it.message}") }
            .getOrDefault(false)
    }

    /**
     * The three-value display rule; `whenUnhandled` yields to a registered handler
     * only while the app is visible: in the background the handler can't show it.
     */
    private fun shouldDisplayNotification(): Boolean = when (config.displayNotifications) {
        DisplayRule.NEVER -> false
        DisplayRule.ALWAYS -> true
        DisplayRule.WHEN_UNHANDLED -> !deps.handlerRegistered() || !deps.appVisible.isVisible()
    }

    /**
     * SB-32, SB-33, SB-34: one inbound report Ack.
     *
     * `accepted` - not arrival - is what counts as session work. A rejection
     * proves the session is under pressure, and `rate_limited` is specifically
     * the report budget shedding us: spending the backoff reset on it would
     * recreate the attempt-1 loop the budget exists to prevent. Every rejection
     * publishes `lastError` (SB-33).
     */
    private fun onAck(ack: Ack) {
        val outcome = tracker.onAck(ack.ack_token, ack.accepted, ack.error)
        if (ack.accepted) {
            noteSessionWork()
        } else {
            lastError = outcome.error ?: "report rejected: ${ack.error.ifEmpty { "no reason" }}"
            publishState(currentStatus())
        }
        logger.info(
            "ack accepted=${ack.accepted}" +
                (ack.error.takeIf { it.isNotEmpty() }?.let { " error=$it" } ?: "") +
                (outcome.action.takeIf { it != AckAction.NONE }?.let { " action=${it.name.lowercase()}" } ?: ""),
        )
    }

    // ------------------------------------------------------------- backoff

    /**
     * SB-44: zero the budget and arm the reset, remembering what it cost.
     *
     * "Armed" means the zeroing is a claim about this session that the session
     * has not yet backed up. It is spent by [noteSessionWork] and forfeited by a
     * budget denial in [handleDisconnect].
     */
    private fun noteHelloAck() {
        reconnectAttemptsBeforeHelloAck = reconnectAttempts
        reconnectAttempts = 0
        helloAckResetArmed = true
    }

    /**
     * SB-46: the session did real work, so the `HelloAck` reset is earned.
     *
     * Real work is exactly one of two things: a pooled message arrived, or a
     * report was answered `accepted = true`. A bare poll deliberately does not
     * count - the relay answers a poll that drains nothing with silence, so
     * "polling politely" is indistinguishable on the wire from "hanging off a
     * connection that is about to be refused".
     */
    private fun noteSessionWork() {
        helloAckResetArmed = false
    }

    // ---------------------------------------------------------------- poll

    private fun schedulePoll() {
        cancelPoll()
        val interval = pollIntervalMs.toLong()
        pollFuture = scheduler.scheduleAtFixedRate(interval, interval) {
            if (stopped) return@scheduleAtFixedRate
            val ws = socket ?: return@scheduleAtFixedRate
            if (!sendFrame(ws, Poll())) {
                cancelPoll()
                return@scheduleAtFixedRate
            }
            // SB-35: the outbox is not flushed on the poll tick while the relay
            // is shedding. That tick is the traffic it is shedding.
            if (!tracker.isShedding()) {
                tracker.retryDue(reportTransport())
            }
        }
    }

    private fun cancelPoll() {
        pollFuture?.cancel()
        pollFuture = null
    }

    // --------------------------------------------------------------- close

    /**
     * SB-41: the close-reason matrix.
     *
     * `STALE`, `UNAUTHORIZED` and `BG_RESUMED` each have their own behaviour;
     * `POOL_FULL`, `SHUTDOWN`, `INTERNAL` and an unspecified reason are all the
     * same retryable server pressure and must be indistinguishable from each
     * other - an established session that exceeds a budget is closed with
     * `POOL_FULL` and detail `rate_limited`, and that has to travel the same path
     * as any other transient condition.
     */
    private fun handleClose(close: Close) {
        when (close.reason) {
            // The credential is still good and only a fresh `Hello` is missing,
            // so this reconnects at once with no backoff spent (SB-47).
            CloseReason.STALE -> {
                handleStale(close.detail)
                return
            }
            // Terminal: the token is bad and only an identity-layer refresh can
            // revive the client (SB-48, SB-49).
            CloseReason.UNAUTHORIZED -> {
                handleAuthRequired(close)
                return
            }
            // Another surface owns the session; do not fight it (SB-49).
            CloseReason.BG_RESUMED -> {
                handleReplaced()
                return
            }
            else -> Unit
        }
        handleDisconnect(
            detailOr(close, "server closed (reason=${close.reason.value})"),
            shed = close.reason == CloseReason.POOL_FULL,
        )
    }

    /**
     * SB-48: `UNAUTHORIZED` stops the client for good.
     *
     * Timers cancelled and the socket closed before the state is published, so
     * nothing can open a socket afterwards (SB-53), and the status is the
     * distinct `auth_required` rather than a generic `error` (SB-49): a host
     * that can refresh a credential has to be able to tell that case from the
     * relay being broken.
     */
    private fun handleAuthRequired(close: Close) {
        stopped = true
        connected = false
        cancelTimers()
        closeSocket(1000, "server close")
        lastError = detailOr(close, "server closed (reason=${close.reason.value})")
        publishState(STATUS_AUTH_REQUIRED)
        // One refresh attempt, and only one: the hook is the seam the identity
        // layer fills in. Whether it succeeded is not this client's business -
        // the client stays stopped either way.
        if (!authRequiredNotified) {
            authRequiredNotified = true
            try {
                deps.onAuthRequired()
            } catch (t: Throwable) {
                logger.warn("onAuthRequired failed", t)
            }
        }
    }

    /** SB-49: another surface took the session over. Stop, and do not reconnect. */
    private fun handleReplaced() {
        stopped = true
        connected = false
        cancelTimers()
        closeSocket(1000, "server close")
        publishState(STATUS_REPLACED)
    }

    /**
     * SB-47: `STALE` reconnects immediately, with a fresh `Hello` and no timer.
     *
     * The session hit its server-side TTL on the relay's schedule; backing off
     * would add delay this client did not need. The attempt count is reset
     * because the next failure is a genuinely new one.
     */
    private fun handleStale(detail: String) {
        connected = false
        cancelTimers()
        closeSocket(1000, "session stale")
        if (stopped) {
            publishState(STATUS_STOPPED)
            return
        }
        logger.info("session stale, reconnecting immediately${detail.takeIf { it.isNotEmpty() }?.let { " ($it)" } ?: ""}")
        reconnectAttempts = 0
        openSocket()
    }

    /**
     * The socket is gone. Unless [shed], this is attempt N+1 from the base delay.
     *
     * @param shed the close was a server budget denial. `POOL_FULL` is emitted
     *   only by the relay's rate limiters and always carries detail
     *   `rate_limited`, so the *reason* is an exact discriminator and survives a
     *   detail rename (SB-45).
     */
    private fun handleDisconnect(reason: String, shed: Boolean = false) {
        connected = false
        // cancelTimers, not just cancelPoll: a pending reconnect is dropped
        // before another is scheduled, so repeated sheds cannot stack timers and
        // open several sockets at once (SB-51).
        cancelTimers()
        // Close before dropping the reference (SB-51). Nulling first leaves a
        // socket the relay has not closed yet running with nobody driving it -
        // it keeps its poll timer, its connection and its battery cost, and only
        // the identity guard stops it opening a second reconnect.
        closeSocket(1000, "socket gone")
        if (stopped) {
            publishState(STATUS_STOPPED)
            return
        }
        if (shed && helloAckResetArmed) {
            // SB-45: forfeit the reset. This handshake completed and was then
            // refused, so the zeroing it bought was never real; restore the
            // recorded pre-handshake count and let this attempt stack on top,
            // which is what makes repeated denials climb to the 30s cap instead
            // of restarting at 1.
            helloAckResetArmed = false
            reconnectAttempts = reconnectAttemptsBeforeHelloAck
        }
        reconnectAttempts += 1
        lastError = reason
        publishState(STATUS_RECONNECTING)
        val delay = reconnectDelayMs(reconnectAttempts, deps.random)
        reconnectFuture = scheduler.schedule(delay) {
            if (!stopped) openSocket()
        }
    }

    private fun detailOr(close: Close, fallback: String): String =
        close.detail.takeIf { it.isNotEmpty() } ?: fallback

    /**
     * Closes the current socket and drops the reference to it.
     *
     * The field is nulled before [WebSocketConnection.close] returns so the
     * callbacks the close provokes - OkHttp delivers `onClosed` and sometimes
     * `onFailure` afterwards - fail [SocketListener.isCurrent] instead of
     * driving a second reconnect.
     */
    private fun closeSocket(code: Int, reason: String) {
        val ws = socket
        socket = null
        connected = false
        // Retire the attempt *before* closing (SB-51): a close that provokes a
        // trailing `onClosed` synchronously, or one that provokes it later, must
        // not find a live attempt to drive.
        epochs.incrementAndGet()
        try {
            ws?.close(code, reason)
        } catch (t: Throwable) {
            logger.warn("closing the socket failed", t)
        }
    }

    /** SB-53: every terminal and stale transition clears both timers first. */
    private fun cancelTimers() {
        cancelPoll()
        reconnectFuture?.cancel()
        reconnectFuture = null
    }

    // ----------------------------------------------------------------- out

    private fun currentStatus(): String = when {
        stopped -> STATUS_STOPPED
        connected -> STATUS_CONNECTED
        reconnectAttempts > 0 -> STATUS_RECONNECTING
        else -> STATUS_CONNECTING
    }

    private fun publishState(status: String) {
        val snapshot = SinchPushSocketStore.SocketState(
            status = status,
            connectionId = connectionId,
            pollIntervalMs = pollIntervalMs,
            reconnectAttempts = reconnectAttempts,
            lastError = lastError,
        )
        // The shared store is written by the listener, not here: the controller
        // mutes a stopping client's listener, and a late `stopped` must not
        // overwrite a service error in the store either (SB-60).
        currentListener?.onState(snapshot)
    }

    /**
     * Sends a report if the session can take it, and says so.
     *
     * False is what puts a report into the outbox (SB-35). "Connected" means the
     * handshake completed, not merely that a socket object exists.
     */
    private fun reportTransport(): ReportTransport = object : ReportTransport {
        override fun send(report: PendingReport): Boolean {
            if (stopped || !connected) return false
            val ws = socket ?: return false
            return sendFrame(
                ws,
                DeliveryReport(
                    // SB-31 / SB-37: the pooled id, the one the upstream sink
                    // receives as `channel_message_id`, and never the Sinch id.
                    message_id = report.messageId,
                    sinch_message_id = report.sinchMessageId,
                    status = report.status.wire,
                    reason = report.reason,
                    reported_at_unix_millis = clock.nowMs(),
                ),
            )
        }
    }

    private fun sendFrame(message: WireMessage): Boolean = sendFrame(socket, message)

    private fun sendFrame(ws: WebSocketConnection?, message: WireMessage): Boolean {
        if (ws == null) return false
        return try {
            // Everything this client sends is a ClientFrame, so the direction is
            // CLIENT for every message below; FrameCodec refuses anything that is
            // not a ClientFrame oneof member rather than framing it with a
            // server-only tag.
            ws.send(FrameCodec.encode(message, FrameDirection.CLIENT))
        } catch (t: Throwable) {
            logger.warn("send failed", t)
            false
        }
    }

    @Volatile
    private var authRequiredNotified: Boolean = false

    companion object {
        private const val STATUS_CONNECTING = "connecting"
        private const val STATUS_CONNECTED = "connected"
        private const val STATUS_RECONNECTING = "reconnecting"
        private const val STATUS_STOPPED = "stopped"

        /** SB-49 (resolved): `UNAUTHORIZED` gets its own status, not `error`. */
        const val STATUS_AUTH_REQUIRED = "auth_required"

        /** SB-49 (resolved): `BG_RESUMED` gets its own status, not `stopped`. */
        const val STATUS_REPLACED = "replaced"

        /** `Message.message` and `PooledMessage.message_id` field numbers. */
        private const val MESSAGE_FIELD_POOLED_MESSAGE = 2
        private const val POOLED_MESSAGE_FIELD_MESSAGE_ID = 1
        private const val POOLED_MESSAGE_FIELD_SINCH_MESSAGE_ID = 2

        /**
         * SB-42: full jitter - `random(0, min(30s, 1s * 2^(n-1)))`.
         *
         * Full jitter, not an additive spread: throttling sheds a whole cohort
         * of devices at the same instant, and an additive 250 ms spread leaves
         * them all retrying inside that same quarter second, so the retry storm
         * reproduces the overload that caused it.
         *
         * The delay can legitimately be 0: the first retry after a shed is
         * immediate, which is correct - the socket was closed for load-shedding,
         * not because anything is wrong with this device.
         *
         * Kept byte-for-byte equivalent to `reconnectDelayMs` in the TypeScript
         * snapshot. If you change one, change both: the two platforms must not
         * put different retry pressure on the same relay.
         */
        internal fun reconnectDelayMs(attempts: Int): Long =
            reconnectDelayMs(attempts) { Math.random() }

        internal fun reconnectDelayMs(attempts: Int, random: () -> Double): Long =
            (random() * reconnectCeilingMs(attempts)).toLong()

        /**
         * `min(30s, 1s * 2^(n-1))`, built by doubling rather than by shifting.
         *
         * The shift form is equivalent for every `n` a retry count can reach, but
         * it wraps negative past 63 and then reads as a *smaller* ceiling than
         * the base delay - a disconnect that backs off harder the longer it has
         * been failing. Doubling saturates at the cap for every `n`, which is
         * also what the TypeScript `Math.min` does with an exponent that has
         * overflowed to infinity.
         */
        internal fun reconnectCeilingMs(attempts: Int): Long {
            require(attempts >= 1) { "attempts must be >= 1, was $attempts" }
            var ceiling = SocketSpec.BASE_RECONNECT_MS
            repeat(attempts - 1) {
                if (ceiling >= SocketSpec.MAX_RECONNECT_MS) return SocketSpec.MAX_RECONNECT_MS
                ceiling = minOf(ceiling * 2, SocketSpec.MAX_RECONNECT_MS)
            }
            return ceiling
        }
    }
}

/**
 * SB-39: `AuthChallenge` is tag 1 on the server side and is handled, not ignored.
 *
 * Named here rather than imported inline so the `when` in `handleFrame` reads
 * as the tag table rather than as a message list. Wire generates it as a real
 * message, so the branch is a type check like every other one.
 */
private typealias AuthChallengeFrame = sinch.push.delivery.v1beta1.ws.AuthChallenge