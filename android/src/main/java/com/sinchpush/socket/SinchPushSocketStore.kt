package com.sinchpush.socket

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap

/**
 * The JS-facing view of the socket: the messages that were delivered and the
 * current state.
 *
 * Deliberately *not* where dedupe lives. The seen set is durable state owned by
 * [SeenSet] over a [SocketStateStore], because it has to survive the process
 * death a foreground service is subject to (SB-28); this object is the
 * presentation buffer, and clearing it must not cost the client its memory of
 * what the relay already offered.
 */
internal object SinchPushSocketStore {

    data class SocketMessage(
        val id: String,
        val sinchMessageId: String,
        val ackToken: String,
        val title: String?,
        val body: String?,
        val imageUrl: String?,
        val metadata: Map<String, String>,
        val importance: Int,
        val trigger: String?,
        val enqueuedAt: Long,
        val receivedAt: Long,
        val background: Boolean,
        val shown: Boolean,
    )

    data class SocketState(
        val status: String,
        val connectionId: String?,
        val pollIntervalMs: Int,
        val reconnectAttempts: Int,
        val lastError: String?,
    ) {
        fun toWritableMap(): WritableMap = Arguments.createMap().apply {
            putString("status", status)
            putString("transport", "native")
            if (connectionId != null) putString("connectionId", connectionId) else putNull("connectionId")
            putInt("pollIntervalMs", pollIntervalMs)
            putInt("reconnectAttempts", reconnectAttempts)
            if (lastError != null) putString("lastError", lastError) else putNull("lastError")
        }
    }

    @Volatile
    private var state: SocketState = SocketState(
        status = "idle",
        connectionId = null,
        pollIntervalMs = 0,
        reconnectAttempts = 0,
        lastError = null,
    )

    /**
     * Whether the host registered an in-app message handler (RN-012/RN-031).
     *
     * Lives here, not on the client: JS can publish it before the foreground
     * service has built a client, and a client that is replaced on reconnect
     * must not forget it. The `whenUnhandled` display rule reads it per message.
     */
    @Volatile
    var handlerRegistered: Boolean = false

    private val messages: MutableMap<String, SocketMessage> = linkedMapOf()

    /** Records a delivered message. The client has already decided it is not a duplicate. */
    @Synchronized
    fun recordMessage(message: SocketMessage) {
        if (message.id.isEmpty()) return
        messages[message.id] = message
    }

    @Synchronized
    fun messages(): List<SocketMessage> = messages.values.toList()

    /**
     * Empties the presentation buffer.
     *
     * Only the buffer: the client's dedupe memory is durable and deliberately
     * survives this, so restarting the socket does not turn every re-offered
     * message into a second `DELIVERED` (SB-27, SB-28).
     */
    @Synchronized
    fun clear() {
        messages.clear()
    }

    @Synchronized
    fun setState(patch: SocketState) {
        state = patch
    }

    @Synchronized
    fun state(): SocketState = state
}

internal fun SinchPushSocketStore.SocketMessage.toWritableMap(): WritableMap =
    Arguments.createMap().apply {
        putString("id", id)
        putString("sinchMessageId", sinchMessageId)
        putString("ackToken", ackToken)
        if (title != null) putString("title", title) else putNull("title")
        if (body != null) putString("body", body) else putNull("body")
        if (imageUrl != null) putString("imageUrl", imageUrl) else putNull("imageUrl")
        val metadataMap = Arguments.createMap()
        for ((k, v) in metadata) metadataMap.putString(k, v)
        putMap("metadata", metadataMap)
        putInt("importance", importance)
        if (trigger != null) putString("trigger", trigger) else putNull("trigger")
        putDouble("enqueuedAt", enqueuedAt.toDouble())
        putDouble("receivedAt", receivedAt.toDouble())
        putBoolean("background", background)
        putBoolean("shown", shown)
    }

internal fun toWritableArray(items: List<SinchPushSocketStore.SocketMessage>): WritableArray =
    Arguments.createArray().apply {
        for (m in items) pushMap(m.toWritableMap())
    }