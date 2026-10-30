package com.sinchpush.socket

import android.content.Context
import android.util.Log
import java.net.URL
import java.util.concurrent.TimeUnit
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** One finished HTTP exchange, as far as the outcome needs it. */
internal class ReportHttpResponse(
    val status: Int,
    val contentType: String?,
    val grpcStatusHeader: String?,
    val body: ByteArray?,
)

/** The one network call the uploader makes; a JVM test substitutes its own. */
internal interface ReportHttp {
    /**
     * `null` on a transport failure (no route, DNS, TLS, timeout). Never throws.
     * [timeoutMs] bounds the whole call, DNS and body included.
     */
    fun post(url: URL, headers: Map<String, String>, body: ByteArray, timeoutMs: Int): ReportHttpResponse?
}

/**
 * OkHttp (already a dependency of the socket client). Its `callTimeout` is a
 * deadline for the whole call - DNS, connect, TLS, write, response headers and
 * body - which `HttpURLConnection`'s per-phase timeouts are not: DNS ignores
 * them, and connect plus read could each take the full budget.
 */
internal object OkHttpReportHttp : ReportHttp {

    /** A `ReportEvents` response is an empty message and a trailer; anything larger is not ours. */
    private const val MAX_RESPONSE_BYTES = 64L * 1024

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .followRedirects(false)
            .followSslRedirects(false)
            .retryOnConnectionFailure(false)
            .build()
    }

    /**
     * A native gRPC server (plain HTTP/2) sends `grpc-status` in the trailers, which
     * follow the body: only readable once it is consumed. Empty when the response has
     * none; OkHttp throws if they cannot be read yet. Either way: no status.
     */
    private fun trailerStatus(response: okhttp3.Response): String? = try {
        response.trailers()["grpc-status"]
    } catch (_: Exception) {
        null
    }

    override fun post(url: URL, headers: Map<String, String>, body: ByteArray, timeoutMs: Int): ReportHttpResponse? {
        return try {
            val request = Request.Builder().url(url).apply {
                for ((name, value) in headers) header(name, value)
            }.post(body.toRequestBody(headers["content-type"]?.toMediaTypeOrNull())).build()
            client.newBuilder()
                .callTimeout(timeoutMs.toLong().coerceAtLeast(1), TimeUnit.MILLISECONDS)
                .build()
                .newCall(request)
                .execute()
                .use { response ->
                    val source = response.body?.source()
                    // Over the cap the response is not ours, and its status (a trailer frame
                    // or HTTP/2 trailers past the cap) unreadable: a transport failure, retried.
                    if (source != null && source.request(MAX_RESPONSE_BYTES + 1)) return@use null
                    val bytes = source?.let { it.buffer.readByteArray(it.buffer.size) }
                    ReportHttpResponse(
                        status = response.code,
                        contentType = response.header("content-type"),
                        grpcStatusHeader = response.header("grpc-status") ?: trailerStatus(response),
                        body = bytes,
                    )
                }
        } catch (_: Exception) {
            null
        }
    }
}

/**
 * Sends the queued `DELIVERED` reports natively (SB-67), for a push that arrives
 * while there is no JS runtime to flush the outbox: a backgrounded or killed app.
 *
 * Called on the FCM service thread right after a report is queued. FCM gives that
 * thread roughly 10-20 s, so the whole attempt is bounded by [budgetMs]; whatever
 * it could not do stays in the outbox for the JS flusher, which sends exactly the
 * same request.
 *
 * Safe next to the JS flusher: it works on entries it [ReportOutbox.claim]ed, so
 * the two never hold the same entry, and it removes only entries the server
 * acknowledged (or will never accept) - the same rule as `reportOutbox.ts`.
 */
