package com.sinchpush.socket

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import sinch.push.delivery.v1beta1.ws.Platform
import sinch.push.v1beta1.resources.BackgroundServiceState

/**
 * What the relay is told about this install in `Hello` (SB-59).
 *
 * Fields 9-12 of `Hello` (`installation_id`, `os_version`, `bundle_id`,
 * `background_service`) plus the two that are derived from the device rather
 * than the credential (`platform`, `sdk_version`), collected in one place so
 * the Hello builder stays a mapping with no policy in it.
 */
internal data class DeviceInfo(
    /** Empty when the store could not produce one (SB-59). */
    val installationId: String,
    val platform: Platform,
    val osVersion: String,
    val sdkVersion: String,
    val bundleId: String,
    val backgroundService: BackgroundServiceState,
)

/**
 * Maximum UTF-8 bytes for OS, SDK and bundle values in Hello and Subscribe.
 *
 * A value over the cap is rejected like any other malformed `Hello` - closed
 * with a reason, no session stored - so the SDK has to fit inside the cap
 * itself: over the limit is not a degraded session, it is no session at all.
 */
internal const val MAX_DEVICE_INFO_VALUE_BYTES = 128

/**
 * Replace unpaired surrogates with U+FFFD and return the longest scalar prefix
 * within [maxBytes].
 *
 * Whole scalars, not bytes: cutting between the halves of a surrogate pair
 * would put an unpaired surrogate on the wire, and the strict decoder here
 * (SB-17) refuses ill-formed UTF-8 outright rather than substituting U+FFFD - so
 * a cut like that is the very outcome this clamp exists to prevent.
 *
 * Bytes rather than `length`, because the contract counts bytes: `"ż"` is one
 * `Char` and two bytes, so a `Char` budget would let 128 of them through as a
 * 256-byte field - still rejected, still no session.
 *
 * @return a well-formed prefix of [s] (U+FFFD standing in for any unpaired
 *   surrogate it contained) when [s] already fits - the common case, an OS
 *   version and an SDK version are a handful of bytes - otherwise the longest
 *   such prefix within the budget.
 */
internal fun clampUtf8(s: String, maxBytes: Int = MAX_DEVICE_INFO_VALUE_BYTES): String {
    val source = replaceUnpairedSurrogates(s)
    if (source.toByteArray(Charsets.UTF_8).size <= maxBytes) return source
    val kept = StringBuilder(maxBytes)
    var used = 0
    var i = 0
    while (i < source.length) {
        val codePoint = source.codePointAt(i)
        val width = utf8Width(codePoint)
        if (used + width > maxBytes) break
        // `charCount` keeps a real surrogate pair together, and nothing left is
        // half of one: an unpaired surrogate became U+FFFD above, so each step
        // here is a whole scalar and the budget is its exact width.
        val charCount = Character.charCount(codePoint)
        kept.append(source, i, i + charCount)
        used += width
        i += charCount
    }
    return kept.toString()
}

/**
 * Every unpaired surrogate in [s] replaced by U+FFFD, and nothing else changed.
 *
 * Always, before the size is even looked at: `String.toByteArray(UTF_8)` writes
 * an unpaired surrogate as one `?` byte, so a budget measured on it says a
 * 128-byte field, but the encoder the SDK actually writes with -
 * `ReverseProtoWriter`, behind both `Message.encode()` and `ProtoAdapter.encode`
 * (and so `FrameCodec.encode` too) - writes a *lone low* surrogate as its own
 * four-byte sequence and swallows the char in front of it: `"a\uDC00"` is two
 * bytes to Kotlin and four on the wire (`F0 A8 90 80`). (A lone *high*
 * surrogate is written as the same `?` byte Kotlin counts, but replacing it
 * keeps both cases on one rule and one width.)
 *
 * Normalize to U+FFFD before measuring so the byte budget and protobuf writer
 * see the same valid scalar sequence.
 */
private fun replaceUnpairedSurrogates(s: String): String {
    if (s.none { Character.isSurrogate(it) }) return s
    val out = StringBuilder(s.length)
    var i = 0
    while (i < s.length) {
        val c = s[i]
        when {
            Character.isHighSurrogate(c) ->
                if (i + 1 < s.length && Character.isLowSurrogate(s[i + 1])) {
                    out.append(c).append(s[i + 1])
                    i += 2
                } else {
                    out.append(UNPAIRED_SURROGATE_REPLACEMENT)
                    i++
                }
            Character.isLowSurrogate(c) -> {
                out.append(UNPAIRED_SURROGATE_REPLACEMENT)
                i++
            }
            else -> {
                out.append(c)
                i++
            }
        }
    }
    return out.toString()
}

