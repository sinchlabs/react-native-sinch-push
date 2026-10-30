package com.sinchpush

import java.lang.reflect.Modifier

/**
 * Compile-time-optional bridge to [FcmProvider].
 *
 * [FcmProvider] lives in the `src/fcm` source set, which `android/build.gradle`
 * excludes when `SinchPush_firebaseMessaging=none`. [SinchPushModuleImpl] lives
 * in `src/main` and compiles in every mode, so it cannot name `FcmProvider` —
 * which is why `none` mode failed to compile before this class existed.
 *
 * The bridge reaches it by name instead: the class is present exactly when the
 * FCM source set was compiled in, so a missing class *is* the `none` mode and
 * nothing needs disabling at runtime. When it is present,
 * `FcmProvider.fetchAndListen()` keeps its own reflection-free Firebase calls
 * and its own `isAvailable()` probe, so this adds no Firebase reflection — it
 * only resolves the library's own class.
 *
 * R8: `consumer-rules.pro` keeps `com.sinchpush.FcmProvider` and all its
 * members, so the lookup survives shrinking in a host's release build.
 */
internal object FcmBridge {

    private const val PROVIDER_CLASS = "com.sinchpush.FcmProvider"
    private const val FETCH_AND_LISTEN = "fetchAndListen"

    /**
     * Asks Firebase for the current device token and forwards it to
     * [SinchPushEmitter]. No-op when the library was built without FCM
     * (`SinchPush_firebaseMessaging=none`) or when the host does not ship
     * firebase-messaging at runtime.
     */
    fun fetchAndListen() {
        try {
            val providerClass = Class.forName(PROVIDER_CLASS)
            val method = providerClass.getMethod(FETCH_AND_LISTEN)
            // FcmProvider is a Kotlin `object`: without @JvmStatic the method is
            // an instance method on the singleton held in INSTANCE.
            val receiver = if (Modifier.isStatic(method.modifiers)) {
                null
            } else {
                providerClass.getField("INSTANCE").get(null)
            }
            method.invoke(receiver)
        } catch (_: ClassNotFoundException) {
            // `none` mode: FCM was never compiled in. Nothing to refresh.
        } catch (_: Throwable) {
            // Mirrors FcmProvider.fetchAndListen's own contract: Firebase can
            // throw synchronously when Play Services is missing or the app has
            // not finished initializing. A token is picked up by the
            // FirebaseMessagingService.onNewToken callback instead.
        }
    }
}