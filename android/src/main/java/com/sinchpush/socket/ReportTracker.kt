package com.sinchpush.socket

/**
 * The four report statuses, with the wire numbers the Ack token is built from.
 *
 * RN-004 confirms the numbers with the relay: the token is
 * `"<message_id>:<decimal enum value>"` and never the enum *name*, so
 * `DELIVERED = 1` and `DISMISSED = 4` are part of the protocol rather than an
 * implementation detail of a generated enum.
 */
internal enum class ReportStatus(val wire: sinch.push.delivery.v1beta1.ws.DeliveryReport.Status, val code: Int) {
    DELIVERED(sinch.push.delivery.v1beta1.ws.DeliveryReport.Status.DELIVERED, 1),
    DISPLAYED(sinch.push.delivery.v1beta1.ws.DeliveryReport.Status.DISPLAYED, 2),
    FAILED(sinch.push.delivery.v1beta1.ws.DeliveryReport.Status.FAILED, 3),
    DISMISSED(sinch.push.delivery.v1beta1.ws.DeliveryReport.Status.DISMISSED, 4),
    ;

    companion object {
        fun fromCode(code: Int): ReportStatus? = values().firstOrNull { it.code == code }

        /** The host-facing spelling: `"displayed"` / `"dismissed"` (RN-004). */
        fun fromHostString(value: String): ReportStatus? = when (value.lowercase()) {
            "displayed" -> DISPLAYED
            "dismissed" -> DISMISSED
            else -> null
        }
    }
}

/**
 * One report, either on its way out or waiting in the outbox.
 *
 * [attempts] and [notBeforeMs] exist for SB-33's policy table: `rate_limited`
 * defers with a timestamp rather than retrying on the next poll tick (that tick
 * is the thing being throttled), while `upstream_forward_failed` gets a bounded
 * number of retries and `unsupported_status` gets none.
 */
internal data class PendingReport(
    val messageId: String,
    val sinchMessageId: String,
    val status: ReportStatus,
    val reason: String,
    val queuedAtMs: Long,
    val attempts: Int = 0,
    val notBeforeMs: Long = 0L,
    val deferredByRateLimit: Boolean = false,
) {
    /**
     * The Ack correlation token, built rather than parsed (SB-32).
     *
     * Whole-string comparison on the client side means a `:` inside a
     * `message_id` needs no escaping rule and the relay never has to parse
     * anything: it echoes the id it was given plus `:1`.
     */
    val ackToken: String get() = "$messageId:${status.code}"
}

/** Where a report goes when the socket cannot take it right now. */
internal interface ReportTransport {
    /** @return true when the frame was handed to the socket. */
    fun send(report: PendingReport): Boolean
}

/** What an inbound `Ack` did to the tracker. */
internal data class AckOutcome(
    val accepted: Boolean,
    /** The Ack carried no token, so nothing could be attributed (SB-33). */
    val uncorrelated: Boolean,
    /** The token named a `(message_id, status)` this client has not reported. */
    val unknown: Boolean,
    /** The state to publish as `lastError`, when the Ack was a rejection. */
    val error: String?,
    val action: AckAction,
)

internal enum class AckAction {
    /** Accepted, or nothing to attribute. */
    NONE,

    /** `rate_limited`: deferred until [PendingReport.notBeforeMs]. */
    DEFERRED,

    /** `upstream_forward_failed`: re-queued for the next poll tick. */
    REQUEUED,

    /** `unsupported_status`: permanent, dropped. */
    DROPPED,
}