/** What an unpaired surrogate becomes: a real scalar, three UTF-8 bytes. */
private const val UNPAIRED_SURROGATE_REPLACEMENT = '\uFFFD'

/**
 * UTF-8 width of one code point, without encoding it: 1, 2, 3 or 4 bytes by the
 * value's range.
 *
 * Only ever called on a whole scalar - `clampUtf8` replaced anything unpaired
 * before measuring, so a value in the surrogate range cannot arrive here and
 * needs no width of its own.
 */
private fun utf8Width(codePoint: Int): Int = when {
    codePoint < 0x80 -> 1
    codePoint < 0x800 -> 2
    codePoint < 0x10000 -> 3
    else -> 4
}

/**
 * [DeviceInfo] as `getDeviceInfo()` hands it to JS (SB-61): plain strings, the
 * platform and the background-service state by name, so JS owns the mapping
 * onto the push API's `resources` enums.
 */
internal fun DeviceInfo.toJsMap(): Map<String, String> = mapOf(
    "installationId" to installationId,
    "platform" to "android",
    "osVersion" to osVersion,
    "sdkVersion" to sdkVersion,
    "bundleId" to bundleId,
    "backgroundService" to backgroundService.jsName(),
)

/** The wire enum's own names are the names JS knows (`UNSPECIFIED` is never produced by SB-60). */
internal fun BackgroundServiceState.jsName(): String = when (this) {
    BackgroundServiceState.UNSUPPORTED -> "UNSUPPORTED"
    BackgroundServiceState.DISABLED -> "DISABLED"
    BackgroundServiceState.ENABLED_RUNNING -> "ENABLED_RUNNING"
    BackgroundServiceState.ENABLED_NOT_RUNNING -> "ENABLED_NOT_RUNNING"
    BackgroundServiceState.RELAY_DISABLED -> "RELAY_DISABLED"
    else -> "DISABLED"
}

/** Who [DeviceInfoProvider.current] is answering, which decides three of its rules. */
internal enum class DeviceInfoPurpose {
    /** The relay `Hello` (SB-59): never fails, honours the config's `sdkVersion` override. */
    HELLO,

    /** `getDeviceInfo()` for `Subscribe` (SB-61): fails without an id, built-in `sdk_version`. */
    SUBSCRIBE,
}

/** Source of [DeviceInfo]; called once per `Hello`, never cached by the client. */
internal fun interface DeviceInfoProvider {
    fun current(config: PushSocketConfig?, purpose: DeviceInfoPurpose): DeviceInfo
}

/**
 * The four reads that need Android, behind an interface (SB-59).
 *
 * `Build.VERSION.RELEASE`, `Context.packageName`, the service's process-wide
 * state and the runtime permission are all framework calls a JVM test cannot
 * make; the state machine in [SystemDeviceInfoProvider] is the part worth
 * testing, and it only needs these answers.
 */
internal interface DeviceEnvironment {
    /** `Build.VERSION.RELEASE`. */
    fun osVersion(): String

    /** `Context.packageName`. */
    fun bundleId(): String

    /**
     * The installation id.
     *
     * @throws InstallationIdUnavailableException when the store cannot answer.
     */
    fun installationId(): String

    /** Whether [SinchPushSocketService] is running in this process (SB-60). */
    fun serviceRunning(): Boolean

    /**
     * Whether the foreground-service notification can be shown: `true` below
     * API 33, where `POST_NOTIFICATIONS` is not a runtime permission, and the
     * grant state at or above it.
     */
    fun notificationPermissionGranted(): Boolean
}

