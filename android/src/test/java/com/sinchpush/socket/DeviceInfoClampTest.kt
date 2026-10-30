package com.sinchpush.socket

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import sinch.push.v1beta1.resources.BackgroundServiceState

/**
 * The 128-byte cap on `os_version`, `bundle_id` and `sdk_version`.
 *
 * The relay **rejects** a `Hello` whose value exceeds the cap, closing the socket
 * with a reason and storing no session - it does not truncate - and sinch-push
 * caps `Subscribe` the same way, so the value has to fit before it is sent.
 *
 * Both places that carry these three fields build their message from the same
 * `DeviceInfo` (`SinchPushSocketClient`'s `Hello` and `getDeviceInfo()` for
 * `Subscribe`), so clamping where `DeviceInfo` is built covers both, and these
 * tests are written against the provider rather than against each consumer -
 * with one end-to-end pass through the client, because "the bytes that would
 * reach the relay are within the cap" is the claim that actually matters.
 */
class DeviceInfoClampTest {

    private val logger = RecordingLogger()

    private fun utf8Size(s: String) = s.toByteArray(Charsets.UTF_8).size

    /** How many surrogates in [s] are *not* half of a pair. Zero is well-formed UTF-16. */
    private fun unpairedSurrogates(s: String): Int {
        var count = 0
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (Character.isHighSurrogate(c) && i + 1 < s.length && Character.isLowSurrogate(s[i + 1])) {
                i += 2
                continue
            }
            if (Character.isSurrogate(c)) count++
            i++
        }
        return count
    }

    /**
     * The bytes field [tag] really occupies in the frame the client wrote.
     *
     * The raw frame rather than the decoded message, because the claim under
     * test is about the wire: the encoder the SDK writes with (`FrameCodec.encode`
     * → `ReverseProtoWriter`) is not `toByteArray`, and the two disagree on an
     * unpaired surrogate - a lone low one is paired with the char before it and
     * written as four bytes where Kotlin counted one.
     */
    private fun rawFieldBytes(h: Harness, tag: Int): ByteArray {
        val frame = FrameCodec.readFrame(h.conn.sentBytes.single(), FrameDirection.CLIENT)
        return (protoFields(frame.payload).getValue(tag) as ProtoField.Bytes).value
    }

    /** A well-formed reading of the bytes, and the absence of a U+FFFD the encoder had to substitute. */
    private fun decodesCleanly(s: String): Boolean =
        String(s.toByteArray(Charsets.UTF_8), Charsets.UTF_8) == s && !s.contains('�')

    // --- the helper -------------------------------------------------------------

    @Test
    fun `SB59_aValueInsideTheCapIsReturnedUnchanged`() {
        val bundleId = "com.sinch.example"
        assertEquals(17, utf8Size(bundleId))
        assertEquals(bundleId, clampUtf8(bundleId))
        assertEquals(utf8Size(bundleId), utf8Size(clampUtf8(bundleId)))
    }

    @Test
    fun `SB59_aLongAsciiValueIsCutToExactlyTheCap`() {
        // 200 ASCII bytes: one byte per char, so the cut lands on 128 exactly.
        val long = "a".repeat(200)
        assertEquals(200, utf8Size(long))
        val clamped = clampUtf8(long)
        assertEquals(128, utf8Size(clamped))
        assertEquals("a".repeat(128), clamped)
    }

    @Test
    fun `SB59_aMultiByteValueIsCutToTheCapWithoutBreakingACodePoint`() {
        // "ż" is two UTF-8 bytes, so the budget is bytes, not characters.
        val long = "ż".repeat(100)
        assertEquals(200, utf8Size(long))
        val clamped = clampUtf8(long)
        assertTrue(utf8Size(clamped) <= MAX_DEVICE_INFO_VALUE_BYTES)
        // 64 of the 100 fit; the 65th would need byte 129.
        assertEquals(128, utf8Size(clamped))
        assertEquals("ż".repeat(64), clamped)
        assertTrue(decodesCleanly(clamped))
    }

    @Test
    fun `SB59_aThreeByteValueIsCutAtTheLastWholeCodePoint`() {
        // 128 is not a multiple of 3, so the result is the longest prefix that
        // fits (126 bytes), never a partial euro sign.
        val long = "€".repeat(50) // 150 bytes
        assertEquals(150, utf8Size(long))
        val clamped = clampUtf8(long)
        assertTrue(utf8Size(clamped) <= 128)
        assertEquals(126, utf8Size(clamped))
        assertEquals("€".repeat(42), clamped)
        assertTrue(long.startsWith(clamped))
        assertTrue(decodesCleanly(clamped))
    }

    @Test
    fun `SB59_fourByteEmojiAreKeptWhole`() {
        // An emoji outside the BMP is one code point of four UTF-8 bytes, written
        // as a surrogate pair. A byte-by-byte cut on an odd offset would put half
        // a pair on the wire - ill-formed UTF-8, which the strict decoder here
        // (SB-17) refuses rather than substitutes.
        val long = "😀".repeat(40) // 160 bytes, 80 chars
        assertEquals(160, utf8Size(long))
        assertEquals(80, long.length)
        val clamped = clampUtf8(long)
        assertTrue(utf8Size(clamped) <= 128)
        // 128 is a multiple of 4, so this one lands exactly on the cap.
        assertEquals(128, utf8Size(clamped))
        assertEquals("😀".repeat(32), clamped)
        assertTrue(long.startsWith(clamped))
        assertTrue(decodesCleanly(clamped))
    }

    @Test
    fun `SB59_anEmojiNextToAnAsciiLetterIsCutWhereTheBytesRunOut`() {
        // 31 emojis (124 bytes) and one ASCII letter fit at 125; the 32nd emoji
        // would need byte 129.
        val long = "😀".repeat(31) + "a" + "😀".repeat(20)
        val clamped = clampUtf8(long)
        assertEquals(125, utf8Size(clamped))
        assertEquals("😀".repeat(31) + "a", clamped)
        assertTrue(long.startsWith(clamped))
        assertTrue(decodesCleanly(clamped))
    }

    @Test
    fun `SB59_aCodePointWiderThanTheCapYieldsNothingRatherThanHalf`() {
        // Nothing of a 4-byte emoji fits in a 2-byte budget, and half of one is
        // not a value: empty is the only thing the cap admits.
        assertEquals("", clampUtf8("😀", maxBytes = 2))
        assertEquals("a", clampUtf8("a😀", maxBytes = 2))
        assertEquals("a", clampUtf8("a😀", maxBytes = 1))
    }

    @Test
    fun `SB59_theCapIsTheContracts128Bytes`() {
        assertEquals(128, MAX_DEVICE_INFO_VALUE_BYTES)
        val exactly = "b".repeat(MAX_DEVICE_INFO_VALUE_BYTES)
        assertEquals(exactly, clampUtf8(exactly))
        assertEquals(128, utf8Size(clampUtf8("b".repeat(MAX_DEVICE_INFO_VALUE_BYTES + 1))))
    }

    @Test
    fun `SB59_theHelperLeavesTheEmptyStringAlone`() {
        assertEquals("", clampUtf8(""))
    }

    @Test
    fun `SB59_aLoneLowSurrogateCannotSpendTheBudgetItDoesNotSpendOnTheWire`() {
        // The case this whole helper is repaired for. Kotlin writes an unpaired
        // surrogate as one `?` byte, so `"a\uDC00".repeat(64)` measures 128 and
        // sits exactly on the cap. The encoder the SDK writes with
        // (`ReverseProtoWriter`, behind `FrameCodec.encode`) writes a lone LOW
        // surrogate as a four-byte sequence and swallows the `a` with it, so
        // those two chars go out as `F0 A8 90 80` - four bytes, not the two
        // measured - and the value leaves as 256 bytes. The relay rejects that
        // Hello outright.
        val long = "a\uDC00".repeat(100)
        assertEquals(200, utf8Size(long)) // what Kotlin counts, and it is wrong
        val clamped = clampUtf8(long)
        // What leaves the clamp is well-formed and inside the cap by the measure
        // the writer agrees with.
        assertEquals(0, unpairedSurrogates(clamped))
        assertTrue(utf8Size(clamped) <= MAX_DEVICE_INFO_VALUE_BYTES)
        // U+FFFD is three bytes, so 'a' plus a replacement is four and 32 of them
        // fill the cap exactly.
        assertEquals("a\uFFFD".repeat(32), clamped)
        assertEquals(128, utf8Size(clamped))
        assertEquals(clamped, String(clamped.toByteArray(Charsets.UTF_8), Charsets.UTF_8))
    }

    @Test
    fun `SB59_aLoneHighSurrogateIsReplacedRatherThanCountedAsOneByte`() {
        // The mirror case: the wire writes a lone *high* surrogate as the same
        // one byte Kotlin counts, so the cap is not at risk here - but a budget
        // resting on that byte rests on a character that is not UTF-8 of any
        // scalar, and the width it is measured at (one) is not the width of what
        // it stands for (three).
        val long = "x\uD800".repeat(100)
        assertEquals(200, utf8Size(long))
        val clamped = clampUtf8(long)
        assertEquals(0, unpairedSurrogates(clamped))
        assertTrue(utf8Size(clamped) <= MAX_DEVICE_INFO_VALUE_BYTES)
        assertEquals("x\uFFFD".repeat(32), clamped)
        assertEquals(128, utf8Size(clamped))
    }

    @Test
    fun `SB59_anUnpairedSurrogateIsReplacedEvenWhenTheValueIsUnderTheCap`() {
        // Being under the cap is not a reason to leave it alone: the size check
        // is exactly what the broken surrogate makes wrong.
        assertEquals("v\uFFFD", clampUtf8("v\uDC00"))
        assertEquals(4, utf8Size(clampUtf8("v\uDC00")))
        assertEquals("a\uD83D\uDE00b", clampUtf8("a\uD83D\uDE00b"))
        assertEquals(6, utf8Size(clampUtf8("a\uD83D\uDE00b"))) // 'a' + 😀 + 'b'
        // A high surrogate at the very end has no next char to pair with.
        assertEquals("v\uFFFD", clampUtf8("v\uD800"))
    }

    // --- applied where DeviceInfo is built --------------------------------------

    @Test
    fun `SB59_theSystemProviderClampsTheThreeCappedFieldsForHelloAndForSubscribe`() {
        // The production provider, over a fake environment, so a device with a
        // 200-byte bundle id does not have to exist to prove the rule. Both
        // purposes: `Hello` and the `Subscribe` behind `getDeviceInfo()` are
        // built by the same call (SB-61).
        val long = "z".repeat(200)
        val env = FakeDeviceEnvironment(
            osVersion = long,
            bundleId = long,
            installationId = "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11",
        )
        val provider = SystemDeviceInfoProvider(env, logger)
        val config = testConfig(sdkVersion = "q".repeat(300), backgroundService = false)

        for (purpose in DeviceInfoPurpose.values().toList()) {
            val info = provider.current(config, purpose)
            assertEquals("osVersion for $purpose", 128, utf8Size(info.osVersion))
            assertEquals("bundleId for $purpose", 128, utf8Size(info.bundleId))
            assertTrue("sdkVersion for $purpose", utf8Size(info.sdkVersion) <= 128)
            // The fields the contract does *not* cap are untouched:
            // `installation_id` is a UUID validated by format, `platform` an enum
            // number and `background_service` a state, not a string.
            assertEquals("0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11", info.installationId)
            assertEquals(sinch.push.delivery.v1beta1.ws.Platform.ANDROID, info.platform)
            assertEquals(BackgroundServiceState.DISABLED, info.backgroundService)
        }
        // `Hello` carries the JS-supplied `sdkVersion` (there clamped); the
        // `Subscribe` reports the built-in one whatever the config says (SB-61).
        assertEquals("q".repeat(128), provider.current(config, DeviceInfoPurpose.HELLO).sdkVersion)
        assertEquals(
            SocketSpec.DEFAULT_SDK_VERSION,
            provider.current(config, DeviceInfoPurpose.SUBSCRIBE).sdkVersion,
        )
    }

    @Test
    fun `SB59_theSubscribeFacingDeviceInfoCarriesTheClampedValues`() {
        // The map `getDeviceInfo()` hands JS (SB-61), so `Subscribe` cannot
        // carry what `Hello` refused to. `Subscribe` reports the built-in sdk
        // version (SB-61), which is why the long value here is the bundle id.
        val env = FakeDeviceEnvironment(
            osVersion = "o".repeat(200),
            bundleId = "€".repeat(50), // 150 bytes
            serviceRunning = true,
        )
        val info = SystemDeviceInfoProvider(env, logger)
            .current(testConfig(backgroundService = true), DeviceInfoPurpose.SUBSCRIBE)
            .toJsMap()

        assertEquals(128, utf8Size(info.getValue("osVersion")))
        assertEquals(126, utf8Size(info.getValue("bundleId")))
        assertEquals("€".repeat(42), info.getValue("bundleId"))
        assertEquals(SocketSpec.DEFAULT_SDK_VERSION, info.getValue("sdkVersion"))
        assertEquals("0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11", info.getValue("installationId"))
        assertTrue(decodesCleanly(info.getValue("bundleId")))
    }

    @Test
    fun `SB59_theDefaultProviderClampsTheSdkVersionItTakesFromTheConfig`() {
        // The provider a client built without one gets: no device info, but the
        // `sdkVersion` override is JS-supplied and can be arbitrarily long, so
        // the cap has to hold there too (an over-long Hello is no Hello).
        val deps = SocketDependencies(
            clock = FakeClock(),
            scheduler = FakeScheduler(FakeClock()),
            random = { 0.5 },
            transport = FakeTransport(),
            store = InMemorySocketStateStore(),
            logger = logger,
            notifications = FakeNotifications(),
        )
        val info = deps.deviceInfo.current(
            testConfig(sdkVersion = "k".repeat(300)),
            DeviceInfoPurpose.HELLO,
        )
        assertEquals(128, utf8Size(info.sdkVersion))
        assertEquals("k".repeat(128), info.sdkVersion)
        // The rest of the default provider is unchanged.
        assertEquals("", info.osVersion)
        assertEquals("", info.bundleId)
        assertEquals("", info.installationId)
    }

    @Test
    fun `SB59_normalDeviceValuesReachDeviceInfoUntouched`() {
        // The clamp must be invisible on a real device: an Android-shaped
        // install keeps the exact strings the platform reported, or the values
        // sinch-push reads back would differ from the ones the device has.
        val info = SystemDeviceInfoProvider(
            FakeDeviceEnvironment(osVersion = "14", bundleId = "com.example.host"),
            logger,
        ).current(testConfig(sdkVersion = ""), DeviceInfoPurpose.HELLO)

        assertEquals("14", info.osVersion)
        assertEquals("com.example.host", info.bundleId)
        assertEquals(SocketSpec.DEFAULT_SDK_VERSION, info.sdkVersion)
    }

    // --- end to end: the Hello frame --------------------------------------------

    @Test
    fun `SB59_theHelloFrameCarriesAtMostTheCapForEveryCappedField`() {
        // End to end through `SinchPushSocketClient`: the Hello the relay would
        // see, not just the DeviceInfo behind it. The `sdkVersion` override is
        // the one input JS can make long, so it rides along here too.
        val h = Harness(
            testConfig(sdkVersion = "s".repeat(300)),
            environment = FakeDeviceEnvironment(
                osVersion = "o".repeat(200),
                bundleId = "ż".repeat(100),
            ),
        )
        h.start()
        h.conn.serverOpens()

        val hello = h.conn.hellos.single()
        assertEquals("ż".repeat(64), hello.bundle_id)
        assertTrue(utf8Size(hello.bundle_id) <= 128)
        assertEquals(128, utf8Size(hello.os_version))
        assertTrue(utf8Size(hello.sdk_version) <= 128)
        assertEquals("s".repeat(128), hello.sdk_version)
        // The bytes that actually left, read back out of the raw frame: the cap
        // is about the wire, and the writer is not `toByteArray`. Each capped
        // field's encoded length is inside the cap and is the clamped string's
        // UTF-8, byte for byte - so nothing widened it on the way out.
        for (tag in listOf(8 to hello.sdk_version, 10 to hello.os_version, 11 to hello.bundle_id)) {
            val bytes = rawFieldBytes(h, tag.first)
            assertTrue("field ${tag.first} is ${bytes.size} wire bytes", bytes.size <= MAX_DEVICE_INFO_VALUE_BYTES)
            assertArrayEquals(tag.second.toByteArray(Charsets.UTF_8), bytes)
        }
        assertEquals(128, rawFieldBytes(h, 11).size)
        assertEquals(1, h.conn.sent.size)
    }

    @Test
    fun `SB59_theHelloFrameWritesNoMoreThanTheCapForASurrogateBearingSdkVersion`() {
        // The regression this repair is for, end to end: an `sdk_version` that
        // measures 128 bytes to Kotlin but would be written as twice that. The
        // assertion is on field 8's own length prefix in the raw frame, which is
        // what the relay counts - not on the decoded string, which is what a
        // clamp could pass while still sending an over-long field.
        val h = Harness(testConfig(sdkVersion = "a\uDC00".repeat(100)))
        h.start()
        h.conn.serverOpens()

        val hello = h.conn.hellos.single()
        assertEquals(0, unpairedSurrogates(hello.sdk_version))
        assertTrue(utf8Size(hello.sdk_version) <= MAX_DEVICE_INFO_VALUE_BYTES)

        val field8 = rawFieldBytes(h, 8)
        assertTrue(
            "sdk_version went out as ${field8.size} bytes",
            field8.size <= MAX_DEVICE_INFO_VALUE_BYTES,
        )
        assertEquals(128, field8.size)
        // The wire bytes are the clamp's bytes: `61 EF BF BD` × 32, and never a
        // four-byte sequence standing in for a surrogate that was never a scalar.
        assertArrayEquals(hello.sdk_version.toByteArray(Charsets.UTF_8), field8)
    }

    @Test
    fun `SB59_aHelloWithACappedValueStillCarriesTheUncappedFieldsWhole`() {
        // The clamp is three fields and not a fourth: `installation_id` is a
        // 36-char UUID the relay validates by format, and a truncated one would
        // be rejected as malformed instead of as too long.
        val id = "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11"
        val h = Harness(
            environment = FakeDeviceEnvironment(osVersion = "14", bundleId = "b".repeat(200), installationId = id),
        )
        h.start()
        h.conn.serverOpens()

        val hello = h.conn.hellos.single()
        assertEquals(id, hello.installation_id)
        assertEquals(36, hello.installation_id.length)
        assertEquals(128, utf8Size(hello.bundle_id))
        assertEquals("14", hello.os_version)
    }
}