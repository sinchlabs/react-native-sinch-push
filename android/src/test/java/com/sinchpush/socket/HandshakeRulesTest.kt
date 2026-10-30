package com.sinchpush.socket

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import sinch.push.delivery.v1beta1.ws.AuthChallenge
import sinch.push.delivery.v1beta1.ws.CloseReason
import sinch.push.delivery.v1beta1.ws.Ping
import sinch.push.delivery.v1beta1.ws.Platform
import sinch.push.v1beta1.resources.BackgroundServiceState

/** SB-16, SB-18 .. SB-24, SB-29, SB-38, SB-39, SB-54, SB-57, SB-59, SB-60 against the real client over fakes. */
class HandshakeRulesTest {

    @Before
    fun resetPresentationBuffer() = SinchPushSocketStore.clear()

    @Test
    fun `SB18_helloCarriesEveryFieldTheRelayValidates`() {
        val h = Harness()
        h.start()
        assertTrue("no Hello before the socket opens", h.conn.sentBytes.isEmpty())
        h.conn.serverOpens()
        val hello = h.conn.hellos.single()
        assertEquals("jwt-secret-token", hello.auth_token)
        assertEquals("proj-1", hello.project_id)
        assertEquals("app-1", hello.app_id)
        assertEquals("user-1", hello.user_id)
        assertEquals(Platform.ANDROID, hello.platform)
        assertEquals(SocketSpec.DEFAULT_SDK_VERSION, hello.sdk_version)
        assertEquals("the Hello is the very first frame", 1, h.conn.sentBytes.size)
        assertEquals(FrameCodec.CLIENT_TAG_HELLO, h.conn.sentBytes[0][0].toInt())
    }

    @Test
    fun `SB19_platformIsTheOsNotTheBackgroundSurface`() {
        for (backgroundService in listOf(true, false)) {
            val h = Harness(testConfig(backgroundService = backgroundService))
            h.start()
            h.conn.serverOpens()
            assertEquals(Platform.ANDROID, h.conn.hellos.single().platform)
        }
    }

    @Test
    fun `SB19_sdkVersionComesFromConfigWithASaneDefault`() {
        val custom = Harness(testConfig(sdkVersion = "rn-sinch-push/9.9.9"))
        custom.start(); custom.conn.serverOpens()
        assertEquals("rn-sinch-push/9.9.9", custom.conn.hellos.single().sdk_version)

        val default = Harness(testConfig(sdkVersion = ""))
        default.start(); default.conn.serverOpens()
        assertEquals(SocketSpec.DEFAULT_SDK_VERSION, default.conn.hellos.single().sdk_version)
        assertTrue(SocketSpec.DEFAULT_SDK_VERSION.startsWith("rn-sinch-push/"))
    }

    @Test
    fun `SB20_connectingThenReconnectingAndLastErrorClearedOnEachAttempt`() {
        val h = Harness(random = 1.0)
        h.start()
        assertEquals("connecting", h.status)
        h.conn.listener.onFailure(RuntimeException("boom"))
        assertEquals("reconnecting", h.status)
        assertEquals("boom", h.state.lastError)
        h.scheduler.advanceBy(1000)
        assertEquals("a new attempt publishes reconnecting", "reconnecting", h.status)
        assertNull("SB-24: lastError must not survive into a fresh attempt", h.state.lastError)
        h.conn.serverOpens()
        assertEquals(1, h.conn.hellos.size)
    }

    @Test
    fun `SB21_helloAckPublishesConnectedEmitsPooledMessagesWithEmptyTokenAndPolls`() {
        val h = Harness()
        h.start()
        h.connect("conn-7", 5000, pooled("a"), pooled("b"))
        assertEquals("connected", h.status)
        assertEquals("conn-7", h.state.connectionId)
        assertEquals(listOf("a", "b"), h.messages.map { it.id })
        assertTrue(h.messages.all { it.ackToken == "" })
        assertEquals(1, h.conn.polls.size)
    }

