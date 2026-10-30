package com.sinchpush.socket

/**
 * The platform refused to start the socket's foreground service from the
 * caller: `ForegroundServiceStartNotAllowedException` (API 31+, app in the
 * background) or a `SecurityException` (missing FGS permission). Carries the
 * text that is published as `lastError` (SB-60) and the bridge's
 * `E_FGS_START_REFUSED` rejection message.
 */
internal class ForegroundServiceRefusedException(cause: Throwable) :
    RuntimeException(reasonFor(cause), cause) {

    companion object {
        /** `foreground service start refused: <ExceptionClass>: <message>`. */
        fun reasonFor(t: Throwable): String =
            "foreground service start refused: ${t.javaClass.simpleName}: ${t.message}"
    }
}

/** The system's `dataSync` budget for the foreground service ran out (API 35 `onTimeout`). */
internal class ForegroundServiceTimeoutException :
    RuntimeException(SinchPushSocketService.FOREGROUND_TIMEOUT_REASON)
