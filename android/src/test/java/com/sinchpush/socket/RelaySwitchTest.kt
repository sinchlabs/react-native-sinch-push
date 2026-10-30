package com.sinchpush.socket

import android.content.SharedPreferences
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.WritableMap
import com.sinchpush.settleRelaySwitch
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import sinch.push.v1beta1.resources.BackgroundServiceState

/**
 * SB-66: the relay off switch, with its collaborators as seams - no `Context`,
 * no `PackageManager`, no React emitter. The service's `onStartCommand` cannot
 * be constructed on the JVM, so the rule it applies ([decideSocketServiceStart])
 * is asserted instead, and the real `SharedPreferences` file by way of an
 * in-memory fake.
 */
class RelaySwitchTest {

    private val logger = RecordingLogger()

    @Before
    fun setUp() {
        // `activeConfig` is process-wide and other tests leave theirs behind.
        SinchPushSocketController.onServiceStopRequested(SinchPushSocketController.ANY_GENERATION)
        SocketServiceState.resetForTest()
        SinchPushSocketStore.clear()
    }

    @After
    fun tearDown() {
        SinchPushSocketController.onServiceStopRequested(SinchPushSocketController.ANY_GENERATION)
        SinchPushSocketController.installClientForTest(null)
        SinchPushSocketController.setStateSinkForTest(null)
        SocketServiceState.resetForTest()
    }

    /** Records the order of everything the switch touches. */
    private class Calls {
        val log = mutableListOf<String>()
    }

    private class FakeSwitch(
        private val calls: Calls,
        private var on: Boolean = true,
        /** `false`: the value is applied in memory but never reaches storage. */
        private val commitSucceeds: Boolean = true,
    ) : RelaySwitch {
        override fun isEnabled() = on
        override fun setEnabled(enabled: Boolean): Boolean {
            on = enabled
            calls.log.add("persist:$enabled")
            return commitSucceeds
        }
    }

    private class FakeToggler(private val calls: Calls) : SocketServiceComponentToggler {
        var lastEnabled: Boolean? = null
        override fun setSocketServiceEnabled(enabled: Boolean) {
            lastEnabled = enabled
            calls.log.add("component:${if (enabled) "default" else "disabled"}")
        }
    }

    // --- off / on -------------------------------------------------------------

    @Test
    fun `SB66_offStopsTheSocketThenDisablesTheComponentAndPersistsFirst`() {
        val calls = Calls()
        val relay = FakeSwitch(calls)
        val toggler = FakeToggler(calls)

        val persisted = applyRelaySwitch(
            enabled = false,
            relaySwitch = relay,
            componentToggler = toggler,
            stopSocket = { calls.log.add("stop") },
            clearSocketConfig = { calls.log.add("clearConfig") },
            onChanged = { calls.log.add("changed") },
        )

        assertEquals(
            listOf("persist:false", "stop", "clearConfig", "component:disabled", "changed"),
            calls.log,
        )
        assertFalse(relay.isEnabled())
        assertTrue("the choice reached storage", persisted)
    }

    /**
     * A stop the platform refuses (a background `startService` for `ACTION_STOP`
     * throws on API 26+) must not abort the switch: it is logged and everything
     * else still happens - including the disable, which is the part that makes
     * "off" hold across a `START_STICKY` restart.
     */
    @Test
    fun `SB66_aStopThatThrowsStillDisablesTheComponent`() {
        val calls = Calls()
        val toggler = FakeToggler(calls)
        val harness = Harness()
        harness.startAndConnect()
        SinchPushSocketController.installClientForTest(harness.client)

        // No exception escapes: the switch was applied, so the bridge resolves.
        applyRelaySwitch(
            enabled = false,
            relaySwitch = FakeSwitch(calls),
            componentToggler = toggler,
            stopSocket = {
                // The real off-path stop, with the platform start refused.
                SinchPushSocketController.stopForRelayOff(
                    serviceRunning = true,
                    stopService = { error("the platform refused the STOP start") },
                )
            },
            clearSocketConfig = { calls.log.add("clearConfig") },
            onChanged = { calls.log.add("changed") },
        )

        assertFalse("the client must be closed even though the service stop was refused", SinchPushSocketController.isActive())
        assertEquals("the component must not stay enabled", false, toggler.lastEnabled)
        assertEquals(
            listOf("persist:false", "clearConfig", "component:disabled", "changed"),
            calls.log,
        )
    }

