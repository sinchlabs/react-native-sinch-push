package com.sinchpush.socket

import java.io.File
import java.net.HttpURLConnection
import java.net.ServerSocket
import java.net.URL
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

/**
 * Starts the prebuilt relay binaries (`deliveryd`, `report-sink-stub`, `enqueue`)
 * for the live contract suite (SB-58). Everything here is about getting the
 * harness notes in the spec right, because getting them wrong produces
 * convincing false failures:
 *
 *  - zerolog writes to **stderr**; both streams are collected and lines are
 *    matched on the decoded JSON `message` field, not by substring;
 *  - the relay drains for ~5 s on SIGTERM and holds its ports for the whole
 *    window, so a respawn waits for process **exit**, never for the signal;
 *  - the sink gets its **own** probes port or deliveryd's probe bind fails.
 */
internal class RelayHarness private constructor(private val binDir: File) {

    val httpPort = freePort()
    val grpcPort = freePort()
    private val metricsPort = freePort()
    private val probesPort = freePort()
    private val sinkPort = freePort()
    private val sinkProbesPort = freePort()

    val wsUrl: String get() = "ws://127.0.0.1:$httpPort/ws"

    private val sinkLog = CopyOnWriteArrayList<String>()
    val relayLog = CopyOnWriteArrayList<String>()
    private var sink: Process? = null
    @Volatile var relay: Process? = null
        private set

    /**
     * One `ReportDelivery` call as the upstream sink saw it.
     *
     * The relay reports through `RelayCallbackService` (log message
     * `RelayCallback ReportDelivery`, the message id in `message_id`, plus
     * `installation_id`); the legacy `DeliveryService` line (`ReportDelivery`,
     * `channel_message_id`) is still read, for older relay pins.
     */
    data class SinkReport(
        val sinchMessageId: String,
        val channelMessageId: String,
        val status: String,
        val installationId: String = "",
    )

    fun start() {
        sink = spawn(
            "report-sink-stub",
            mapOf("GRPC_LISTEN_ADDR" to ":$sinkPort", "PROBES_ADDR" to ":$sinkProbesPort"),
            sinkLog,
        )
        startRelay()
    }

    /** (Re)starts deliveryd on the same ports and waits for it to be healthy. */
    fun startRelay() {
        relay = spawn(
            "deliveryd",
            mapOf(
                "HTTP_PORT" to "$httpPort",
                "GRPC_PORT" to "$grpcPort",
                "METRICS_PORT" to "$metricsPort",
                "PROBES_PORT" to "$probesPort",
                "SINCH_PUSH_GRPC_ADDR" to "127.0.0.1:$sinkPort",
                "LOG_LEVEL" to "info",
                // The relay refuses to start without a JWT secret. The harness
                // talks to it with placeholder tokens, so the JWT check is
                // skipped (local only). An inherited JWT_SECRET is cleared:
                // the relay refuses to start when both are set.
                "AUTH_INSECURE_SKIP_JWT" to "true",
                "JWT_SECRET" to "",
            ),
            relayLog,
        )
        val deadline = System.currentTimeMillis() + 15_000
        var last = "never attempted"
        while (true) {
            try {
                val c = URL("http://127.0.0.1:$probesPort/healthz").openConnection() as HttpURLConnection
                c.connectTimeout = 500
                c.readTimeout = 500
                if (c.responseCode == 200) return
                last = "/healthz returned ${c.responseCode}"
            } catch (e: Exception) {
                last = e.message ?: e.javaClass.simpleName
            }
            check(System.currentTimeMillis() < deadline) { "deliveryd never became healthy: $last\n${relayTail()}" }
            Thread.sleep(100)
        }
    }

    /** SIGTERM and wait for the ~5 s graceful drain to end, i.e. for process exit. */
    fun sigtermRelayAndAwaitExit() {
        val p = relay ?: return
        p.destroy() // SIGTERM on Unix
        check(p.waitFor(25, TimeUnit.SECONDS)) { "deliveryd did not exit within 25 s of SIGTERM\n${relayTail()}" }
    }

    fun stop() {
        for (p in listOfNotNull(relay, sink)) {
            if (!p.isAlive) continue
            p.destroy()
            if (!p.waitFor(10, TimeUnit.SECONDS)) {
                p.destroyForcibly()
                p.waitFor(5, TimeUnit.SECONDS)
            }
        }
    }

