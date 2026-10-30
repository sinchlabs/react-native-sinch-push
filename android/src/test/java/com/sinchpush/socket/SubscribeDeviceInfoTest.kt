package com.sinchpush.socket

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test
import sinch.push.v1beta1.resources.BackgroundServiceState

/**
 * SB-61: `Subscribe` carries the same device info as `Hello`, and JS is told
 * when the one fact that moves at runtime - `background_service` - changes.
 *
 * [DeviceInfoChangeNotifier] is the pure part (injectable value and sink); the
 * wiring to [SocketServiceState] is exercised through the same listener hook the
 * production [DeviceInfoChanges] installs.
 */
class SubscribeDeviceInfoTest {

    private val logger = RecordingLogger()

    @After
    fun tearDown() {
        SinchPushSocketController.onServiceStopRequested(SinchPushSocketController.ANY_GENERATION)
        SocketServiceState.changeListener = null
        SocketServiceState.resetForTest()
    }

    /** A notifier over a settable value, recording what reached the sink. */
    private class Probe(var value: BackgroundServiceState, var deliver: Boolean = true) {
        val emitted = mutableListOf<BackgroundServiceState>()
        var sinkCalls = 0
        var failing = false
        val notifier = DeviceInfoChangeNotifier(
            current = { if (failing) error("cannot compute") else value },
            sink = { state ->
                sinkCalls++
                if (deliver) emitted.add(state)
                deliver
            },
        )
    }

    // --- DeviceInfoChangeNotifier --------------------------------------------

    @Test
    fun `SB61_aChangeEmitsOnceAndAnUnchangedValueEmitsNothing`() {
        val p = Probe(BackgroundServiceState.ENABLED_NOT_RUNNING)
        p.notifier.prime()

        repeat(3) { p.notifier.check() }
        assertEquals(emptyList<BackgroundServiceState>(), p.emitted)

        p.value = BackgroundServiceState.ENABLED_RUNNING
        repeat(3) { p.notifier.check() }
        assertEquals(listOf(BackgroundServiceState.ENABLED_RUNNING), p.emitted)

        p.value = BackgroundServiceState.ENABLED_NOT_RUNNING
        p.notifier.check()
        p.value = BackgroundServiceState.ENABLED_RUNNING
        p.notifier.check()
        assertEquals(
            listOf(
                BackgroundServiceState.ENABLED_RUNNING,
                BackgroundServiceState.ENABLED_NOT_RUNNING,
                BackgroundServiceState.ENABLED_RUNNING,
            ),
            p.emitted,
        )
    }

    @Test
    fun `SB61_primingRecordsTheValueJsAlreadyKnowsWithoutEmitting`() {
        val p = Probe(BackgroundServiceState.DISABLED)
        p.notifier.prime()
        p.notifier.check()
        assertEquals(0, p.sinkCalls)
    }

    @Test
    fun `SB61_withoutPrimingTheFirstObservedValueIsReported`() {
        val p = Probe(BackgroundServiceState.ENABLED_RUNNING)
        p.notifier.check()
        p.notifier.check()
        assertEquals(listOf(BackgroundServiceState.ENABLED_RUNNING), p.emitted)
    }

    @Test
    fun `SB61_aChangeWithNoReactContextIsOfferedAgainRatherThanLost`() {
        val p = Probe(BackgroundServiceState.DISABLED)
        p.notifier.prime()
        p.value = BackgroundServiceState.ENABLED_RUNNING

        p.deliver = false // no React context yet
        p.notifier.check()
        p.notifier.check()
        assertEquals(2, p.sinkCalls)
        assertEquals(emptyList<BackgroundServiceState>(), p.emitted)

        p.deliver = true
        p.notifier.check()
        p.notifier.check()
        assertEquals(listOf(BackgroundServiceState.ENABLED_RUNNING), p.emitted)
        assertEquals(3, p.sinkCalls)
    }

    @Test
    fun `SB61_aValueThatCannotBeComputedIsNotAChange`() {
        val p = Probe(BackgroundServiceState.ENABLED_RUNNING)
        p.notifier.prime()
        p.failing = true

        p.notifier.check() // must not throw

        assertEquals(0, p.sinkCalls)
        p.failing = false
        p.notifier.check()
        assertEquals(0, p.sinkCalls)
    }

    // --- the inputs of the value ----------------------------------------------

