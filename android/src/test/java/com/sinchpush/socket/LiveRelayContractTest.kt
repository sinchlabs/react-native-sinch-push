package com.sinchpush.socket

import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.BeforeClass
import org.junit.Test
import com.sinchpush.PushDecision
import com.sinchpush.PushDedupe
import java.util.concurrent.CopyOnWriteArrayList

/**
 * SB-58: the shipped Kotlin client against a real `deliveryd` and
 * `report-sink-stub`, over real OkHttp.
 *
 * Golden vectors prove the bytes; this proves the behaviour: does a push arrive
 * unprompted, is the report Ack accepted, does the report land in the upstream
 * sink, does SIGTERM let the client come back, does a DISMISSED raised while
 * disconnected survive. Excluded from `testDebugUnitTest`; run with
 * `npm run contract:android` (Gradle property `-PliveRelay`). Skips with a
 * message when the relay binaries are missing.
 */
class LiveRelayContractTest {

    companion object {
        private var relay: RelayHarness? = null
        private var skipReason = ""

        @BeforeClass
        @JvmStatic
        fun startRelay() {
            val why = StringBuilder()
            val h = RelayHarness.locate(why)
            if (h == null) {
                skipReason = why.toString()
            } else {
                relay = h
                h.start()
            }
        }

        @AfterClass
        @JvmStatic
        fun stopRelay() {
            relay?.stop()
        }
    }

    private val appId = "contract-app"
    private val userId = "contract-user"

    private fun relayOrSkip(): RelayHarness {
        assumeTrue("live relay contract skipped: $skipReason", relay != null)
        return relay!!
    }

    /** Thread-safe: the client logs from its own executor thread. */
    private class SafeLogger : SocketLogger {
        val lines = CopyOnWriteArrayList<String>()
        override fun debug(line: String) { lines.add("D $line") }
        override fun info(line: String) { lines.add("I $line") }
        override fun warn(line: String, t: Throwable?) { lines.add("W $line ${t ?: ""}") }
    }

    private class Live(
        val relay: RelayHarness,
        userId: String,
        appId: String,
        /** Shared between two clients, it is the "same store" of a restart (SB-28, SB-29). */
        val store: InMemorySocketStateStore = InMemorySocketStateStore(),
        /** Null keeps the default provider: no device info, i.e. a legacy client (SB-59). */
        deviceInfo: DeviceInfoProvider? = null,
        backgroundService: Boolean = false,
        /** Shared with the FCM path, it is the cross-channel dedupe registry (SB-64). */
        val seen: SeenSet? = null,
    ) {
        val logger = SafeLogger()
        val states = CopyOnWriteArrayList<SinchPushSocketStore.SocketState>()
        val messages = CopyOnWriteArrayList<SinchPushSocketStore.SocketMessage>()
        val notifications = FakeNotifications(true)

        private val dependencies = SocketDependencies(
            clock = SystemClock,
            scheduler = ExecutorSocketScheduler(),
            random = { Math.random() },
            transport = OkHttpWebSocketTransport(),
            store = store,
            logger = logger,
            notifications = notifications,
            deviceInfo = deviceInfo ?: SocketDependencies.LEGACY_DEVICE_INFO,
            seen = seen,
        )

        val client = SinchPushSocketClient(
            PushSocketConfig(
                url = relay.wsUrl,
                authToken = "dev-token",
                projectId = "contract-project",
                appId = appId,
                userId = userId,
                sdkVersion = "rn-sinch-push-contract/1.0.0",
                pollIntervalMs = 0,
                displayNotifications = DisplayRule.NEVER,
                backgroundService = backgroundService,
            ),
            dependencies,
        ).apply {
            setListener(object : SinchPushSocketClient.Listener {
                override fun onMessage(message: SinchPushSocketStore.SocketMessage) { messages.add(message) }
                override fun onState(state: SinchPushSocketStore.SocketState) { states.add(state) }
            })
        }

        val state get() = states.lastOrNull()
        val connected get() = state?.status == "connected"
    }

    private inline fun withClient(r: RelayHarness, user: String, block: (Live) -> Unit) {
        val live = Live(r, user, appId)
        live.client.start()
        try {
            block(live)
        } finally {
            live.client.stop()
        }
    }