    /**
     * Turning the relay off with nothing running must not make a background start
     * at all: `ACTION_STOP` is sent only when a service is actually up. Counted
     * rather than asserted inside the seam, because a `fail()` there would be
     * swallowed by the very `catch` this test is about.
     */
    @Test
    fun `SB66_offWhileNoServiceRunsSendsNoStopStart`() {
        val calls = Calls()
        var stopStarts = 0

        applyRelaySwitch(
            enabled = false,
            relaySwitch = FakeSwitch(calls),
            componentToggler = FakeToggler(calls),
            stopSocket = {
                SinchPushSocketController.stopForRelayOff(
                    serviceRunning = false,
                    stopService = { stopStarts++ },
                )
            },
            clearSocketConfig = { calls.log.add("clearConfig") },
            onChanged = {},
        )

        assertEquals("no ACTION_STOP may be sent when nothing is running", 0, stopStarts)
        assertEquals(listOf("persist:false", "clearConfig", "component:disabled"), calls.log)
    }

    /**
     * Whatever the stop threw, the switch is applied: the bridge resolves, the
     * component is disabled and JS is told the value moved. A rejected
     * `setRelayEnabled` would leave the host believing the relay is still on.
     */
    @Test
    fun `SB66_aFailedStopIsNeverPropagatedToTheBridge`() {
        val calls = Calls()
        val toggler = FakeToggler(calls)
        var changes = 0

        applyRelaySwitch(
            enabled = false,
            relaySwitch = FakeSwitch(calls),
            componentToggler = toggler,
            stopSocket = { throw IllegalStateException("the stop itself failed") },
            clearSocketConfig = { calls.log.add("clearConfig") },
            onChanged = { changes++ },
        )

        assertEquals(1, changes)
        assertEquals(false, toggler.lastEnabled)
        assertEquals(listOf("persist:false", "clearConfig", "component:disabled"), calls.log)
    }

    @Test
    fun `SB66_onRestoresTheComponentAndStartsNothing`() {
        val calls = Calls()
        val relay = FakeSwitch(calls, on = false)
        val toggler = FakeToggler(calls)

        val persisted = applyRelaySwitch(
            enabled = true,
            relaySwitch = relay,
            componentToggler = toggler,
            stopSocket = { calls.log.add("stop") },
            onChanged = { calls.log.add("changed") },
        )

        assertEquals(listOf("persist:true", "component:default", "changed"), calls.log)
        assertTrue(relay.isEnabled())
        assertTrue("the choice reached storage", persisted)
    }

    // --- the switch and the component cannot drift -----------------------------

    /**
     * A switch and a component that disagree: the relay is on, but the component
     * is still disabled (a toggle the platform refused, or one that never ran).
     * The start repairs it before asking the platform for the service, because a
     * start dispatched to a disabled component never reaches `onStartCommand`.
     */
    @Test
    fun `SB66_startWhileTheRelayIsOnReEnablesTheComponentBeforeStarting`() {
        val calls = Calls()

        SinchPushSocketController.start(
            testConfig(backgroundService = true),
            relayEnabled = { true },
            enableComponent = { calls.log.add("component:default") },
            startService = { calls.log.add("startService") },
            startInProcess = { fail("service owner expected") },
        )

        assertEquals(listOf("component:default", "startService"), calls.log)
    }

    @Test
    fun `SB66_aStartRefusedWhileOffReEnablesNothing`() {
        try {
            SinchPushSocketController.start(
                testConfig(backgroundService = true),
                relayEnabled = { false },
                enableComponent = { fail("a refused start must not touch the component") },
                startService = { fail("no service") },
                startInProcess = { fail("no in-process socket") },
            )
            fail("a start while the relay is off must be refused")
        } catch (_: RelayDisabledException) {
        }
    }