    /** The production derivation (SB-60) over the live [SocketServiceState], as [DeviceInfoChanges] builds it. */
    private fun serviceDriven(config: () -> PushSocketConfig?): Probe {
        val provider = SystemDeviceInfoProvider(
            FakeDeviceEnvironment(serviceRunningSource = { SocketServiceState.running }),
            logger,
        )
        val emitted = Probe(BackgroundServiceState.DISABLED)
        val notifier = DeviceInfoChangeNotifier(
            current = { provider.backgroundServiceState(config()) },
            sink = { state -> emitted.emitted.add(state); true },
        )
        SocketServiceState.resetForTest()
        notifier.prime()
        SocketServiceState.changeListener = { notifier.check() }
        return emitted
    }

    @Test
    fun `SB61_theServiceLifecycleEmitsOncePerTransition`() {
        val config = testConfig(backgroundService = true)
        val probe = serviceDriven { config }

        // Primed as ENABLED_NOT_RUNNING: the service has not come up yet.
        SocketServiceState.onCreated()
        assertEquals(listOf(BackgroundServiceState.ENABLED_RUNNING), probe.emitted)

        SocketServiceState.onPromotionFailed(IllegalStateException("not allowed"))
        assertEquals(
            listOf(BackgroundServiceState.ENABLED_RUNNING, BackgroundServiceState.ENABLED_NOT_RUNNING),
            probe.emitted,
        )

        // The destroy that follows a failed promotion changes nothing.
        SocketServiceState.onDestroyed()
        assertEquals(2, probe.emitted.size)

        SocketServiceState.onCreated()
        SocketServiceState.onDestroyed()
        assertEquals(
            listOf(
                BackgroundServiceState.ENABLED_RUNNING,
                BackgroundServiceState.ENABLED_NOT_RUNNING,
                BackgroundServiceState.ENABLED_RUNNING,
                BackgroundServiceState.ENABLED_NOT_RUNNING,
            ),
            probe.emitted,
        )
    }

    @Test
    fun `SB61_aCallerSideRefusalDoesNotMoveTheValue`() {
        val probe = serviceDriven { testConfig(backgroundService = true) }
        SocketServiceState.onCreated()
        probe.emitted.clear()

        // Only the service writes the running flag (SB-60), so this is no change.
        SocketServiceState.recordStartFailure(SecurityException("missing FGS permission"))

        assertEquals(emptyList<BackgroundServiceState>(), probe.emitted)
    }

    @Test
    fun `SB61_aChangedBackgroundServiceSettingOrNoConfigIsAChange`() {
        var config: PushSocketConfig? = null
        val provider = SystemDeviceInfoProvider(FakeDeviceEnvironment(serviceRunning = false), logger)
        val emitted = mutableListOf<BackgroundServiceState>()
        val notifier = DeviceInfoChangeNotifier(
            current = { provider.backgroundServiceState(config) },
            sink = { emitted.add(it); true },
        )
        notifier.prime() // no config: DISABLED

        config = testConfig(backgroundService = true) // startPushSocket
        notifier.check()
        config = testConfig(backgroundService = false) // restarted in-process
        notifier.check()
        config = null // stopPushSocket
        notifier.check()

        assertEquals(
            listOf(BackgroundServiceState.ENABLED_NOT_RUNNING, BackgroundServiceState.DISABLED),
            emitted,
        )
    }

    // --- getDeviceInfo: the same facts as Hello ---------------------------------

    @Test
    fun `SB61_subscribeAndHelloAreToldTheSameFacts`() {
        val env = FakeDeviceEnvironment(osVersion = "15", bundleId = "com.example.other", serviceRunning = true)
        val provider = SystemDeviceInfoProvider(env, logger)
        val config = testConfig(backgroundService = true)

        assertEquals(provider.current(config, DeviceInfoPurpose.HELLO), provider.current(config, DeviceInfoPurpose.SUBSCRIBE))
    }

    @Test
    fun `SB61_theSdkVersionOverrideIsForHelloOnlyAndSubscribeAlwaysReportsTheBuiltInOne`() {
        val provider = SystemDeviceInfoProvider(FakeDeviceEnvironment(serviceRunning = true), logger)
        val config = testConfig(sdkVersion = "rn-sinch-push/9.9.9", backgroundService = true)

        assertEquals("rn-sinch-push/9.9.9", provider.current(config, DeviceInfoPurpose.HELLO).sdkVersion)
        assertEquals(SocketSpec.DEFAULT_SDK_VERSION, provider.current(config, DeviceInfoPurpose.SUBSCRIBE).sdkVersion)
        assertEquals(
            SocketSpec.DEFAULT_SDK_VERSION,
            provider.current(config, DeviceInfoPurpose.SUBSCRIBE).toJsMap()["sdkVersion"],
        )
    }