    @Test
    fun `SB22_pollIntervalIsConfigThenServerThenDefaultAndFlooredBeforePublishing`() {
        fun published(config: PushSocketConfig, server: Int): Int {
            val h = Harness(config)
            h.startAndConnect(pollMs = server)
            return h.state.pollIntervalMs
        }
        assertEquals("server asks 50ms, floor wins and is what is published", 1000, published(testConfig(), 50))
        assertEquals("config beats server", 3000, published(testConfig(pollIntervalMs = 3000), 9000))
        assertEquals("server beats default", 7000, published(testConfig(), 7000))
        assertEquals("default", 5000, published(testConfig(), 0))
        assertEquals("config below floor is floored too", 1000, published(testConfig(pollIntervalMs = 200), 0))
    }

    @Test
    fun `SB22_timerUsesTheFlooredIntervalNotTheServerOne`() {
        val h = Harness()
        h.startAndConnect(pollMs = 50)
        assertEquals(1, h.conn.polls.size)
        h.scheduler.advanceBy(999)
        assertEquals(1, h.conn.polls.size)
        h.scheduler.advanceBy(1)
        assertEquals(2, h.conn.polls.size)
    }

    @Test
    fun `SB23_immediatePollAfterEveryHelloAckIncludingReconnect`() {
        val h = Harness(random = 0.0)
        h.startAndConnect()
        assertEquals("poll before any interval tick", 1, h.conn.polls.size)
        h.conn.serverSends(closeFrame(CloseReason.STALE))
        h.connect("conn-2")
        assertEquals(1, h.conn.polls.size)
        h.conn.serverSends(closeFrame(CloseReason.POOL_FULL, "rate_limited"))
        h.scheduler.advanceBy(0)
        h.connect("conn-3")
        assertEquals(1, h.conn.polls.size)
    }