    // --- RELAY_DISABLED -------------------------------------------------------

    @Test
    fun `SB66_theProviderReportsRelayDisabledForHelloAndForSubscribeWhateverTheConfigSays`() {
        val relay = FakeSwitch(Calls(), on = false)
        val provider = SystemDeviceInfoProvider(FakeDeviceEnvironment(serviceRunning = true), logger, relay)
        val config = testConfig(backgroundService = true)

        assertEquals(BackgroundServiceState.RELAY_DISABLED, provider.current(config, DeviceInfoPurpose.HELLO).backgroundService)
        assertEquals(BackgroundServiceState.RELAY_DISABLED, provider.current(config, DeviceInfoPurpose.SUBSCRIBE).backgroundService)
        assertEquals(BackgroundServiceState.RELAY_DISABLED, provider.current(null, DeviceInfoPurpose.SUBSCRIBE).backgroundService)
        assertEquals(
            "RELAY_DISABLED",
            provider.current(config, DeviceInfoPurpose.SUBSCRIBE).toJsMap()["backgroundService"],
        )
        // Not the DISABLED of `backgroundService = false` (SB-60): that is a socket.
        assertEquals(
            BackgroundServiceState.RELAY_DISABLED,
            provider.current(testConfig(backgroundService = false), DeviceInfoPurpose.HELLO).backgroundService,
        )
    }

    @Test
    fun `SB66_onReportsTheRealSb60StateAgain`() {
        val relay = FakeSwitch(Calls(), on = false)
        val env = FakeDeviceEnvironment(serviceRunning = true)
        val provider = SystemDeviceInfoProvider(env, logger, relay)

        relay.setEnabled(true)

        assertEquals(
            BackgroundServiceState.ENABLED_RUNNING,
            provider.current(testConfig(backgroundService = true), DeviceInfoPurpose.SUBSCRIBE).backgroundService,
        )
        assertEquals(
            BackgroundServiceState.DISABLED,
            provider.current(testConfig(backgroundService = false), DeviceInfoPurpose.SUBSCRIBE).backgroundService,
        )
    }

    @Test
    fun `SB66_aProviderWithNoSwitchNeverReportsRelayDisabled`() {
        val provider = SystemDeviceInfoProvider(FakeDeviceEnvironment(serviceRunning = true), logger)

        assertEquals(
            BackgroundServiceState.ENABLED_RUNNING,
            provider.current(testConfig(backgroundService = true), DeviceInfoPurpose.SUBSCRIBE).backgroundService,
        )
    }

    @Test
    fun `SB66_theDeviceInfoChangeIsNotifiedOncePerSwitchNotOncePerCheck`() {
        val calls = Calls()
        val relay = FakeSwitch(calls)
        val provider = SystemDeviceInfoProvider(FakeDeviceEnvironment(serviceRunning = true), logger, relay)
        val config = testConfig(backgroundService = true)
        val emitted = mutableListOf<BackgroundServiceState>()
        val notifier = DeviceInfoChangeNotifier(
            current = { provider.backgroundServiceState(config) },
            sink = { emitted.add(it); true },
        )
        notifier.prime()

        // `stop` runs its own check too, as the controller's does: still one event.
        applyRelaySwitch(
            enabled = false,
            relaySwitch = relay,
            componentToggler = FakeToggler(calls),
            stopSocket = { notifier.check() },
            onChanged = { notifier.check() },
        )
        notifier.check()
        assertEquals(listOf(BackgroundServiceState.RELAY_DISABLED), emitted)

        applyRelaySwitch(
            enabled = true,
            relaySwitch = relay,
            componentToggler = FakeToggler(calls),
            stopSocket = {},
            onChanged = { notifier.check() },
        )
        assertEquals(
            listOf(BackgroundServiceState.RELAY_DISABLED, BackgroundServiceState.ENABLED_RUNNING),
            emitted,
        )
    }