    // --- the in-memory config follows the service owner -------------------------

    @Test
    fun `SB61_theServiceOwnersStopForgetsTheConfigThisProcessConsidersStarted`() {
        SinchPushSocketController.installClientForTest(null)
        SinchPushSocketController.start(
            testConfig(backgroundService = true),
            startService = {},
            startInProcess = {},
        )
        assertNotNull(SinchPushSocketController.activeConfigForTest())

        // ACTION_STOP, carrying what stop() saw.
        SinchPushSocketController.onServiceStopRequested(SinchPushSocketController.generationForTest())

        assertNull(SinchPushSocketController.activeConfigForTest())
    }

    @Test
    fun `SB61_aStopWithoutASequenceStillForgetsTheConfig`() {
        SinchPushSocketController.start(testConfig(backgroundService = true), startService = {}, startInProcess = {})

        SinchPushSocketController.onServiceStopRequested(SinchPushSocketController.ANY_GENERATION)

        assertNull(SinchPushSocketController.activeConfigForTest())
    }

    @Test
    fun `SB61_aStopQueuedBehindANewerStartDoesNotForgetTheNewConfig`() {
        SinchPushSocketController.start(testConfig(backgroundService = true), startService = {}, startInProcess = {})
        val seqAtStop = SinchPushSocketController.generationForTest()
        // stopPushSocket's STOP is still queued when startPushSocket runs.
        val newer = testConfig(backgroundService = false)
        SinchPushSocketController.start(newer, startService = {}, startInProcess = {})

        SinchPushSocketController.onServiceStopRequested(seqAtStop)

        assertSame(newer, SinchPushSocketController.activeConfigForTest())
    }

    @Test
    fun `SB61_withoutASocketConfigTheBackgroundServiceIsDisabledAndTheSdkVersionIsTheBuiltInOne`() {
        val provider = SystemDeviceInfoProvider(FakeDeviceEnvironment(serviceRunning = true), logger)

        val info = provider.current(null, DeviceInfoPurpose.SUBSCRIBE)

        assertEquals(BackgroundServiceState.DISABLED, info.backgroundService)
        assertEquals(SocketSpec.DEFAULT_SDK_VERSION, info.sdkVersion)
    }

    @Test
    fun `SB61_anUnavailableInstallationIdFailsInsteadOfBecomingAnEmptyId`() {
        val provider = SystemDeviceInfoProvider(FakeDeviceEnvironment(installationId = null), logger)

        // `Hello` sends an empty id (SB-59); `getDeviceInfo` rejects so JS can
        // subscribe without device info.
        assertThrows(InstallationIdUnavailableException::class.java) { provider.current(null, DeviceInfoPurpose.SUBSCRIBE) }
    }

    @Test
    fun `SB61_theMapJsReceivesHasAllSixFieldsAsStrings`() {
        val env = FakeDeviceEnvironment(
            osVersion = "14",
            bundleId = "com.example.host",
            installationId = "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11",
            serviceRunning = true,
        )
        val info = SystemDeviceInfoProvider(env, logger)
            .current(testConfig(sdkVersion = "rn-sinch-push/1.1.0", backgroundService = true), DeviceInfoPurpose.SUBSCRIBE)

        assertEquals(
            mapOf(
                "installationId" to "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11",
                "platform" to "android",
                "osVersion" to "14",
                "sdkVersion" to "rn-sinch-push/1.1.0",
                "bundleId" to "com.example.host",
                "backgroundService" to "ENABLED_RUNNING",
            ),
            info.toJsMap(),
        )
    }

    @Test
    fun `SB61_everyBackgroundServiceStateHasItsNameForJs`() {
        assertEquals("UNSUPPORTED", BackgroundServiceState.UNSUPPORTED.jsName())
        assertEquals("DISABLED", BackgroundServiceState.DISABLED.jsName())
        assertEquals("ENABLED_RUNNING", BackgroundServiceState.ENABLED_RUNNING.jsName())
        assertEquals("ENABLED_NOT_RUNNING", BackgroundServiceState.ENABLED_NOT_RUNNING.jsName())
        assertEquals("RELAY_DISABLED", BackgroundServiceState.RELAY_DISABLED.jsName())
    }
}