/** The production [DeviceInfoProvider]: the rules of SB-59 and SB-60, over a [DeviceEnvironment]. */
internal class SystemDeviceInfoProvider(
    private val environment: DeviceEnvironment,
    private val logger: SocketLogger,
    /**
     * The relay off switch (SB-66). Defaults to "no switch", which is the value
     * every graph that cannot turn the relay off reports.
     */
    private val relaySwitch: RelaySwitch = RelayAlwaysOn,
) : DeviceInfoProvider {

    /**
     * The same rules for both purposes, so a `Subscribe` and a `Hello` made at
     * the same moment say the same thing, with three differences for
     * [DeviceInfoPurpose.SUBSCRIBE]: there may be no socket config at all
     * (nothing was ever started: SB-60 `DISABLED`), the `sdk_version` is always
     * the built-in one (the config's `sdkVersion` override is a dev/test knob for
     * `Hello` only, so the push API never hears a made-up version), and an
     * unavailable installation id is a failure rather than an empty id, because
     * a `Subscribe` can simply go without device info. A [DeviceInfoPurpose.HELLO]
     * without a config falls back to the built-in `sdk_version` too.
     *
     * @throws InstallationIdUnavailableException for [DeviceInfoPurpose.SUBSCRIBE]
     *   when the store cannot answer.
     */
    override fun current(config: PushSocketConfig?, purpose: DeviceInfoPurpose): DeviceInfo {
        val installationId = when (purpose) {
            DeviceInfoPurpose.SUBSCRIBE -> environment.installationId()
            DeviceInfoPurpose.HELLO -> try {
                environment.installationId()
            } catch (e: InstallationIdUnavailableException) {
                // SB-59: not knowing the id must not cost the connection. The relay
                // reads an empty `installation_id` as a legacy client, and the next
                // Hello asks the store again, so a Keystore that failed once
                // recovers on the first reconnect after it works.
                logger.warn("installation id unavailable, sending Hello without it: ${e.message}")
                ""
            }
        }
        val sdkVersion = when (purpose) {
            DeviceInfoPurpose.SUBSCRIBE -> SocketSpec.DEFAULT_SDK_VERSION
            DeviceInfoPurpose.HELLO -> config?.resolvedSdkVersion ?: SocketSpec.DEFAULT_SDK_VERSION
        }
        return DeviceInfo(
            installationId = installationId,
            platform = Platform.ANDROID,
            // The three capped fields are clamped where the DeviceInfo is built,
            // so `Hello` and `getDeviceInfo()` (Subscribe) are both covered.
            // `installation_id` is a UUID validated by format and `platform` an
            // enum number, so neither can exceed the cap.
            osVersion = clampUtf8(environment.osVersion()),
            sdkVersion = clampUtf8(sdkVersion),
            bundleId = clampUtf8(environment.bundleId()),
            backgroundService = backgroundServiceState(config),
        )
    }

    /**
     * SB-60, with the relay switch in front of it (SB-66). `null` is
     * "no socket config": nothing was ever asked to run, which is the same
     * answer as `backgroundService == false`.
     *
     * The truth table, in the order the rules are evaluated:
     *
     *  - relay off -> `RELAY_DISABLED`, whatever the config says;
     *  - no config, or `backgroundService == false` -> `DISABLED`;
     *  - service running and its notification may be shown -> `ENABLED_RUNNING`;
     *  - otherwise -> `ENABLED_NOT_RUNNING`.
     *
     * The switch overrides everything: with the relay off there is no socket
     * *and* no background service, whether or not a service happens to be
     * running.
     */
    fun backgroundServiceState(config: PushSocketConfig?): BackgroundServiceState = when {
        !relaySwitch.isEnabled() -> BackgroundServiceState.RELAY_DISABLED
        config == null || !config.backgroundService -> BackgroundServiceState.DISABLED
        environment.serviceRunning() && environment.notificationPermissionGranted() ->
            BackgroundServiceState.ENABLED_RUNNING
        // Enabled but the service is not up (killed, stopped, never started,
        // FGS start refused), or up without a notification the user can see -
        // which on API 33+ the platform may stop treating as dependable.
        else -> BackgroundServiceState.ENABLED_NOT_RUNNING
    }
}

/** The real Android answers. */
internal class AndroidDeviceEnvironment(context: Context) : DeviceEnvironment {

    private val context = context.applicationContext

    override fun osVersion(): String = Build.VERSION.RELEASE.orEmpty()

    override fun bundleId(): String = context.packageName.orEmpty()

    override fun installationId(): String = InstallationIdStore.get(context).installationId()

    override fun serviceRunning(): Boolean = SocketServiceState.running

    override fun notificationPermissionGranted(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
}