    /**
     * Runs `enqueue` and returns its output. With [installation] the relay's
     * `RelayService.EnqueueMessage` targets that one installation and the output
     * is one `outcome=PUSHED|STORED_OFFLINE ...` line; without it the legacy
     * `DeliveryService.EnqueueMessage` fans out to every session of the user.
     * [ackDeadlineMs] > 0 arms ACK_TIMEOUT/NOT_CONNECTED reporting (relay path only).
     */
    fun enqueue(
        appId: String,
        userId: String,
        sinchMessageId: String,
        title: String,
        body: String = "",
        ttl: Int = 120,
        installation: String? = null,
        ackDeadlineMs: Int? = null,
    ): String {
        val cmd = mutableListOf(
            File(binDir, "enqueue").path, "-addr", "127.0.0.1:$grpcPort",
            "-app", appId, "-user", userId, "-title", title,
            "-sinch-message-id", sinchMessageId, "-ttl", "$ttl",
        )
        if (body.isNotEmpty()) cmd += listOf("-body", body, "-metadata", "kind=chat")
        if (installation != null) cmd += listOf("-installation", installation)
        if (ackDeadlineMs != null) cmd += listOf("-ack-deadline-ms", "$ackDeadlineMs")
        val proc = ProcessBuilder(cmd).redirectErrorStream(true).start()
        val out = proc.inputStream.bufferedReader().readText()
        check(proc.waitFor(15, TimeUnit.SECONDS) && proc.exitValue() == 0) { "enqueue failed: $out" }
        return out
    }

    /** Reports the sink actually received, from its own log. */
    fun sinkReports(): List<SinkReport> = jsonLines(sinkLog)
        .filter { it["message"] == "ReportDelivery" || it["message"] == "RelayCallback ReportDelivery" }
        .map {
            SinkReport(
                sinchMessageId = it["sinch_message_id"] as? String ?: "",
                channelMessageId = (it["message_id"] ?: it["channel_message_id"]) as? String ?: "",
                status = it["status"] as? String ?: "",
                installationId = it["installation_id"] as? String ?: "",
            )
        }

    /** deliveryd's own log lines whose decoded JSON `message` equals [message] (the harness notes in SB-58). */
    fun relayEvents(message: String): List<Map<String, Any?>> =
        jsonLines(relayLog).filter { it["message"] == message }

    fun relayTail(lines: Int = 25): String =
        "--- deliveryd (last $lines) ---\n" + relayLog.joinToString("").lines().takeLast(lines).joinToString("\n")

    fun sinkTail(lines: Int = 25): String =
        "--- sink (last $lines) ---\n" + sinkLog.joinToString("").lines().takeLast(lines).joinToString("\n")

    private fun spawn(bin: String, env: Map<String, String>, into: MutableList<String>): Process {
        val pb = ProcessBuilder(File(binDir, bin).path)
        pb.environment().putAll(env)
        val proc = pb.start()
        proc.outputStream.close()
        for (stream in listOf(proc.inputStream, proc.errorStream)) {
            Thread {
                // Line by line, so a half-written JSON object never lands in the middle of another.
                try {
                    stream.bufferedReader().forEachLine { into.add(it + "\n") }
                } catch (_: java.io.IOException) {
                    // Pipe closed under us at process teardown.
                }
            }.apply { isDaemon = true }.start()
        }
        return proc
    }

    @Suppress("UNCHECKED_CAST")
    private fun jsonLines(buffered: List<String>): List<Map<String, Any?>> =
        buffered.joinToString("").lines().map { it.trim() }.filter { it.startsWith("{") }.mapNotNull {
            try {
                TestJson.parse(it) as? Map<String, Any?>
            } catch (_: Exception) {
                null
            }
        }

    companion object {
        private fun freePort(): Int = ServerSocket(0).use { it.localPort }

        /** Locate `bin/` of a relay checkout, or null (with [why] filled in) when unavailable. */
        fun locate(why: StringBuilder): RelayHarness? {
            val dir = System.getProperty("relay.dir")?.takeIf { it.isNotBlank() }
                ?: System.getenv("RELAY_DIR")?.takeIf { it.isNotBlank() }
                ?: "../../sinch-push-relay"
            val bin = File(System.getenv("RELAY_BIN_DIR")?.takeIf { it.isNotBlank() } ?: File(dir, "bin").path)
            val missing = listOf("deliveryd", "enqueue", "report-sink-stub").filter { !File(bin, it).canExecute() }
            if (missing.isNotEmpty()) {
                why.append("relay binaries $missing not found in ${bin.absoluteFile}; build the relay ")
                    .append("(make build) or pass -PrelayDir / RELAY_DIR / RELAY_BIN_DIR")
                return null
            }
            return RelayHarness(bin)
        }
    }
}
