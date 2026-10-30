package com.sinchpush.socket

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.ServiceCompat

internal class SinchPushSocketService : SocketServiceTimeoutCompat() {

    /** Main thread only (platform callbacks): the timeout is handled once. */
    private var timedOut = false

    override fun onCreate() {
        super.onCreate()
        // SB-60: the process-wide "service is running" flag behind
        // Hello.background_service.
        SocketServiceState.onCreated()
        SinchPushSocketNotifications.ensureChannel(this)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            SinchPushSocketController.onServiceStopRequested(
                intent.getIntExtra(EXTRA_STOP_GENERATION, SinchPushSocketController.ANY_GENERATION),
            )
            PushSocketConfig.clear(this)
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            // stopSelf(startId), not stopSelf(): startPushSocket sends STOP then
            // START back to back. A plain stopSelf() would destroy the service
            // with the START still queued, so startForeground is never reached
            // and Android kills the app (ForegroundServiceDidNotStartInTime).
            stopSelf(startId)
            return START_NOT_STICKY
        }
        // A START_STICKY restart delivers a null Intent; fall back to the
        // persisted config so the socket survives process death.
        val config = intent
            ?.let { PushSocketConfig.fromIntent(it) }
            ?.takeIf { it.url.isNotEmpty() }
            ?: PushSocketConfig.load(this)
        // Any start that came through startForegroundService must reach
        // startForeground, even one we are about to abandon, or Android kills
        // the app. So promote first, then decide.
        val refusal = promoteToForeground()
        if (refusal != null) {
            // The platform refused the foreground promotion (SB-60 records it as
            // ENABLED_NOT_RUNNING). A service that is not in the foreground is
            // killed shortly after, so stop it rather than carry on half-alive -
            // and say so, or JS would sit in "connecting" for good.
            failForeground(refusal)
            stopSelf(startId)
            return START_NOT_STICKY
        }
        // The relay switch is consulted here as well as at the caller, because
        // the platform can start this service without asking (a START_STICKY
        // restart, SB-55). The component is disabled while the relay is off, so
        // that restart should never arrive - but a start that was already
        // dispatched still does, and it must not open a socket. The promotion
        // above already happened, so stopping is the correct exit.
        when (val decision = decideSocketServiceStart(RelaySwitchController.isEnabled(this), config)) {
            is SocketServiceStart.Start -> {
                SinchPushSocketController.begin(this, decision.config)
                return START_STICKY
            }
            SocketServiceStart.RelayOff, SocketServiceStart.NoConfig -> {
                if (decision == SocketServiceStart.RelayOff) {
                    Log.w(TAG, "refusing the start: the relay is turned off in the SDK")
                }
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf(startId)
                return START_NOT_STICKY
            }
        }
    }

    /**
     * @return null when the service is in the foreground; otherwise the
     *   exception the platform refused with: `ForegroundServiceStartNotAllowedException`
     *   (API 31+, started from the background) or a `SecurityException` (a
     *   missing FGS permission). The refusal is not allowed to escape
     *   `onStartCommand`; it is recorded and published instead.
     */
    private fun promoteToForeground(): RuntimeException? {
        return try {
            val notification = SinchPushSocketNotifications.foregroundNotification(
                this,
                "Listening for Sinch push messages",
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    SinchPushSocketNotifications.FOREGROUND_NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(
                    SinchPushSocketNotifications.FOREGROUND_NOTIFICATION_ID,
                    notification,
                )
            }
            null
        } catch (e: RuntimeException) {
            e
        }
    }

    private fun failForeground(t: Throwable) {
        Log.w(TAG, "the socket service could not stay in the foreground", t)
        SinchPushSocketController.onServicePromotionRefused(t)
    }

    /**
     * API 35+: the platform's `dataSync` time budget ran out (reached through
     * [SocketServiceTimeoutCompat.onTimeout], whose two-argument signature
     * cannot be declared in Kotlin across both compileSdk 34 and 35). The
     * service has a few seconds to stop itself or the system raises an
     * ANR-style crash, so it clears the running flag (SB-60), tells JS, and
     * stops. The socket does not continue in-process (SB-54, single owner).
     */
    override fun onForegroundServiceTimeout() {
        handleTimeout()
    }

    /**
     * The API 34 callback. It fires only for a `shortService`, never for this
     * `dataSync` service, so it is not expected to run; kept for forward
     * compatibility, handled the same way.
     */
    override fun onTimeout(startId: Int) {
        handleTimeout()
    }

    private fun handleTimeout() {
        if (timedOut) return
        timedOut = true
        Log.w(TAG, "foreground service timeout; stopping the socket service", ForegroundServiceTimeoutException())
        SinchPushSocketController.onServiceTimeout()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        // stopSelf(), not stopSelf(startId): the callback's startId can be older
        // than the latest start, and stopSelf(startId) is then ignored while a
        // newer start is pending - leaving a timed-out service alive for the
        // platform to crash. The timeout is final, so stop unconditionally.
        stopSelf()
    }

    override fun onDestroy() {
        SocketServiceState.onDestroyed()
        SinchPushSocketController.stopClient()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "SinchPushSocket"
        const val ACTION_START = "com.sinchpush.socket.START"
        const val ACTION_STOP = "com.sinchpush.socket.STOP"
        private const val EXTRA_STOP_GENERATION = "com.sinchpush.socket.STOP_GENERATION"
        const val FOREGROUND_TIMEOUT_REASON = "foreground service timeout"

        /** The text a `null` component name is reported as; see [start]. */
        const val NO_COMPONENT_REASON = "the platform started no socket service component"

        /**
         * @throws ForegroundServiceRefusedException when the service could not be
         *   started — refused outright, or silently (a `null` component name, see
         *   the seam below). The refusal is recorded in [SocketServiceState] (the
         *   flag stays untouched - see there) and handed to the caller, which owns
         *   telling JS.
         */
        fun start(context: Context, config: PushSocketConfig) {
            val appContext = context.applicationContext
            start(
                saveConfig = { PushSocketConfig.save(appContext, config) },
                startPlatform = {
                    val intent = Intent(appContext, SinchPushSocketService::class.java).apply {
                        action = ACTION_START
                        config.toIntentExtras(this)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        appContext.startForegroundService(intent)
                    } else {
                        appContext.startService(intent)
                    }
                },
            )
        }

        /**
         * [start] with its two collaborators as seams, so the refusal rules can be
         * asserted on the JVM.
         *
         * Both refusals are `ForegroundServiceRefusedException` because both mean
         * the same thing to the caller - the service is not running, and nothing
         * else will run it (SB-54) - and neither may be silent. A `null`
         * component name is the silent case: `startForegroundService` returns
         * the `ComponentName` it started, and `null` means the platform started
         * nothing (an OEM background-start policy that refuses by returning
         * rather than throwing). It is treated as the refusal it is.
         */
        internal fun start(saveConfig: () -> Unit, startPlatform: () -> ComponentName?) {
            saveConfig()
            val started = try {
                startPlatform()
            } catch (e: RuntimeException) {
                // ForegroundServiceStartNotAllowedException (API 31+: started
                // while the app is in the background) is an IllegalStateException;
                // a missing FGS permission is a SecurityException. Either way the
                // service is not running (SB-60) - record it and report it to the
                // caller, do not crash the host.
                Log.w(TAG, "the socket service could not be started", e)
                SocketServiceState.recordStartFailure(e)
                throw ForegroundServiceRefusedException(e)
            }
            if (started == null) {
                val refusal = IllegalStateException(NO_COMPONENT_REASON)
                Log.w(TAG, "the socket service could not be started", refusal)
                SocketServiceState.recordStartFailure(refusal)
                throw ForegroundServiceRefusedException(refusal)
            }
        }

        fun stop(context: Context, generation: Int = SinchPushSocketController.ANY_GENERATION) {
            val intent = Intent(context, SinchPushSocketService::class.java).apply {
                action = ACTION_STOP
                putExtra(EXTRA_STOP_GENERATION, generation)
            }
            context.startService(intent)
        }
    }
}