    private fun waitFor(timeoutMs: Long, what: String, extra: () -> String = { "" }, predicate: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (predicate()) return
            Thread.sleep(20)
        }
        throw AssertionError("timed out after ${timeoutMs}ms waiting for $what\n${extra()}")
    }

    private fun uniqueUser(tag: String) = "$userId-$tag-${System.nanoTime()}"

    // ------------------------------------------------------------------ tests

    @Test
    fun `handshake within 2s learns the session parameters`() {
        val r = relayOrSkip()
        withClient(r, uniqueUser("hs")) { live ->
            val started = System.currentTimeMillis()
            waitFor(2_000, "connected within 2 s", { r.relayTail() }) { live.connected }
            assertTrue(System.currentTimeMillis() - started <= 2_500)
            assertTrue(!live.state!!.connectionId.isNullOrEmpty())
            assertTrue("poll interval adopted from HelloAck", live.state!!.pollIntervalMs > 0)
            assertTrue(live.states.any { it.status == "connecting" })
        }
    }

    @Test
    fun `an enqueued message is pushed without a poll`() {
        val r = relayOrSkip()
        val user = uniqueUser("push")
        val sinchId = "contract-push-${System.nanoTime()}"
        withClient(r, user) { live ->
            waitFor(10_000, "connected", { r.relayTail() }) { live.connected }
            r.enqueue(appId, user, sinchId, "Hello from SDK contract", "contract body")
            // Strictly shorter than one poll interval, so a coincidental poll
            // cannot make this pass: the interval is seconds, this is 1 s.
            assertTrue(live.state!!.pollIntervalMs > 1_000)
            waitFor(1_000, "push delivery within 1 s of enqueue", { r.relayTail() }) { live.messages.isNotEmpty() }
            val m = live.messages.first()
            assertEquals(sinchId, m.sinchMessageId)
            assertEquals("Hello from SDK contract", m.title)
            assertEquals("contract body", m.body)
            // AckTokenContract: ack_token is the pooled message_id.
            assertEquals(m.id, m.ackToken)
            assertTrue(m.id.isNotEmpty())
        }
    }

    @Test
    fun `exactly one DELIVERED reaches the sink with an accepted Ack and a four-part channel id`() {
        val r = relayOrSkip()
        val user = uniqueUser("delivered")
        val sinchId = "contract-report-${System.nanoTime()}"
        withClient(r, user) { live ->
            waitFor(10_000, "connected", { r.relayTail() }) { live.connected }
            r.enqueue(appId, user, sinchId, "report correlation")
            waitFor(10_000, "the report to reach the sink", { r.sinkTail() + "\n" + r.relayTail() }) {
                r.sinkReports().any { it.sinchMessageId == sinchId }
            }
            // Let a poll tick or a redelivery have its chance to produce a duplicate.
            Thread.sleep(1_000)
            val reports = r.sinkReports().filter { it.sinchMessageId == sinchId }
            assertEquals(reports.toString(), 1, reports.size)
            assertEquals("DELIVERED", reports[0].status)

            val delivered = live.messages.firstOrNull { it.sinchMessageId == sinchId }
            assertNotNull(delivered)
            val channelId = reports[0].channelMessageId
            // d2091e1's four parts: present, equals the delivered id, is not the
            // Sinch id, and equals the Ack token (SB-37).
            assertTrue("channel_message_id missing upstream", channelId.isNotEmpty())
            assertEquals(delivered!!.id, channelId)
            assertNotEquals(sinchId, channelId)
            assertEquals(delivered.ackToken, channelId)

            waitFor(5_000, "the report Ack", { live.logger.lines.joinToString("\n") }) {
                live.logger.lines.any { it.contains("ack accepted=true") }
            }
            assertTrue(live.logger.lines.none { it.contains("ack accepted=false") })
        }
    }

    @Test
    fun `DISPLAYED and DISMISSED reach the sink after reportStatus (OPEN-7)`() {
        val r = relayOrSkip()
        val user = uniqueUser("status")
        val sinchId = "contract-status-${System.nanoTime()}"
        withClient(r, user) { live ->
            waitFor(10_000, "connected", { r.relayTail() }) { live.connected }
            r.enqueue(appId, user, sinchId, "status")
            waitFor(10_000, "message", { r.relayTail() }) { live.messages.isNotEmpty() }
            val id = live.messages.first().id
            live.client.reportStatus(id, ReportStatus.DISPLAYED)
            live.client.reportStatus(id, ReportStatus.DISMISSED)
            waitFor(10_000, "DISPLAYED and DISMISSED at the sink", { r.sinkTail() }) {
                val s = r.sinkReports().filter { it.sinchMessageId == sinchId }.map { it.status }
                "DISPLAYED" in s && "DISMISSED" in s
            }
            val reports = r.sinkReports().filter { it.sinchMessageId == sinchId }
            assertEquals(reports.toString(), 3, reports.size)
            assertTrue(reports.all { it.channelMessageId == id })
        }
    }

    @Test
    fun `reconnects with a new session after SIGTERM`() {
        val r = relayOrSkip()
        withClient(r, uniqueUser("sigterm")) { live ->
            waitFor(10_000, "connected", { r.relayTail() }) { live.connected }
            val first = live.state!!.connectionId
            assertTrue(!first.isNullOrEmpty())

            r.sigtermRelayAndAwaitExit()
            waitFor(10_000, "the client to notice the shutdown", { live.states.joinToString("\n") }) {
                live.states.any { it.status == "reconnecting" }
            }
            // Respawn on process exit, not on the signal (the relay holds its ports while it drains).
            r.startRelay()
            waitFor(30_000, "a reconnect with a fresh connection id", {
                live.states.joinToString("\n") + "\n" + live.logger.lines.joinToString("\n") + "\n" + r.relayTail(30)
            }) { live.connected && live.state!!.connectionId != first }
            assertNotEquals(first, live.state!!.connectionId)
            assertEquals("connected", live.state!!.status)
        }
    }

    @Test
    fun `a DISMISSED raised while disconnected arrives after the reconnect`() {
        val r = relayOrSkip()
        val user = uniqueUser("outbox")
        val sinchId = "contract-outbox-${System.nanoTime()}"
        withClient(r, user) { live ->
            waitFor(10_000, "connected", { r.relayTail() }) { live.connected }
            r.enqueue(appId, user, sinchId, "outbox")
            waitFor(10_000, "message", { r.relayTail() }) { live.messages.isNotEmpty() }
            val id = live.messages.first().id
            waitFor(10_000, "DELIVERED at the sink", { r.sinkTail() }) {
                r.sinkReports().any { it.sinchMessageId == sinchId && it.status == "DELIVERED" }
            }

            r.sigtermRelayAndAwaitExit()
            waitFor(10_000, "the client to notice the shutdown", { live.states.joinToString("\n") }) {
                !live.connected
            }
            live.client.reportStatus(id, ReportStatus.DISMISSED)
            Thread.sleep(300)
            assertTrue(
                "nothing may reach the sink while the relay is down",
                r.sinkReports().none { it.sinchMessageId == sinchId && it.status == "DISMISSED" },
            )

            r.startRelay()
            waitFor(30_000, "the outboxed DISMISSED at the sink", {
                r.sinkTail() + "\n" + live.logger.lines.joinToString("\n")
            }) { r.sinkReports().any { it.sinchMessageId == sinchId && it.status == "DISMISSED" } }
            val dismissed = r.sinkReports().filter { it.sinchMessageId == sinchId && it.status == "DISMISSED" }
            assertEquals(1, dismissed.size)
            assertEquals(id, dismissed[0].channelMessageId)
        }
    }

    @Test
    fun `a Hello carrying the full device info is accepted and the relay registers the installation`() {
        val r = relayOrSkip()
        val user = uniqueUser("devinfo")
        val installationId = java.util.UUID.randomUUID().toString().lowercase()
        // The shipped provider over a fake Android environment (SB-59, SB-60):
        // a running service, so `background_service` is ENABLED_RUNNING.
        val environment = FakeDeviceEnvironment(
            osVersion = "14",
            bundleId = "com.example.contract",
            installationId = installationId,
            serviceRunning = true,
            notificationPermissionGranted = true,
        )
        val live = Live(
            r, user, appId,
            deviceInfo = SystemDeviceInfoProvider(environment, SafeLogger()),
            backgroundService = true,
        )
        live.client.start()
        try {
            val started = System.currentTimeMillis()
            waitFor(2_000, "connected within 2 s", { r.relayTail() + "\n" + live.logger.lines.joinToString("\n") }) { live.connected }
            assertTrue(System.currentTimeMillis() - started <= 2_500)
            assertTrue(!live.state!!.connectionId.isNullOrEmpty())
            assertTrue("poll interval adopted from HelloAck", live.state!!.pollIntervalMs > 0)
            assertEquals(1, environment.installationIdCalls)

            // The relay logs `registered` with the installation id it parsed from
            // the Hello, after it has already sent the HelloAck, hence the wait.
            val connectionId = live.state!!.connectionId
            waitFor(5_000, "the relay to register the session", { r.relayTail() }) {
                r.relayEvents("registered").any { it["connection_id"] == connectionId }
            }
            val registered = r.relayEvents("registered").single { it["connection_id"] == connectionId }
            assertEquals(installationId, registered["installation_id"])
            assertEquals("sess:$appId:$user:$installationId", registered["key"])
            assertTrue(
                "a refused Hello would have been logged",
                r.relayEvents("ws hello refused: installation_id must be a canonical uuid").isEmpty(),
            )
        } finally {
            live.client.stop()
        }
    }

    @Test
    fun `after a restart over the same store only the messages missed while disconnected are emitted, once each`() {
        val r = relayOrSkip()
        val user = uniqueUser("replay")
        val store = InMemorySocketStateStore()
        val a = "contract-replay-a-${System.nanoTime()}"
        val b = "contract-replay-b-${System.nanoTime()}"
        val c = "contract-replay-c-${System.nanoTime()}"

        // Legacy key (empty installation_id): plain `enqueue`, no `-installation`; the per-installation case is below.
        val first = Live(r, user, appId, store)
        first.client.start()
        val aId: String
        try {
            waitFor(10_000, "connected", { r.relayTail() }) { first.connected }
            r.enqueue(appId, user, a, "A")
            // Pushed, not polled: the poll interval is 5 s.
            assertTrue(first.state!!.pollIntervalMs > 2_000)
            waitFor(2_000, "A pushed within 2 s", { r.relayTail() }) { first.messages.isNotEmpty() }
            aId = first.messages.single().id
            assertEquals(a, first.messages.single().sinchMessageId)
            waitFor(10_000, "DELIVERED for A at the sink", { r.sinkTail() }) {
                r.sinkReports().any { it.sinchMessageId == a && it.status == "DELIVERED" }
            }
        } finally {
            first.client.stop()
        }
        val firstConnection = first.states.last { !it.connectionId.isNullOrEmpty() }.connectionId
        waitFor(5_000, "the first client to stop", { first.states.joinToString("\n") }) { first.state?.status == "stopped" }
        // The relay must have dropped the session before B is enqueued, or B
        // would be pushed into the closing socket instead of waiting in the pool.
        waitFor(10_000, "the relay to unregister the first connection", { r.relayTail() }) {
            r.relayEvents("unregistered").any { it["connection_id"] == firstConnection }
        }

        r.enqueue(appId, user, b, "B")
        r.enqueue(appId, user, c, "C")
        Thread.sleep(500)
        assertEquals("a stopped client emits nothing", 1, first.messages.size)

        // A new client over the same persisted store: seen set and cursor survive.
        // The relay hello-replay is a no-op for the legacy key, so B and C arrive
        // with the immediate Poll after HelloAck, and A may come along with them
        // (the pool is not emptied by a push): the seen set must swallow it.
        val second = Live(r, user, appId, store)
        second.client.start()
        try {
            waitFor(20_000, "B and C emitted after the restart", {
                second.logger.lines.joinToString("\n") + "\n" + r.relayTail(30)
            }) { second.messages.size >= 2 }
            assertEquals(listOf(b, c), second.messages.map { it.sinchMessageId })
            waitFor(10_000, "DELIVERED for B and C at the sink", { r.sinkTail() }) {
                val delivered = r.sinkReports().filter { it.status == "DELIVERED" }.map { it.sinchMessageId }
                b in delivered && c in delivered
            }
            // More than one poll interval (5 s): catches a late duplicate event or
            // report (the legacy first Poll already drained the pool).
            Thread.sleep(6_000)
        } finally {
            second.client.stop()
        }
        assertEquals("exactly B and C, in order, A not again", listOf(b, c), second.messages.map { it.sinchMessageId })
        assertTrue(
            "the relay re-sent A and the seen set swallowed it",
            second.logger.lines.any { it.contains("duplicate message $aId") },
        )
        assertEquals("A was emitted once, by the first client", listOf(a), first.messages.map { it.sinchMessageId })
        assertEquals(aId, first.messages.single().id)
        for (id in listOf(a, b, c)) {
            val reports = r.sinkReports().filter { it.sinchMessageId == id }
            assertEquals(reports.toString(), listOf("DELIVERED"), reports.map { it.status })
        }
    }

    /** A client whose provider reports [installationId]; two of them over one store are "the same install" restarting. */
    private fun installationClient(r: RelayHarness, user: String, installationId: String, store: InMemorySocketStateStore) =
        Live(
            r, user, appId, store,
            deviceInfo = SystemDeviceInfoProvider(
                FakeDeviceEnvironment(
                    osVersion = "14",
                    bundleId = "com.example.contract",
                    installationId = installationId,
                    serviceRunning = true,
                    notificationPermissionGranted = true,
                ),
                SafeLogger(),
            ),
            backgroundService = true,
        )

    @Test
    fun `per-installation replay after a restart over the same store re-sends only B and C, A never again`() {
        val r = relayOrSkip()
        val user = uniqueUser("instreplay")
        val installationId = java.util.UUID.randomUUID().toString().lowercase()
        val store = InMemorySocketStateStore()
        val a = "contract-inst-a-${System.nanoTime()}"
        val b = "contract-inst-b-${System.nanoTime()}"
        val c = "contract-inst-c-${System.nanoTime()}"

        val first = installationClient(r, user, installationId, store)
        first.client.start()
        val aId: String
        try {
            waitFor(10_000, "connected", { r.relayTail() }) { first.connected }
            val connectionId = first.state!!.connectionId
            waitFor(5_000, "the relay to register the installation session", { r.relayTail() }) {
                r.relayEvents("registered").any { it["connection_id"] == connectionId }
            }
            val out = r.enqueue(appId, user, a, "A", installation = installationId)
            assertTrue("A is pushed to the live session: $out", out.contains("outcome=PUSHED"))
            assertTrue(first.state!!.pollIntervalMs > 2_000)
            waitFor(2_000, "A pushed within 2 s", { r.relayTail() }) { first.messages.isNotEmpty() }
            aId = first.messages.single().id
            assertEquals(a, first.messages.single().sinchMessageId)
            waitFor(10_000, "DELIVERED for A at the sink", { r.sinkTail() }) {
                r.sinkReports().any { it.sinchMessageId == a && it.status == "DELIVERED" }
            }
        } finally {
            first.client.stop()
        }
        val firstConnection = first.states.last { !it.connectionId.isNullOrEmpty() }.connectionId
        waitFor(5_000, "the first client to stop", { first.states.joinToString("\n") }) { first.state?.status == "stopped" }
        waitFor(10_000, "the relay to unregister the first connection", { r.relayTail() }) {
            r.relayEvents("unregistered").any { it["connection_id"] == firstConnection }
        }

        val outB = r.enqueue(appId, user, b, "B", installation = installationId)
        val outC = r.enqueue(appId, user, c, "C", installation = installationId)
        assertTrue("B is stored: $outB", outB.contains("outcome=STORED_OFFLINE"))
        assertTrue("C is stored: $outC", outC.contains("outcome=STORED_OFFLINE"))
        Thread.sleep(500)
        assertEquals("a stopped client emits nothing", 1, first.messages.size)

        // Same persisted store: last_seen = A, so the relay replays only what is
        // after A's cursor. Unlike the legacy key, A does not come back at all.
        val second = installationClient(r, user, installationId, store)
        second.client.start()
        try {
            waitFor(20_000, "B and C emitted after the restart", {
                second.logger.lines.joinToString("\n") + "\n" + r.relayTail(30)
            }) { second.messages.size >= 2 }
            assertEquals(listOf(b, c), second.messages.map { it.sinchMessageId })
            waitFor(10_000, "DELIVERED for B and C at the sink", { r.sinkTail() }) {
                val delivered = r.sinkReports().filter { it.status == "DELIVERED" }.map { it.sinchMessageId }
                b in delivered && c in delivered
            }
            // More than one poll interval (5 s): a late duplicate event, re-send or report would show.
            Thread.sleep(6_000)
        } finally {
            second.client.stop()
        }
        assertEquals("exactly B and C, in order", listOf(b, c), second.messages.map { it.sinchMessageId })
        assertTrue(
            "A did not arrive at all (cursor replay): no seen-set hit for it",
            second.logger.lines.none { it.contains("duplicate message $aId") },
        )
        assertEquals("A was emitted once, by the first client", listOf(a), first.messages.map { it.sinchMessageId })
        for (id in listOf(a, b, c)) {
            val reports = r.sinkReports().filter { it.sinchMessageId == id }
            assertEquals(reports.toString(), listOf("DELIVERED"), reports.map { it.status })
            assertEquals(reports.toString(), listOf(installationId), reports.map { it.installationId })
        }
    }

    @Test
    fun `a message enqueued to a different installation of the same user does not reach this client`() {
        val r = relayOrSkip()
        val user = uniqueUser("instisolation")
        val mine = java.util.UUID.randomUUID().toString().lowercase()
        val other = java.util.UUID.randomUUID().toString().lowercase()
        val elsewhere = "contract-inst-other-${System.nanoTime()}"
        val here = "contract-inst-mine-${System.nanoTime()}"

        val live = installationClient(r, user, mine, InMemorySocketStateStore())
        live.client.start()
        try {
            waitFor(10_000, "connected", { r.relayTail() }) { live.connected }
            val connectionId = live.state!!.connectionId
            waitFor(5_000, "the relay to register the session", { r.relayTail() }) {
                r.relayEvents("registered").any { it["connection_id"] == connectionId }
            }
            val out = r.enqueue(appId, user, elsewhere, "other", installation = other)
            // The "no sink entry for the other installation" assertion at the end holds trivially:
            // nothing is connected for it and the ack deadline is 0, so there is no NOT_CONNECTED
            // report either. The isolation proof is the empty message list after 6 s plus this
            // installation's own outcome=PUSHED.
            assertTrue("no session for the other installation: $out", out.contains("outcome=STORED_OFFLINE"))
            // Longer than one poll interval (5 s): neither a push nor a poll may carry it over.
            Thread.sleep(6_000)
            assertTrue("nothing reached this client", live.messages.isEmpty())

            val outMine = r.enqueue(appId, user, here, "mine", installation = mine)
            assertTrue("pushed to this installation: $outMine", outMine.contains("outcome=PUSHED"))
            waitFor(2_000, "this installation's own message", { r.relayTail() }) { live.messages.isNotEmpty() }
            assertEquals(listOf(here), live.messages.map { it.sinchMessageId })
            assertTrue(r.sinkReports().none { it.sinchMessageId == elsewhere })
        } finally {
            live.client.stop()
        }
    }

    @Test
    fun `the provider copy of a socket-delivered message is dropped and nothing is queued`() {
        val r = relayOrSkip()
        val user = uniqueUser("providerdup")
        val sinchId = "contract-provider-dup-${System.nanoTime()}"
        val store = InMemorySocketStateStore()
        val seen = SeenSet(store)
        val live = Live(r, user, appId, store = store, seen = seen)
        live.client.start()
        try {
            waitFor(10_000, "connected", { r.relayTail() }) { live.connected }
            r.enqueue(appId, user, sinchId, "provider duplicate")
            waitFor(10_000, "the socket delivery", { r.relayTail() }) { live.messages.isNotEmpty() }
            val id = live.messages.first().id
            waitFor(5_000, "the report Ack", { live.logger.lines.joinToString("\n") }) {
                live.logger.lines.any { it.contains("ack accepted=true") }
            }

            val outbox = ReportOutbox(InMemorySocketStateStore())
            val decision = PushDedupe(seen, outbox).decide(providerPush(id))

            assertEquals(PushDecision.Drop, decision)
            assertTrue("nothing is queued", outbox.snapshot().isEmpty())
        } finally {
            live.client.stop()
        }
    }

    @Test
    fun `a provider push the socket never delivered is queued exactly once`() {
        val r = relayOrSkip()
        val user = uniqueUser("providerqueue")
        val id = "contract-provider-only-${System.nanoTime()}"
        val store = InMemorySocketStateStore()
        val seen = SeenSet(store)
        val live = Live(r, user, appId, store = store, seen = seen)
        live.client.start()
        try {
            waitFor(10_000, "connected", { r.relayTail() }) { live.connected }
            val outbox = ReportOutbox(InMemorySocketStateStore())
            val dedupe = PushDedupe(seen, outbox)

            val first = dedupe.decide(providerPush(id))
            val second = dedupe.decide(providerPush(id))

            assertTrue("rendered: $first", first is PushDecision.Render)
            assertEquals(PushDecision.Drop, second)
            assertEquals(listOf(id), outbox.snapshot().map { it.messageId })
            assertEquals(listOf("contract-subscriber"), outbox.snapshot().map { it.subscriberId })
            assertTrue("the socket delivered nothing", live.messages.isEmpty())
        } finally {
            live.client.stop()
        }
    }

    private fun providerPush(messageId: String) = mapOf(
        PushDedupe.MESSAGE_ID_KEY to messageId,
        PushDedupe.SUBSCRIBER_ID_KEY to "contract-subscriber",
    )
}