    @Test
    fun `SB24_lastErrorCarriesTheCloseDetailOrTheReasonForm`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSends(closeFrame(CloseReason.POOL_FULL, "rate_limited"))
        assertEquals("rate_limited", h.state.lastError)
        h.scheduler.advanceBy(30_000)
        h.connect("conn-2")
        h.conn.serverSends(closeFrame(CloseReason.INTERNAL))
        assertEquals("server closed (reason=4)", h.state.lastError)
    }

    @Test
    fun `SB24_stateSurfaceIsNativeAndComplete`() {
        val h = Harness()
        h.startAndConnect()
        val map = h.state
        assertEquals("connected", map.status)
        assertEquals("conn-1", map.connectionId)
        assertEquals(5000, map.pollIntervalMs)
        assertEquals(0, map.reconnectAttempts)
        assertNull(map.lastError)
    }

    @Test
    fun `SB29_lastSeenMessageIdIsTheNewestProcessedIdAndSurvivesRestart`() {
        val store = InMemorySocketStateStore()
        val first = Harness(store = store)
        first.start(); first.conn.serverOpens()
        assertEquals("", first.conn.hellos.single().last_seen_message_id)
        first.conn.serverSends(helloAck())
        first.conn.serverSends(pushMessage("m1").copy(message = pooled("m1", enqueuedAt = 1_000)))
        first.conn.serverSends(pushMessage("m2").copy(message = pooled("m2", enqueuedAt = 2_000)))
        // A duplicate of the older message is a hit; it must not walk the marker back.
        first.conn.serverSends(pushMessage("m1").copy(message = pooled("m1", enqueuedAt = 1_000)))
        first.conn.serverSends(closeFrame(CloseReason.STALE))
        first.conn.serverOpens()
        assertEquals("m2", first.conn.hellos.single().last_seen_message_id)

        val restarted = Harness(store = store)
        restarted.start(); restarted.conn.serverOpens()
        assertEquals("m2", restarted.conn.hellos.single().last_seen_message_id)
    }

    @Test
    fun `SB38_pingIsAnsweredWithAPongEchoingTheCorrelationId`() {
        val h = Harness()
        h.startAndConnect()
        val pollsBefore = h.conn.polls.size
        val timers = h.scheduler.pendingTimers
        h.conn.serverSends(Ping(correlation_id = "corr-9"))
        assertEquals("corr-9", h.conn.pongs.single().correlation_id)
        assertEquals(pollsBefore, h.conn.polls.size)
        assertEquals("poll timer undisturbed", timers, h.scheduler.pendingTimers)
        assertEquals(0, h.state.reconnectAttempts)
    }

    @Test
    fun `SB39_authChallengeIsReservedKeepsTheConnectionAndIsLogged`() {
        val h = Harness()
        h.startAndConnect()
        val sockets = h.transport.connections.size
        h.conn.serverSends(AuthChallenge(nonce = "n"))
        assertEquals("connected", h.status)
        assertEquals(sockets, h.transport.connections.size)
        assertTrue(h.conn.closes.isEmpty())
        assertTrue(h.logger.any("AuthChallenge"))
        assertFalse("not reported as an unknown tag", h.logger.any("unknown"))
    }

    @Test
    fun `SB16_unknownTagAndMalformedEnvelopeAreDroppedAndLoggedSeparately`() {
        val h = Harness()
        h.startAndConnect()
        h.conn.serverSendsRaw(bytesOf(200, 0))
        val afterUnknown = h.logger.lines.toList()
        assertEquals("connected", h.status)
        assertTrue(afterUnknown.any { it.startsWith("I ignoring") })

        h.conn.serverSendsRaw(bytesOf(FrameCodec.SERVER_TAG_ACK, 5, 1))
        assertEquals("connected", h.status)
        assertTrue(h.logger.lines.any { it.startsWith("W dropping malformed server frame") })
        assertTrue("the two lines are distinguishable", afterUnknown.none { it.contains("malformed") })
        assertTrue(h.conn.closes.isEmpty())
    }

    @Test
    fun `SB54_ownerIsTheForegroundServiceByDefaultAndInProcessWhenOptedOut`() {
        assertEquals(SocketOwner.SERVICE, ownerFor(testConfig()))
        assertEquals(SocketOwner.IN_PROCESS, ownerFor(testConfig(backgroundService = false)))
    }

    @Test
    fun `SB57_inProcessHelloBackgroundIsFalseWhateverTheVisibility`() {
        for (visible in listOf(true, false)) {
            val h = Harness(testConfig(backgroundService = false), appVisible = visible)
            h.start(); h.conn.serverOpens()
            assertFalse("in-process, visible=$visible", h.conn.hellos.single().background)
        }
    }

    @Test
    fun `SB57_serviceHelloBackgroundIsNotAppVisibleAtConnect`() {
        val hidden = Harness(testConfig(backgroundService = true), appVisible = false)
        hidden.start(); hidden.conn.serverOpens()
        assertTrue(hidden.conn.hellos.single().background)

        val shown = Harness(testConfig(backgroundService = true), appVisible = true)
        shown.start(); shown.conn.serverOpens()
        assertFalse(shown.conn.hellos.single().background)
    }

    @Test
    fun `SB57_visibilityIsReadAtEachConnectNotCachedFromTheFirst`() {
        val h = Harness(testConfig(backgroundService = true), random = 0.0, appVisible = true)
        h.start(); h.conn.serverOpens()
        assertFalse(h.conn.hellos.single().background)

        h.appVisible = false
        h.conn.listener.onFailure(RuntimeException("drop"))
        h.scheduler.advanceBy(1000)
        h.conn.serverOpens()
        assertTrue("the reconnect's Hello sees the new visibility", h.conn.hellos.single().background)
    }

    // ----------------------------------------------- SB-59 / SB-60 device info

    @Test
    fun `SB18_helloCarriesAllTwelveFieldsOfTheRelayContract`() {
        val store = InMemorySocketStateStore().apply { saveLastSeenMessageId("msg-9") }
        val h = Harness(
            testConfig(sdkVersion = "rn-sinch-push/9.9.9"),
            store = store,
            environment = FakeDeviceEnvironment(
                osVersion = "14",
                bundleId = "com.example.host",
                installationId = "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11",
            ),
        )
        h.start(); h.conn.serverOpens()
        val hello = h.conn.hellos.single()
        assertEquals("jwt-secret-token", hello.auth_token)
        assertEquals("proj-1", hello.project_id)
        assertEquals("app-1", hello.app_id)
        assertEquals("user-1", hello.user_id)
        assertEquals(Platform.ANDROID, hello.platform)
        // The service owner with the app not visible: a background Hello.
        assertTrue(hello.background)
        assertEquals("msg-9", hello.last_seen_message_id)
        assertEquals("rn-sinch-push/9.9.9", hello.sdk_version)
        assertEquals("0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11", hello.installation_id)
        assertEquals("14", hello.os_version)
        assertEquals("com.example.host", hello.bundle_id)
        assertEquals(BackgroundServiceState.ENABLED_RUNNING, hello.background_service)
    }

    @Test
    fun `SB60_serviceEnabledAndRunningWithNotificationsIsEnabledRunning`() {
        val h = Harness(testConfig(backgroundService = true), environment = FakeDeviceEnvironment(serviceRunning = true))
        h.start(); h.conn.serverOpens()
        assertEquals(BackgroundServiceState.ENABLED_RUNNING, h.conn.hellos.single().background_service)
    }

    @Test
    fun `SB60_backgroundServiceFalseIsDisabledEvenIfAServiceIsRunning`() {
        val h = Harness(
            testConfig(backgroundService = false),
            environment = FakeDeviceEnvironment(serviceRunning = true),
        )
        h.start(); h.conn.serverOpens()
        assertEquals(BackgroundServiceState.DISABLED, h.conn.hellos.single().background_service)
    }

    @Test
    fun `SB60_noSocketConfigIsDisabled`() {
        val provider = SystemDeviceInfoProvider(FakeDeviceEnvironment(serviceRunning = true), RecordingLogger())
        assertEquals(BackgroundServiceState.DISABLED, provider.backgroundServiceState(null))
    }

    @Test
    fun `SB60_enabledButServiceNotRunningIsEnabledNotRunning`() {
        val h = Harness(
            testConfig(backgroundService = true),
            environment = FakeDeviceEnvironment(serviceRunning = false),
        )
        h.start(); h.conn.serverOpens()
        assertEquals(BackgroundServiceState.ENABLED_NOT_RUNNING, h.conn.hellos.single().background_service)
    }

    @Test
    fun `SB60_postNotificationsDeniedMakesARunningServiceEnabledNotRunning`() {
        val h = Harness(
            testConfig(backgroundService = true),
            environment = FakeDeviceEnvironment(serviceRunning = true, notificationPermissionGranted = false),
        )
        h.start(); h.conn.serverOpens()
        assertEquals(BackgroundServiceState.ENABLED_NOT_RUNNING, h.conn.hellos.single().background_service)
    }

    @Test
    fun `SB60_aServiceThatCouldNotStayInTheForegroundSaysNotRunningInTheNextHello`() {
        SocketServiceState.resetForTest()
        SocketServiceState.onCreated()
        assertTrue(SocketServiceState.running)
        // The environment reads SocketServiceState lazily, at each Hello, as
        // AndroidDeviceEnvironment does - not a value captured when it was built.
        val env = FakeDeviceEnvironment(serviceRunningSource = { SocketServiceState.running })
        val h = Harness(testConfig(backgroundService = true), random = 0.0, environment = env)
        h.start(); h.conn.serverOpens()
        assertEquals(BackgroundServiceState.ENABLED_RUNNING, h.conn.hellos.single().background_service)

        // The service's own startForeground (or onTimeout) failed.
        SocketServiceState.onPromotionFailed(IllegalStateException("ForegroundServiceStartNotAllowedException"))

        assertFalse("a failed promotion clears the running flag", SocketServiceState.running)
        assertTrue(SocketServiceState.lastStartFailure!!.contains("IllegalStateException"))
        h.conn.listener.onFailure(RuntimeException("drop"))
        h.scheduler.advanceBy(1000)
        h.conn.serverOpens()
        assertEquals(BackgroundServiceState.ENABLED_NOT_RUNNING, h.conn.hellos.single().background_service)

        SocketServiceState.resetForTest()
    }

    @Test
    fun `SB60_theCallersRefusalOnlyRecordsTheReasonAndLeavesTheServiceFlagToTheService`() {
        // N1: startForegroundService refused in the caller. No service instance
        // exists, so the caller has nothing to say about whether one is running;
        // a service that was already up must keep reporting ENABLED_RUNNING.
        SocketServiceState.resetForTest()
        SocketServiceState.onCreated()

        SocketServiceState.recordStartFailure(SecurityException("missing FOREGROUND_SERVICE_DATA_SYNC"))

        assertTrue("only the service writes the running flag", SocketServiceState.running)
        assertTrue(SocketServiceState.lastStartFailure!!.contains("SecurityException"))

        SocketServiceState.resetForTest()
        SocketServiceState.recordStartFailure(IllegalStateException("not allowed"))
        assertFalse("and it does not invent a running service either", SocketServiceState.running)
        SocketServiceState.resetForTest()
    }

    @Test
    fun `SB60_theServiceFlagFollowsOnCreateAndOnDestroy`() {
        SocketServiceState.resetForTest()
        assertFalse(SocketServiceState.running)
        SocketServiceState.onCreated()
        assertTrue(SocketServiceState.running)
        SocketServiceState.onDestroyed()
        assertFalse(SocketServiceState.running)
    }

    @Test
    fun `SB59_anUnavailableInstallationIdSendsAnEmptyIdAndKeepsTheConnection`() {
        val env = FakeDeviceEnvironment(installationId = null)
        val h = Harness(environment = env)
        h.start(); h.conn.serverOpens()
        val hello = h.conn.hellos.single()
        assertEquals("", hello.installation_id)
        assertEquals("the rest of the device info is unaffected", "com.example.host", hello.bundle_id)
        assertTrue(h.logger.lines.any { it.startsWith("W installation id unavailable") })
        assertEquals("connecting", h.states.first().status)
        assertTrue("the connection is not failed", h.states.none { it.status == "error" })
    }

    @Test
    fun `SB59_anInstallationIdThatWasUnavailableIsAskedForAgainOnTheNextHello`() {
        val env = FakeDeviceEnvironment(installationId = null)
        val h = Harness(random = 0.0, environment = env)
        h.start(); h.conn.serverOpens()
        assertEquals("", h.conn.hellos.single().installation_id)

        env.installationId = "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11"
        h.conn.listener.onFailure(RuntimeException("drop"))
        h.scheduler.advanceBy(1000)
        h.conn.serverOpens()
        assertEquals("0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11", h.conn.hellos.single().installation_id)
        assertEquals(2, env.installationIdCalls)
    }

    @Test
    fun `SB59_osVersionBundleIdAndSdkVersionComeFromTheirOneSource`() {
        val h = Harness(
            testConfig(sdkVersion = ""),
            environment = FakeDeviceEnvironment(osVersion = "15", bundleId = "org.other.app"),
        )
        h.start(); h.conn.serverOpens()
        val hello = h.conn.hellos.single()
        assertEquals("15", hello.os_version)
        assertEquals("org.other.app", hello.bundle_id)
        assertEquals(SocketSpec.DEFAULT_SDK_VERSION, hello.sdk_version)
    }

    @Test
    fun `SB19_defaultSdkVersionMatchesPackageJson`() {
        val json = listOf("../package.json", "package.json").map(::File).first { it.exists() }.readText()
        val version = Regex("\"version\"\\s*:\\s*\"([^\"]+)\"").find(json)!!.groupValues[1]
        assertEquals("rn-sinch-push/$version", SocketSpec.DEFAULT_SDK_VERSION)
    }
}
