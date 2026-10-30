package com.sinchpush.socket

/**
 * The fixed numbers of the socket protocol, in one place.
 *
 * Every value here is pinned by `docs/socket-behaviour-spec.md` §2 and must not
 * be derived at runtime from anything else: the relay, the TypeScript snapshot
 * and the Swift client all carry the same values, and a client that picks its
 * own is a client that behaves differently under load than the rest of the
 * cohort it is being throttled with.
 */
internal object SocketSpec {

    /** SB-04: largest protobuf payload in one frame. */
    const val MAX_FRAME_PAYLOAD_BYTES = 64 * 1024 // 65536

    /** SB-04: largest whole frame accepted (payload + tag + 10 length bytes). */
    const val MAX_FRAME_TOTAL_BYTES = MAX_FRAME_PAYLOAD_BYTES + 1 + 10 // 65547

    /** SB-08: largest whole frame written (canonical length prefix). */
    const val MAX_FRAME_EMITTED_BYTES = MAX_FRAME_PAYLOAD_BYTES + 1 + 3 // 65540

    /** SB-22: the poll cadence never goes below this, whatever the server asks. */
    const val MIN_POLL_MS = 1000

    /** SB-22: used when neither config nor server supplies a cadence. */
    const val DEFAULT_POLL_MS = 5000

    /** SB-42: full-jitter base delay. */
    const val BASE_RECONNECT_MS = 1000L

    /** SB-42: full-jitter ceiling, however many attempts have failed. */
    const val MAX_RECONNECT_MS = 30_000L

    /**
     * SB-28: bounded LRU of processed `message_id`s. One set serves the socket,
     * FCM and APNs/FCM pushes.
     */
    const val SEEN_SET_CAPACITY = 2000

    /** SB-35: bounded report outbox. */
    const val OUTBOX_CAPACITY = 200

    /**
     * SB-63: at most one *alerting* system notification per window; the rest are
     * posted silently. Spec §2 `NOTIFICATION_ALERT_WINDOW_MS`.
     */
    const val NOTIFICATION_ALERT_WINDOW_MS = 2000L

    /**
     * SB-65: the notification id every Sinch message notification is posted
     * under, whichever channel renders it. The tag (`message_id`) is what makes
     * each one distinct; a constant id is what makes a second copy with the same
     * tag replace the first. Distinct from the foreground-service notification
     * id (`SinchPushSocketNotifications.FOREGROUND_NOTIFICATION_ID`) and from the
     * `showLocal` id space, which never carries a tag.
     */
    const val SINCH_MESSAGE_NOTIFICATION_ID = 0x534E_4D4D // 'SNMM'

    /** SB-63: the group every socket notification is posted under. */
    const val NOTIFICATION_GROUP = "com.sinch.push.messages"

    /**
     * SB-30: how many times a `upstream_forward_failed` report is re-queued
     * before it is dropped.
     *
     * `rate_limited` does not consume this budget - it defers instead - so a
     * relay that is merely slow cannot burn a report out of existence.
     */
    const val MAX_REPORT_ATTEMPTS = 3

    /**
     * The sent-set is what makes "at most one report per `(message_id, status)`"
     * true across a restart, so it has to outlive the message it belongs to. At
     * `4 x SEEN_SET_CAPACITY` the oldest eviction can only reach a pair whose
     * message has already fallen out of the seen window - the same trade the
     * seen-set bound already makes, one status per message.
     */
    const val SENT_SET_CAPACITY = SEEN_SET_CAPACITY * 4

    /**
     * SB-19: the `sdk_version` reported when the host config supplies none.
     *
     * `rn-sinch-push/<package.json version>`. `SDKVersionTest` asserts this
     * literal against `package.json`, so bumping the published package without
     * bumping this fails a test instead of shipping a stale string.
     */
    const val DEFAULT_SDK_VERSION = "rn-sinch-push/1.1.0"
}