package com.sinchpush.socket

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * RN-005 / RN-030 Priority 0 — the reconnect backoff distribution.
 *
 * Full jitter, `random(0, min(30s, 1s·2^(n-1)))`, and the reason it is full
 * jitter rather than the `base + random(0, 250ms)` it replaced: throttling sheds
 * a whole cohort of devices at the same instant, and an additive quarter-second
 * spread leaves them all retrying inside the same window, so the retry storm
 * reproduces the overload that caused it.
 *
 * The reference implementation is `reconnectDelayMs` in `src/pushSocket/client.ts`
 * and its test at tag `ts-socket-client-snapshot`; this is the same three cases
 * with the same numbers. A change to one without the other changes the retry
 * pressure both platforms put on the same relay.
 */
class BackoffDistributionTest {

    private companion object {
        const val BASE_MS = 1000L
        const val MAX_MS = 30_000L
        const val SAMPLES = 1000
    }

    private fun ceilingFor(attempts: Int): Long =
        minOf(MAX_MS, BASE_MS shl (attempts - 1).coerceAtMost(30))

    @Test
    fun `stays inside 0 and the exponential ceiling`() {
        // 1000 samples per attempt, as RN-005's acceptance calls for.
        for (attempts in 1..12) {
            val ceiling = ceilingFor(attempts)
            repeat(SAMPLES) {
                val delay = SinchPushSocketClient.reconnectDelayMs(attempts)
                assertTrue(
                    "attempt $attempts produced $delay, outside [0, $ceiling]",
                    delay >= 0L && delay <= ceiling,
                )
            }
        }
    }

    @Test
    fun `spreads retries across the window instead of clustering them`() {
        val attempts = 6
        val ceiling = ceilingFor(attempts)
        val delays = List(SAMPLES) { SinchPushSocketClient.reconnectDelayMs(attempts) }

        // Full jitter should occupy a healthy share of the window...
        assertTrue(
            "max sample ${delays.max()} never passed half the $ceiling ms window",
            delays.max()!! > ceiling / 2,
        )
        // ...with no pile-up in the first tenth of it. An additive jitter would
        // put every sample in the bottom quarter percent of the window.
        val inFirstTenth = delays.count { it < ceiling / 10 }
        assertTrue(
            "$inFirstTenth/${delays.size} samples landed in the first tenth of the window",
            inFirstTenth.toDouble() / delays.size < 0.25,
        )
    }

    @Test
    fun `caps at 30s however many attempts have failed`() {
        repeat(SAMPLES) {
            val delay = SinchPushSocketClient.reconnectDelayMs(50)
            assertTrue("attempt 50 produced $delay", delay in 0..MAX_MS)
        }
    }

    @Test
    fun `rejects an attempt count below one`() {
        // Attempt 0 is not a retry: a zero here would produce a negative shift
        // and an immediate reconnect on the first failure.
        val thrown = runCatching { SinchPushSocketClient.reconnectDelayMs(0) }.exceptionOrNull()
        assertTrue("attempt 0 must be refused, got $thrown", thrown is IllegalArgumentException)
    }
}