    // --- start refused --------------------------------------------------------

    @Test
    fun `SB66_startWhileOffThrowsAndStartsNothingAndWritesNoState`() {
        val before = SinchPushSocketStore.state()
        var serviceStarted = false
        var inProcessStarted = false

        try {
            SinchPushSocketController.start(
                testConfig(backgroundService = true),
                relayEnabled = { false },
                startService = { serviceStarted = true },
                startInProcess = { inProcessStarted = true },
            )
            fail("a start while the relay is off must be refused")
        } catch (e: RelayDisabledException) {
            assertTrue(e.message!!.contains("setRelayEnabled(true)"))
        }

        assertFalse(serviceStarted)
        assertFalse(inProcessStarted)
        assertNull(SinchPushSocketController.activeConfigForTest())
        assertEquals(before, SinchPushSocketStore.state())
    }

    @Test
    fun `SB66_startWhileOffIsRefusedForTheInProcessOwnerToo`() {
        try {
            SinchPushSocketController.start(
                testConfig(backgroundService = false),
                relayEnabled = { false },
                startService = { fail("no service") },
                startInProcess = { fail("no in-process socket") },
            )
            fail("a start while the relay is off must be refused")
        } catch (e: RelayDisabledException) {
            // expected
        }
    }

    @Test
    fun `SB66_startWhileOnProceedsAsBefore`() {
        var serviceStarted = false

        SinchPushSocketController.start(
            testConfig(backgroundService = true),
            relayEnabled = { true },
            startService = { serviceStarted = true },
            startInProcess = { fail("service owner expected") },
        )

        assertTrue(serviceStarted)
        assertEquals("connecting", SinchPushSocketStore.state().status)
    }

    // --- the service ----------------------------------------------------------

    @Test
    fun `SB66_theServiceRefusesAStartWhileOffWhateverTheConfigOrTheRestart`() {
        val config = testConfig(backgroundService = true)

        // A START_STICKY restart (null intent, persisted config) and an explicit one.
        assertEquals(SocketServiceStart.RelayOff, decideSocketServiceStart(relayEnabled = false, config = config))
        assertEquals(SocketServiceStart.RelayOff, decideSocketServiceStart(relayEnabled = false, config = null))
    }

    @Test
    fun `SB66_theServiceStartsWhenOnAndKeepsTheNoConfigExit`() {
        val config = testConfig(backgroundService = true)

        assertEquals(SocketServiceStart.Start(config), decideSocketServiceStart(true, config))
        assertEquals(SocketServiceStart.NoConfig, decideSocketServiceStart(true, null))
        assertEquals(SocketServiceStart.NoConfig, decideSocketServiceStart(true, config.copy(url = "")))
    }

    // --- the race the service's own check cannot close -------------------------

    /**
     * `onStartCommand` runs on the main thread and reads the switch there;
     * `setRelayEnabled(false)` runs on the native-modules thread and writes it
     * there. A start that passed `decideSocketServiceStart` a moment earlier
     * therefore reaches `begin` *after* the off path ran. `begin` reads the
     * switch again for that reason: no client is built, and the config is not
     * recorded as started.
     */
    @Test
    fun `SB66_beginCreatesNoClientWhenTheSwitchFlippedAfterTheServiceCheck`() {
        val harness = Harness()
        var clientsCreated = 0

        SinchPushSocketController.begin(
            config = testConfig(backgroundService = true),
            relayEnabled = { false },
            createClient = { clientsCreated++; harness.client },
        )

        assertEquals("no client may be built while the relay is off", 0, clientsCreated)
        assertFalse(SinchPushSocketController.isActive())
        assertNull(SinchPushSocketController.activeConfigForTest())
        assertTrue("nothing may be opened on the harness client", harness.transport.connections.isEmpty())
    }

