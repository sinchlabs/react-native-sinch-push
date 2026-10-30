//  Backoff.swift — full-jitter reconnect delay (RN-005, SB-42).
//
//      delay(n) = random(0, min(30s, 1s · 2^(n-1)))
//
//  for n ≥ 1, the attempt count. Two properties of that formula are the whole
//  reason it is spelled out in a file of its own:
//
//    * It is *full* jitter, not `backoff + random(0, 250ms)`. Throttling sheds a
//      cohort of clients at the same instant; an additive 250 ms spread leaves
//      every one of them retrying inside that same quarter second, so the retry
//      storm reproduces the overload that caused it. Spreading across the whole
//      window trades one extra attempt for a recovery that actually completes.
//    * `delay` may legitimately be `0`. The first retry after a shed is
//      immediate, which is correct: the socket was closed for load-shedding,
//      not because anything is wrong with the client.
//
//  The cap is 30 s however many attempts have failed, and both bounds are
//  constants rather than configuration (spec §2).

import Foundation

enum ReconnectBackoff {
  /// Full-jitter base.
  static let baseMs = 1000

  /// Full-jitter cap.
  static let maxMs = 30_000

  /// The window the next attempt draws from: `min(30s, 1s · 2^(n-1))`.
  ///
  /// `attempts` is 1-based. `attempts <= 0` is clamped to the base window
  /// rather than left to produce `random(0, 500ms)` or a shift by a negative
  /// amount: the reference implementations disagree about what a zero or
  /// negative count means (the TypeScript one has no guard at all, the Kotlin
  /// one `require`s `attempts >= 1`), and a caller that got it wrong should not
  /// get a *different* window out of each platform.
  static func ceilingMs(attempts: Int) -> Int {
    let n = max(1, attempts)
    // Computed by doubling, not by shifting: `base << (n-1)` overflows for n ≥ 63
    // on a 32-bit Int and is not the same operation as the spec's multiply.
    guard n <= 1 + (maxMs / baseMs) else { return maxMs }
    return min(maxMs, baseMs * (1 << (n - 1)))
  }

  /// One draw. `Int` arithmetic on a `Double` product is floored, matching
  /// `Math.floor(Math.random() * ceiling)` in the reference client.
  static func delayMs(attempts: Int, using random: RandomSource) -> Int {
    let ceiling = ceilingMs(attempts: attempts)
    let draw = random.nextUnitDouble()
    // A source that returns exactly 1.0 (out of contract for `nextUnitDouble`,
    // but cheap to survive) would otherwise put the draw one past the window.
    let bounded = min(max(0.0, draw), 0.999_999_999_999)
    return Int(bounded * Double(ceiling))
  }
}