/**
 * The delivery-report state machine (SB-30 … SB-35).
 *
 * Three things live here, and they are the three things a socket client gets
 * wrong:
 *
 *  - **once per `(message_id, status)`** - the sent-set, persisted so a restart
 *    does not re-report a delivery the relay already recorded (SB-30);
 *  - **never a report without a `message_id`** - the relay refuses one as
 *    `missing_message_id`, so an unrecoverable id is a dropped report and a log
 *    line, not an empty one on the wire (SB-31);
 *  - **the Ack policy table** - `accepted` decides health (SB-34) and `error`
 *    decides what happens to the entry (SB-33), with `rate_limited` deferring
 *    against the backoff the client is already honouring rather than hot-retrying
 *    on the poll tick.
 *
 * It takes a [ReportTransport] rather than a socket, so all of that is testable
 * without a connection.
 */
internal class ReportTracker(
    private val store: SocketStateStore,
    private val clock: Clock,
    private val logger: SocketLogger,
    /**
     * The ceiling of the backoff the client is already honouring for server
     * pressure. A `rate_limited` report waits this long (SB-33), so a throttled
     * relay is never leaned on from two directions at once.
     */
    private val serverPressureCeilingMs: () -> Long = { SocketSpec.BASE_RECONNECT_MS },
    private val outboxCapacity: Int = SocketSpec.OUTBOX_CAPACITY,
    private val maxAttempts: Int = SocketSpec.MAX_REPORT_ATTEMPTS,
) {

    /**
     * Ack tokens of every `(message_id, status)` this installation has issued.
     *
     * Restored from the persisted keys as keys only: after a restart the set is
     * there to *refuse* a duplicate, which is the whole of SB-30's promise, and
     * the live copy of a report lives in the (also persisted) outbox.
     */
    private val sentKeys = BoundedLru<String, Boolean>(SocketSpec.SENT_SET_CAPACITY).apply {
        store.loadSentKeys().forEach { put(it, true) }
    }

    /** Entries issued by this process, by token, for Ack correlation. */
    private val pending = BoundedLru<String, PendingReport>(SocketSpec.SENT_SET_CAPACITY)

    private val outbox = ArrayDeque(store.loadOutbox())

    /** Pooled id -> Sinch id, for a report the host triggers long after delivery. */
    private val sinchMessageIds = BoundedLru<String, String>(SocketSpec.SEEN_SET_CAPACITY).apply {
        store.loadSinchMessageIds().forEach { (k, v) -> put(k, v) }
    }

    /** Whether this `(message_id, status)` has already been issued. */
    fun hasReported(messageId: String, status: ReportStatus): Boolean =
        messageId.isNotEmpty() && sentKeys.containsKey("$messageId:${status.code}")

    /** The Sinch id retained for [messageId], or `""` if this process never saw it. */
    fun sinchMessageIdFor(messageId: String): String = sinchMessageIds[messageId].orEmpty()

    fun remember(messageId: String, sinchMessageId: String) {
        if (messageId.isEmpty()) return
        if (sinchMessageIds.put(messageId, sinchMessageId)) persistSinchIds()
    }

    /**
     * Issues a report, at most once for its `(message_id, status)`.
     *
     * @return whether a report was issued (false for a duplicate, or for one
     *   that could not be identified - which the relay would refuse anyway).
     */
    fun report(
        messageId: String,
        sinchMessageId: String,
        status: ReportStatus,
        reason: String,
        transport: ReportTransport,
    ): Boolean {
        if (messageId.isEmpty()) {
            // SB-31: never a report with an empty message_id. SB-40 wants a
            // FAILED for an undecodable message, and the two meet exactly here -
            // with no recoverable id there is nothing to report *against*, and
            // an empty id is refused as `missing_message_id`.
            logger.warn("refusing $status report with an empty message_id ($reason)")
            return false
        }
        val entry = PendingReport(
            messageId = messageId,
            sinchMessageId = sinchMessageId.ifEmpty { sinchMessageIdFor(messageId) },
            status = status,
            reason = reason,
            queuedAtMs = clock.nowMs(),
        )
        if (!sentKeys.put(entry.ackToken, true)) return false
        persistSentKeys()
        pending.put(entry.ackToken, entry)
        remember(messageId, entry.sinchMessageId)
        if (transport.send(entry)) return true
        enqueue(entry)
        return true
    }

    /**
     * Sends everything the outbox is holding, oldest first (SB-35).
     *
     * Called after a `HelloAck` and nowhere else on the connect path: a
     * handshake is the one moment the client knows the session exists, which is
     * exactly what the outbox was waiting for.
     */
    fun flushOutbox(transport: ReportTransport) {
        resend(transport)
    }

    /**
     * Retries the entries a rejection left behind, from the poll tick (SB-33).
     *
     * @return how many were re-sent.
     */
    fun retryDue(transport: ReportTransport): Int = resend(transport)

    /**
     * Sends every outbox entry that is due, oldest first.
     *
     * Three outcomes per entry, and none of them loses a report silently: an
     * entry still inside its `rate_limited` deferral stays queued; one that has
     * burned its `upstream_forward_failed` budget is dropped with a log line;
     * and one the socket refuses to take stays queued for the next chance
     * (SB-35). The attempt count is only ever moved by an Ack rejection, so a
     * resend after a reconnect is not itself a strike.
     */
    private fun resend(transport: ReportTransport): Int {
        val now = clock.nowMs()
        val queued = outbox.toList()
        outbox.clear()
        var sent = 0
        for (entry in queued) {
            when {
                entry.notBeforeMs > now -> outbox.addLast(entry)
                entry.attempts >= maxAttempts -> logger.warn(
                    "dropping ${entry.status} report for ${entry.messageId} after ${entry.attempts} attempts",
                )
                transport.send(entry) -> {
                    pending.put(entry.ackToken, entry.copy(deferredByRateLimit = false))
                    sent++
                }
                else -> outbox.addLast(entry)
            }
        }
        if (sent > 0 || outbox.size != queued.size || queued != outbox.toList()) persistOutbox()
        return sent
    }

    /**
     * Whether the relay has told us to stop leaning on it.
     *
     * SB-35 forbids flushing the outbox on the next poll tick *while the relay is
     * shedding*: the tick is the traffic being shed. While a `rate_limited`
     * deferral is outstanding, the poll-tick retry path is disabled entirely.
     */
    fun isShedding(): Boolean {
        val now = clock.nowMs()
        return outbox.any { it.deferredByRateLimit && it.notBeforeMs > now }
    }

    fun outboxSize(): Int = outbox.size

    /** The outbox contents, oldest first - for tests and for reasoning about deferrals. */
    fun outboxEntries(): List<PendingReport> = outbox.toList()

    /**
     * Applies SB-33's policy table to one inbound Ack.
     *
     * Correlation is a whole-string comparison against tokens this client built,
     * never a parse (SB-32), so a `:` inside a `message_id` is harmless.
     */
    fun onAck(ackToken: String, accepted: Boolean, error: String): AckOutcome {
        if (ackToken.isEmpty()) {
            // Log only: uncorrelatable, so nothing may be cleared, failed or
            // retried (SB-32, SB-33).
            logger.debug("ack with an empty token; nothing to correlate")
            return AckOutcome(accepted, true, false, null, AckAction.NONE)
        }
        if (!sentKeys.containsKey(ackToken)) {
            // A token this client never built: another surface's report, or a
            // relay running ahead. Attributing it to a guess would be worse.
            logger.debug("ack token '$ackToken' matches no reported (message_id, status)")
            return AckOutcome(accepted, false, true, null, AckAction.NONE)
        }
        if (accepted) {
            forgetDeferred(ackToken)
            return AckOutcome(true, false, false, null, AckAction.NONE)
        }
        val reported = resolve(ackToken)
        val message = error.ifEmpty { "rejected" }
        if (reported == null) {
            // Known key, no live entry: the report was issued before this
            // process started and the outbox no longer holds it. Log only.
            logger.info("ack for '$ackToken' rejected with '$message'; no entry to act on")
            return AckOutcome(false, false, false, "report rejected: $message", AckAction.NONE)
        }
        return when (error) {
            ERROR_RATE_LIMITED -> {
                val delay = serverPressureCeilingMs()
                // Deliberately not a strike: the attempt budget is for a relay that is
                // broken, and a throttled relay is working as designed.
                val entry = current(reported).copy(
                    notBeforeMs = clock.nowMs() + delay,
                    deferredByRateLimit = true,
                )
                upsert(entry)
                logger.warn(
                    "relay rate-limited the ${entry.status} report for ${entry.messageId}; " +
                        "deferring ${delay} ms instead of hot-retrying the poll tick",
                )
                AckOutcome(false, false, false, "report rejected: $message", AckAction.DEFERRED)
            }
            ERROR_UPSTREAM_FORWARD_FAILED -> {
                val attempts = reported.attempts + 1
                if (attempts >= maxAttempts) {
                    drop(ackToken, reported, "upstream_forward_failed $attempts times")
                    AckOutcome(false, false, false, "report rejected: $message", AckAction.DROPPED)
                } else {
                    val entry = current(reported).copy(attempts = attempts)
                    upsert(entry)
                    AckOutcome(false, false, false, "report rejected: $message", AckAction.REQUEUED)
                }
            }
            ERROR_UNSUPPORTED_STATUS -> {
                // Permanent against this relay version: quota recovery cannot
                // make a status supported, so a retry is a loop.
                drop(ackToken, reported, "this relay does not support ${reported.status}")
                AckOutcome(false, false, false, "report rejected: $message", AckAction.DROPPED)
            }
            else -> {
                logger.info("ack for '$ackToken' rejected with '$message'; no entry action")
                AckOutcome(false, false, false, "report rejected: $message", AckAction.NONE)
            }
        }
    }

    /** The queued copy if there is one, so a deferral does not lose its bookkeeping. */
    private fun current(reported: PendingReport): PendingReport =
        outbox.firstOrNull { it.ackToken == reported.ackToken } ?: pending[reported.ackToken] ?: reported

    /** The live entry behind a token: the outbox first (it survives a restart). */
    private fun resolve(ackToken: String): PendingReport? =
        outbox.firstOrNull { it.ackToken == ackToken } ?: pending[ackToken]

    private fun drop(ackToken: String, reported: PendingReport, why: String) {
        // The sent-set key stays: the report *was* issued, and SB-30 promises
        // at most one per (message_id, status) across the process lifetime.
        // Only the pending copy goes.
        outbox.removeAll { it.ackToken == ackToken }
        logger.warn("dropping ${reported.status} report for ${reported.messageId}: $why")
        persistOutbox()
    }

    private fun forgetDeferred(ackToken: String) {
        if (outbox.removeAll { it.ackToken == ackToken }) persistOutbox()
    }

    private fun upsert(entry: PendingReport) {
        outbox.removeAll { it.ackToken == entry.ackToken }
        enqueue(entry)
        pending.put(entry.ackToken, entry)
    }

    private fun enqueue(entry: PendingReport) {
        if (outbox.size >= outboxCapacity) {
            val oldest = outbox.removeFirst()
            logger.warn(
                "outbox full at $outboxCapacity; dropping the oldest queued report for ${oldest.messageId}",
            )
        }
        outbox.addLast(entry)
        persistOutbox()
    }

    private fun persistSentKeys() {
        store.saveSentKeys(sentKeys.keys())
    }

    private fun persistOutbox() {
        store.saveOutbox(outbox.toList())
    }

    private fun persistSinchIds() {
        store.saveSinchMessageIds(sinchMessageIds.pairs().toMap())
    }

    companion object {
        const val ERROR_RATE_LIMITED = "rate_limited"
        const val ERROR_UPSTREAM_FORWARD_FAILED = "upstream_forward_failed"
        const val ERROR_UNSUPPORTED_STATUS = "unsupported_status"
    }
}