    /** The re-check is a refusal, not a way to refuse every start. */
    @Test
    fun `SB66_beginOpensTheClientWhileTheRelayIsOn`() {
        val harness = Harness()
        var clientsCreated = 0
        val emitted = mutableListOf<SinchPushSocketStore.SocketState>()
        SinchPushSocketController.setStateSinkForTest { emitted.add(it) }

        SinchPushSocketController.begin(
            config = testConfig(backgroundService = true),
            relayEnabled = { true },
            createClient = { clientsCreated++; harness.client },
        )

        assertEquals(1, clientsCreated)
        assertTrue(SinchPushSocketController.isActive())
        assertEquals(testConfig(backgroundService = true), SinchPushSocketController.activeConfigForTest())
        assertEquals(1, harness.transport.connections.size)
        assertEquals(listOf("connecting"), emitted.map { it.status })
    }

    /**
     * The relay off and `begin` run on different threads - the service's
     * `onStartCommand` on the main thread, `setRelayEnabled(false)` on the
     * native-modules thread - so the switch read, the client installation and
     * the off path's stop are serialized by one lock.
     *
     * Without it the off lands between the read and the installation: the off
     * path stops a client that does not exist yet, and `begin` then installs
     * one - a socket while the relay is off (F01, OPEN-12 race (c)).
     */
    @Test
    fun `SB66_aRelayOffThatRacesBeginLeavesNoClient`() {
        val harness = Harness()
        // The React emitter is not reachable on the JVM: the states go nowhere.
        SinchPushSocketController.setStateSinkForTest { }
        var relayOn = true
        val offStarted = CountDownLatch(1)
        val offFinished = CountDownLatch(1)
        val offThread = Thread {
            relayOn = false
            offStarted.countDown()
            SinchPushSocketController.stopForRelayOff(serviceRunning = false, stopService = {})
            offFinished.countDown()
        }

        SinchPushSocketController.begin(
            config = testConfig(backgroundService = true),
            relayEnabled = {
                // The off path is already on its way when the switch is read.
                offThread.start()
                offStarted.await(1, TimeUnit.SECONDS)
                // With the lock the off path is blocked on it and the wait runs
                // out; without it the off path is through before the client is
                // installed, which is the bug this test is about.
                offFinished.await(300, TimeUnit.MILLISECONDS)
                true
            },
            createClient = { harness.client },
        )
        offThread.join()

        assertFalse("a relay-off that raced begin must not leave a client behind", SinchPushSocketController.isActive())
        assertFalse("the relay must be off", relayOn)
    }

    // --- persistence ----------------------------------------------------------

    @Test
    fun `SB66_theSwitchDefaultsToOffAndSurvivesANewInstanceOverTheSameFile`() {
        val file = FakeSharedPreferences()
        assertFalse("a missing key means never switched on", SharedPreferencesRelaySwitch(file).isEnabled())

        assertTrue("the commit succeeded", SharedPreferencesRelaySwitch(file).setEnabled(true))
        assertTrue("a relaunched process reads what was persisted", SharedPreferencesRelaySwitch(file).isEnabled())
        assertEquals(true, file.values[SharedPreferencesRelaySwitch.KEY_ENABLED])
        // commit(), not apply(): a process killed right after switching the relay
        // must come back with the same choice, and an asynchronous write is lost
        // exactly there.
        assertEquals(1, file.commits)
        assertEquals(0, file.applies)

        SharedPreferencesRelaySwitch(file).setEnabled(false)
        assertFalse(SharedPreferencesRelaySwitch(file).isEnabled())
    }

    /** The build's opt-in sits in front of the stored value: a stale `true` cannot run a relay the build lacks. */
    @Test
    fun `SB66_aBuildWithoutTheRelayReadsOffWhateverIsStored`() {
        val file = FakeSharedPreferences()
        var available = false
        val gated = BuildGatedRelaySwitch(SharedPreferencesRelaySwitch(file)) { available }

        assertTrue("storing still works", gated.setEnabled(true))
        assertFalse("but a build without the relay reads off", gated.isEnabled())

        available = true
        assertTrue(gated.isEnabled())
        gated.setEnabled(false)
        assertFalse(gated.isEnabled())
    }

