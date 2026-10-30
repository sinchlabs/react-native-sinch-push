package com.sinchpush.socket

/** What [SinchPushSocketService.onStartCommand] does with the start it was handed (SB-55). */
internal sealed interface SocketServiceStart {

    /** Run the socket with this config and return `START_STICKY`. */
    data class Start(val config: PushSocketConfig) : SocketServiceStart

    /** The relay is off in the SDK: stop rather than open a socket. */
    data object RelayOff : SocketServiceStart

    /** Nothing to start from: a null `Intent` restart with no persisted config (SB-55). */
    data object NoConfig : SocketServiceStart
}

/**
 * The service's start decision, as a pure function of the two facts it needs.
 *
 * A `Service` cannot be constructed by a JVM test, so the rule that matters —
 * the platform can start this service on its own, and that start must not open
 * a socket while the relay is off — lives here instead, where it can be
 * asserted. The service promotes to the foreground first whatever the answer (a
 * `startForegroundService` start that never reaches `startForeground` gets the
 * app killed), so this decides only whether to go on to `begin`.
 *
 * The relay check comes first: with the relay off, a config that is present and
 * a service that is running are both irrelevant.
 */
internal fun decideSocketServiceStart(
    relayEnabled: Boolean,
    config: PushSocketConfig?,
): SocketServiceStart = when {
    !relayEnabled -> SocketServiceStart.RelayOff
    config == null || config.url.isEmpty() -> SocketServiceStart.NoConfig
    else -> SocketServiceStart.Start(config)
}
