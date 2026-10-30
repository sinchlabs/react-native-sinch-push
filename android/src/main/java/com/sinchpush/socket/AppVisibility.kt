package com.sinchpush.socket

import android.app.ActivityManager

/**
 * Whether the app has UI the user can see right now (SB-57).
 *
 * Read at connect time, on the service path only: it is the value of
 * `Hello.background = !visible`. The relay uses it to decide whether the
 * foreground service or the JS surface should hold the session, and there is no
 * reconnect on transitions.
 */
internal fun interface AppVisibility {
    fun isVisible(): Boolean
}

/**
 * The process's own importance, from `ActivityManager.getMyMemoryState`.
 *
 * Needs no permission and no extra dependency. `IMPORTANCE_FOREGROUND` is a
 * process with a resumed activity; `IMPORTANCE_VISIBLE` is one with a visible
 * but not resumed activity (a dialog over it). `IMPORTANCE_FOREGROUND_SERVICE`
 * (125) sits between the two and is what the socket's own service reports with
 * no UI, so a plain `importance <= VISIBLE` would call a background-only process
 * visible. This may be replaced with a `ProcessLifecycleOwner` observer behind
 * the same interface.
 */
internal class ActivityManagerAppVisibility : AppVisibility {

    override fun isVisible(): Boolean {
        val info = ActivityManager.RunningAppProcessInfo()
        return try {
            ActivityManager.getMyMemoryState(info)
            info.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND ||
                info.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
        } catch (t: Throwable) {
            // Unknown visibility is reported as not visible: the conservative
            // answer for the relay, which then routes to this background surface.
            false
        }
    }
}