    @Test
    fun `SB66_aStartInABuildWithoutTheRelayIsRefusedAndNamesTheGradleProperty`() {
        try {
            SinchPushSocketController.start(
                testConfig(backgroundService = true),
                relayAvailable = { false },
                relayEnabled = { true },
                enableComponent = { fail("a refused start must not touch the component") },
                startService = { fail("no service") },
                startInProcess = { fail("no in-process socket") },
            )
            fail("a start without the relay in the build must be refused")
        } catch (e: RelayDisabledException) {
            assertTrue(e.message, e.message!!.contains("SinchPush_relay=true"))
        }
    }

    @Test
    fun `SB66_theNoSwitchStandInStaysOnForGraphsThatCannotTurnTheRelayOff`() {
        RelayAlwaysOn.setEnabled(false)

        assertTrue(RelayAlwaysOn.isEnabled())
    }

    // --- a commit that fails --------------------------------------------------

    /**
     * The store's own answer: `commit()` reports the failure, and the value is
     * still in memory — a failed write is not a failed switch.
     */
    @Test
    fun `SB66_theStoreReportsAFailedCommitAndKeepsTheValueForThisProcess`() {
        val file = FakeSharedPreferences()
        file.commitSucceeds = false
        val relay = SharedPreferencesRelaySwitch(file)

        assertFalse("the store must report the failed commit", relay.setEnabled(false))
        assertFalse("the value still applies to this process", relay.isEnabled())
        assertEquals(1, file.commits)
        assertEquals(0, file.applies)
    }

    /**
     * The value did not reach the disk. The switch still applies to this
     * process and the off path still runs in full — the client is closed, the
     * config cleared, the component disabled, the change notified — while the
     * result reports the choice as not persisted.
     */
    @Test
    fun `SB66_aFailedCommitStillAppliesTheSwitchAndReportsItAsNotPersisted`() {
        val calls = Calls()
        val toggler = FakeToggler(calls)
        val relay = FakeSwitch(calls, commitSucceeds = false)
        val harness = Harness()
        harness.startAndConnect()
        SinchPushSocketController.installClientForTest(harness.client)

        val persisted = applyRelaySwitch(
            enabled = false,
            relaySwitch = relay,
            componentToggler = toggler,
            stopSocket = {
                calls.log.add("stop")
                // The real off-path stop: the client is closed first.
                SinchPushSocketController.stopForRelayOff(serviceRunning = true, stopService = {})
            },
            clearSocketConfig = { calls.log.add("clearConfig") },
            onChanged = { calls.log.add("changed") },
        )

        assertFalse("the client must be closed even though the commit failed", SinchPushSocketController.isActive())
        assertEquals("the component must not stay enabled", false, toggler.lastEnabled)
        assertEquals(
            listOf("persist:false", "stop", "clearConfig", "component:disabled", "changed"),
            calls.log,
        )
        assertFalse("the switch still holds for this process", relay.isEnabled())
        assertFalse("the choice did not reach storage", persisted)
    }

    /**
     * The other direction: a failed commit on the way on still enables the
     * component, and the result reports the choice as not persisted.
     */
    @Test
    fun `SB66_aFailedCommitWhileTurningTheRelayOnEnablesTheComponentAndReportsNotPersisted`() {
        val calls = Calls()
        val toggler = FakeToggler(calls)
        val relay = FakeSwitch(calls, on = false, commitSucceeds = false)

        val persisted = applyRelaySwitch(
            enabled = true,
            relaySwitch = relay,
            componentToggler = toggler,
            stopSocket = { calls.log.add("stop") },
            onChanged = { calls.log.add("changed") },
        )

        assertEquals("the component must be enabled", true, toggler.lastEnabled)
        assertEquals(listOf("persist:true", "component:default", "changed"), calls.log)
        assertTrue("the switch still holds for this process", relay.isEnabled())
        assertFalse("the choice did not reach storage", persisted)
    }