internal class NativeReportUploader(
    private val outbox: ReportOutbox,
    private val sessions: SharedReportSessionStore,
    private val http: ReportHttp = OkHttpReportHttp,
    private val clock: Clock = SystemClock,
    private val budgetMs: Long = BUDGET_MS,
) {

    /** What one [flush] did, for the caller and for tests. */
    data class Result(
        /** Entries acknowledged (or refused for good) and removed. */
        val removed: Int,
        /** Entries still in the outbox that this flush tried or was meant to send. */
        val remaining: Int,
    )

    fun flush(): Result {
        val session = sessions.load() ?: return Result(0, outbox.snapshot().size)
        val deadline = clock.nowMs() + budgetMs
        if (!isUsable(session)) return Result(0, outbox.snapshot().size)
        val url = ReportWire.endpoint(session.reportBaseURL) ?: return Result(0, outbox.snapshot().size)

        // The lease runs from the real deadline: every request is cut off by it
        // (callTimeout), so nothing this flush holds outlives the lease.
        val claimed = outbox.claim(ReportFlusher.NATIVE, leaseMs = (deadline - clock.nowMs()).coerceAtLeast(0) + LEASE_SLACK_MS)
        if (claimed.isEmpty()) return Result(0, 0)

        var removed = 0
        val cutoff = clock.nowMs() - TTL_MS
        val expired = claimed.filter { it.enqueuedAtMs < cutoff }
        if (expired.isNotEmpty()) {
            outbox.remove(expired.map(::keyOf))
            removed += expired.size
        }
        val pending = claimed.filter { it.enqueuedAtMs >= cutoff }

        val sent = HashSet<Pair<String, String>>()
        try {
            for (batch in pending.chunked(ReportWire.BATCH_SIZE)) {
                val remainingMs = deadline - clock.nowMs()
                if (remainingMs <= 0) break
                val keys = batch.map(::keyOf)
                val response = http.post(
                    url,
                    ReportWire.headers(session.accessToken),
                    ReportWire.requestBody(keys),
                    remainingMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                )
                val outcome = if (response == null) {
                    ReportOutcome.RETRY
                } else {
                    ReportWire.outcome(response.status, response.contentType, response.grpcStatusHeader, response.body)
                }
                if (!outcome.isFinal) {
                    // Unauthenticated: JS may hold a newer token. Retry: the next
                    // trigger will. Either way, stop here and keep the rest.
                    val detail = response?.let { "http ${it.status}, ${it.contentType}, grpc-status ${it.grpcStatusHeader}" } ?: "no response"
                    Log.w(TAG, "report upload not acknowledged ($outcome, $detail); leaving ${pending.size - sent.size} for the flusher")
                    break
                }
                outbox.remove(keys)
                sent.addAll(keys)
                removed += keys.size
            }
        } finally {
            outbox.release(ReportFlusher.NATIVE, pending.map(::keyOf).filterNot { it in sent })
        }
        if (sent.isNotEmpty()) Log.i(TAG, "reported ${sent.size} DELIVERED natively")
        return Result(removed, pending.size - sent.size)
    }

    private fun isUsable(session: SharedReportSession): Boolean {
        val expiresAt = JwtExpiry.expiresAtMs(session.accessToken) ?: return true
        return expiresAt - EXPIRY_LEEWAY_MS > clock.nowMs()
    }

    private fun keyOf(entry: ReportOutboxEntry) = entry.messageId to entry.subscriberId

    companion object {
        private const val TAG = "SinchPushReportUpload"

        /** FCM gives the service thread ~10-20 s; stay well inside it. */
        const val BUDGET_MS = 8_000L

        /** Added to the budget so a lease outlives the attempt that holds it. */
        private const val LEASE_SLACK_MS = 5_000L

        /** An entry older than this is dropped unsent, like `REPORT_TTL_MS` in JS. */
        const val TTL_MS = 72L * 60 * 60 * 1000

        private const val EXPIRY_LEEWAY_MS = 30_000L
    }
}

/** The process-wide uploader's wiring, from a `Context`. */
internal object NativeReports {

    fun sessionStore(context: Context): SharedReportSessionStore =
        FileReportSessionStore.of(context)

    /**
     * Drains the outbox now, on the calling thread (which must not be the main
     * thread). Never throws: a failed upload is a log line and entries left for JS.
     */
    fun flush(context: Context): NativeReportUploader.Result? = try {
        NativeReportUploader(
            outbox = SharedReportOutbox.get(context),
            sessions = sessionStore(context),
        ).flush()
    } catch (t: Throwable) {
        Log.w("SinchPushReportUpload", "native report flush failed", t)
        null
    }
}
