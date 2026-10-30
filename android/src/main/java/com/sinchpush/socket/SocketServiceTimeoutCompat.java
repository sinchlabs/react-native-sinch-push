package com.sinchpush.socket;

import android.app.Service;

/**
 * Bridges the API 35 {@code Service.onTimeout(int startId, int fgsType)} callback.
 *
 * Kotlin refuses a same-signature member without {@code override} once
 * {@code compileSdk} is 35 (it hides the platform method), and refuses
 * {@code override} below 35 (nothing to override). Java has no such rule, so
 * this one-line shim compiles against API 34 (a new method the platform never
 * calls) and API 35 (the real override) alike.
 */
abstract class SocketServiceTimeoutCompat extends Service {
    /** API 35+: the platform calls this for a {@code dataSync} service. */
    public void onTimeout(int startId, int fgsType) {
        onForegroundServiceTimeout();
    }

    abstract void onForegroundServiceTimeout();
}