    /**
     * The bridge's answer: a switch that was applied but not persisted rejects
     * with `E_SET_RELAY_ENABLED`, a persisted one resolves.
     *
     * `SinchPushModuleImpl` cannot be built on the JVM — it wants a
     * `ReactApplicationContext` — so the promise it settles is driven here.
     */
    @Test
    fun `SB66_theBridgeRejectsWithESetRelayEnabledWhenTheChoiceWasNotPersisted`() {
        val notPersisted = RecordingPromise()
        settleRelaySwitch(persisted = false, promise = notPersisted)

        assertFalse("a switch that did not persist must not resolve", notPersisted.resolved)
        assertEquals("E_SET_RELAY_ENABLED", notPersisted.rejectedCode)
        assertEquals("relay switch applied but not persisted", notPersisted.rejectedMessage)

        val persisted = RecordingPromise()
        settleRelaySwitch(persisted = true, promise = persisted)

        assertTrue("a persisted switch resolves", persisted.resolved)
        assertNull("a persisted switch does not reject", persisted.rejectedCode)
    }

    /** The bridge's promise, recorded. */
    private class RecordingPromise : Promise {
        var resolved = false
        var rejectedCode: String? = null
        var rejectedMessage: String? = null

        override fun resolve(value: Any?) {
            resolved = true
        }

        override fun reject(code: String, message: String?) {
            rejectedCode = code
            rejectedMessage = message
        }

        override fun reject(code: String, throwable: Throwable?) = reject(code, throwable?.message)

        override fun reject(code: String, message: String?, throwable: Throwable?) = reject(code, message)

        override fun reject(throwable: Throwable) = reject(throwable.message ?: "", throwable)

        override fun reject(throwable: Throwable, userInfo: WritableMap) = reject(throwable.message ?: "", throwable)

        override fun reject(code: String, userInfo: WritableMap) = reject(code, "")

        override fun reject(code: String, throwable: Throwable?, userInfo: WritableMap) = reject(code, throwable?.message)

        override fun reject(code: String, message: String?, userInfo: WritableMap) = reject(code, message)

        override fun reject(code: String?, message: String?, throwable: Throwable?, userInfo: WritableMap?) =
            reject(code ?: "", message)

        @Suppress("OVERRIDE_DEPRECATION")
        override fun reject(message: String) {
            rejectedMessage = message
        }
    }

    /** Just enough of `SharedPreferences` for a boolean policy flag. */
    private class FakeSharedPreferences : SharedPreferences {
        val values = mutableMapOf<String, Any?>()
        /** How the SDK wrote the file: `apply()` is asynchronous and can be lost. */
        var commits = 0
        var applies = 0
        /** `false`: the write fails on disk; the in-memory map is still updated. */
        var commitSucceeds = true

        override fun getAll(): MutableMap<String, *> = values
        override fun getString(key: String?, defValue: String?) = values[key] as? String ?: defValue
        override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? = defValues
        override fun getInt(key: String?, defValue: Int) = values[key] as? Int ?: defValue
        override fun getLong(key: String?, defValue: Long) = values[key] as? Long ?: defValue
        override fun getFloat(key: String?, defValue: Float) = values[key] as? Float ?: defValue
        override fun getBoolean(key: String?, defValue: Boolean) = values[key] as? Boolean ?: defValue
        override fun contains(key: String?) = values.containsKey(key)
        override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
        override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

        override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
            private val pending = mutableMapOf<String, Any?>()
            override fun putString(key: String, value: String?) = apply { pending[key] = value }
            override fun putStringSet(key: String, values: MutableSet<String>?) = apply { pending[key] = values }
            override fun putInt(key: String, value: Int) = apply { pending[key] = value }
            override fun putLong(key: String, value: Long) = apply { pending[key] = value }
            override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
            override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
            override fun remove(key: String) = apply { pending.remove(key) }
            override fun clear() = apply { pending.clear() }
            override fun commit(): Boolean {
                commits++
                values.putAll(pending)
                return commitSucceeds
            }
            override fun apply() {
                applies++
                commit()
            }
        }
    }
}
