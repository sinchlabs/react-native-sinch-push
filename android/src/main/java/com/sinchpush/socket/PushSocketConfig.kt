package com.sinchpush.socket

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType

/**
 * The three-value display rule, the same one iOS has (`SocketDisplayRule`).
 *
 * JS always sends the string form (`nativeConfig` normalises a 1.0.x boolean),
 * so the native side must read a string: reading it with `getBoolean` would
 * throw on every start.
 */
enum class DisplayRule(val wire: String) {
    /** Post only when the host has no in-app handler registered. */
    WHEN_UNHANDLED("whenUnhandled"),
    ALWAYS("always"),
    NEVER("never"),
    ;

    companion object {
        fun fromWire(value: String?): DisplayRule =
            values().firstOrNull { it.wire == value } ?: WHEN_UNHANDLED
    }
}

/**
 * What the native socket runs on.
 *
 * There is deliberately no `background` field: `Hello.background` is computed
 * natively (SB-57) from the owner and the app's visibility at connect, and a
 * config flag for it is what let it default to `true` in-process.
 */
data class PushSocketConfig(
    val url: String,
    val authToken: String,
    val projectId: String,
    val appId: String,
    val userId: String,
    val sdkVersion: String,
    val pollIntervalMs: Int,
    val displayNotifications: DisplayRule,
    /**
     * Whether the socket runs in the foreground service (SB-54).
     *
     * Default true: on Android the background path is the service, because an
     * in-process socket dies with the app. The in-process mode is for hosts
     * that opt out; the same client drives both, so the only difference is
     * which owner holds it.
     */
    val backgroundService: Boolean = true,
) {

    /**
     * The `sdk_version` actually put on the wire (SB-19).
     *
     * The version comes from the JS config map, which is where a build-time
     * injected `package.json` version belongs. [SocketSpec.DEFAULT_SDK_VERSION]
     * is the fallback for a config that omits it, and `SDKVersionTest` pins
     * that constant against `package.json`.
     */
    val resolvedSdkVersion: String
        get() = sdkVersion.takeIf { it.isNotEmpty() } ?: SocketSpec.DEFAULT_SDK_VERSION

    fun toIntentExtras(intent: Intent) {
        intent.putExtra(EXTRA_URL, url)
        intent.putExtra(EXTRA_AUTH_TOKEN, authToken)
        intent.putExtra(EXTRA_PROJECT_ID, projectId)
        intent.putExtra(EXTRA_APP_ID, appId)
        intent.putExtra(EXTRA_USER_ID, userId)
        intent.putExtra(EXTRA_SDK_VERSION, sdkVersion)
        intent.putExtra(EXTRA_POLL_INTERVAL_MS, pollIntervalMs)
        intent.putExtra(EXTRA_DISPLAY_NOTIFICATIONS, displayNotifications.wire)
        intent.putExtra(EXTRA_BACKGROUND_SERVICE, backgroundService)
    }

    companion object {
        const val EXTRA_URL = "com.sinchpush.socket.URL"
        const val EXTRA_AUTH_TOKEN = "com.sinchpush.socket.AUTH_TOKEN"
        const val EXTRA_PROJECT_ID = "com.sinchpush.socket.PROJECT_ID"
        const val EXTRA_APP_ID = "com.sinchpush.socket.APP_ID"
        const val EXTRA_USER_ID = "com.sinchpush.socket.USER_ID"
        const val EXTRA_SDK_VERSION = "com.sinchpush.socket.SDK_VERSION"
        const val EXTRA_POLL_INTERVAL_MS = "com.sinchpush.socket.POLL_INTERVAL_MS"
        const val EXTRA_DISPLAY_NOTIFICATIONS = "com.sinchpush.socket.DISPLAY_NOTIFICATIONS"
        const val EXTRA_BACKGROUND_SERVICE = "com.sinchpush.socket.BACKGROUND_SERVICE"

        fun fromReadableMap(map: ReadableMap?): PushSocketConfig {
            val m = map ?: error("PushSocketConfig requires a ReadableMap")
            return PushSocketConfig(
                url = m.getStringOrThrow(KEY_URL).orEmpty(),
                authToken = m.getStringOrThrow(KEY_AUTH_TOKEN).orEmpty(),
                projectId = m.getStringOrDefault(KEY_PROJECT_ID, ""),
                appId = m.getStringOrThrow(KEY_APP_ID).orEmpty(),
                userId = m.getStringOrThrow(KEY_USER_ID).orEmpty(),
                sdkVersion = m.getStringOrDefault(KEY_SDK_VERSION, SocketSpec.DEFAULT_SDK_VERSION),
                pollIntervalMs = if (m.hasKey(KEY_POLL_INTERVAL_MS)) m.getInt(KEY_POLL_INTERVAL_MS) else 0,
                displayNotifications = readDisplayRule(m),
                backgroundService = if (m.hasKey(KEY_BACKGROUND_SERVICE)) {
                    m.getBoolean(KEY_BACKGROUND_SERVICE)
                } else {
                    true
                },
            )
        }

        const val KEY_URL = "url"
        const val KEY_AUTH_TOKEN = "authToken"
        const val KEY_PROJECT_ID = "projectId"
        const val KEY_APP_ID = "appId"
        const val KEY_USER_ID = "userId"
        const val KEY_SDK_VERSION = "sdkVersion"
        const val KEY_POLL_INTERVAL_MS = "pollIntervalMs"
        const val KEY_DISPLAY_NOTIFICATIONS = "displayNotifications"
        const val KEY_BACKGROUND_SERVICE = "backgroundService"

        // Persisted so a START_STICKY restart (process death) can resume the
        // socket without the original Intent extras.
        //
        // The auth token is still stored in plain SharedPreferences here; this
        // whole block moves into EncryptedSharedPreferences, and nothing may put
        // the token in a second store (SocketStateStore holds the seen set,
        // sent set, outbox and last-seen id, and no token).
        fun save(context: Context, config: PushSocketConfig) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(KEY_URL, config.url)
                .putString(KEY_AUTH_TOKEN, config.authToken)
                .putString(KEY_PROJECT_ID, config.projectId)
                .putString(KEY_APP_ID, config.appId)
                .putString(KEY_USER_ID, config.userId)
                .putString(KEY_SDK_VERSION, config.sdkVersion)
                .putInt(KEY_POLL_INTERVAL_MS, config.pollIntervalMs)
                .putString(KEY_DISPLAY_NOTIFICATIONS, config.displayNotifications.wire)
                .putBoolean(KEY_BACKGROUND_SERVICE, config.backgroundService)
                .apply()
        }

        fun load(context: Context): PushSocketConfig? {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val url = p.getString(KEY_URL, null) ?: return null
            return PushSocketConfig(
                url = url,
                authToken = p.getString(KEY_AUTH_TOKEN, "").orEmpty(),
                projectId = p.getString(KEY_PROJECT_ID, "").orEmpty(),
                appId = p.getString(KEY_APP_ID, "").orEmpty(),
                userId = p.getString(KEY_USER_ID, "").orEmpty(),
                sdkVersion = p.getString(KEY_SDK_VERSION, SocketSpec.DEFAULT_SDK_VERSION).orEmpty(),
                pollIntervalMs = p.getInt(KEY_POLL_INTERVAL_MS, 0),
                displayNotifications = loadDisplayRule(p),
                backgroundService = p.getBoolean(KEY_BACKGROUND_SERVICE, true),
            )
        }

        fun clear(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply()
        }

        private const val PREFS = "sinch_push_socket"

        fun fromIntent(intent: Intent): PushSocketConfig = PushSocketConfig(
            url = intent.getStringExtra(EXTRA_URL).orEmpty(),
            authToken = intent.getStringExtra(EXTRA_AUTH_TOKEN).orEmpty(),
            projectId = intent.getStringExtra(EXTRA_PROJECT_ID).orEmpty(),
            appId = intent.getStringExtra(EXTRA_APP_ID).orEmpty(),
            userId = intent.getStringExtra(EXTRA_USER_ID).orEmpty(),
            sdkVersion = intent.getStringExtra(EXTRA_SDK_VERSION) ?: SocketSpec.DEFAULT_SDK_VERSION,
            pollIntervalMs = intent.getIntExtra(EXTRA_POLL_INTERVAL_MS, 0),
            displayNotifications = DisplayRule.fromWire(intent.getStringExtra(EXTRA_DISPLAY_NOTIFICATIONS)),
            backgroundService = intent.getBooleanExtra(EXTRA_BACKGROUND_SERVICE, true),
        )

        /** String (current) or boolean (a 1.0.x config that skipped JS normalisation). */
        private fun readDisplayRule(m: ReadableMap): DisplayRule {
            if (!m.hasKey(KEY_DISPLAY_NOTIFICATIONS)) return DisplayRule.WHEN_UNHANDLED
            return when (m.getType(KEY_DISPLAY_NOTIFICATIONS)) {
                ReadableType.Boolean ->
                    if (m.getBoolean(KEY_DISPLAY_NOTIFICATIONS)) DisplayRule.ALWAYS else DisplayRule.NEVER
                ReadableType.String -> DisplayRule.fromWire(m.getString(KEY_DISPLAY_NOTIFICATIONS))
                else -> DisplayRule.WHEN_UNHANDLED
            }
        }

        /** Older builds stored a boolean under the same key; read both without a ClassCastException. */
        private fun loadDisplayRule(p: SharedPreferences): DisplayRule =
            when (val stored = p.all[KEY_DISPLAY_NOTIFICATIONS]) {
                is Boolean -> if (stored) DisplayRule.ALWAYS else DisplayRule.NEVER
                is String -> DisplayRule.fromWire(stored)
                else -> DisplayRule.WHEN_UNHANDLED
            }

        private fun ReadableMap.getStringOrThrow(key: String): String? {
            require(hasKey(key)) { "PushSocketConfig is missing required field '$key'" }
            return getString(key)
        }

        private fun ReadableMap.getStringOrDefault(key: String, default: String): String =
            if (hasKey(key)) getString(key) ?: default else default
    }
}