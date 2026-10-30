//  BackoffTests.swift — the reconnect delay and the reset that arms it
//  (SB-42 … SB-46).
//
//  Two halves, and they are only separable because both the clock and the random
//  draw are injected:
//
//  * The *distribution* (SB-42) is a property of the formula, so it is measured
//    over 1000 real samples per attempt — the sample count RN-005 asks for — and
//    the jitter is not pinned, because a pinned draw has no distribution.
//  * The *reset* (SB-44 … SB-46) is a property of a sequence of sessions, so
//    the draw is pinned to 0.5 and every scheduled delay is then exact. That is
//    what makes "attempt 9's ceiling is the 30 s cap" an assertion rather than a
//    hope.
//
//  The reset exists because the relay completes `HelloAck` *before* it spends
//  the identity's `ws_hello` budget (`internal/ws/client_loop.go:96`). So
//  "I completed a handshake" stopped implying "I was admitted", and a client
//  that trusts the handshake alone pins every shed client at attempt 1 forever —
//  a ~1 s redial that never decays, on exactly the path shedding exists to drain.

import XCTest

@testable import SinchPushSocket

final class BackoffTests: XCTestCase {

  /// The jitter draw the cap and schedule assertions use.
  ///
  /// 0.9999 makes a scheduled delay 0.9999 of its ceiling, so a cap shows up as
  /// "has not fired yet at 29.9 s" — the same pin the reference suite uses.
  private static let nearTop = 0.9999

  // MARK: - SB-42 the formula

  func test_SB42_everySampleStaysInsideTheWindow() {
    // 1000 samples per attempt, as RN-005's acceptance calls for.
    for attempts in 1...12 {
      let ceiling = min(30_000, 1000 * (1 << (attempts - 1)))
      for _ in 0..<1000 {
        let delay = ReconnectBackoff.delayMs(attempts: attempts, using: SystemRandomSource())
        XCTAssertGreaterThanOrEqual(delay, 0, "attempt \(attempts)")
        XCTAssertLessThanOrEqual(delay, ceiling, "attempt \(attempts)")
      }
    }
  }

  func test_SB42_theDistributionSpreadsInsteadOfClustering() {
    // The reason this is full jitter and not `backoff + random(0, 250)`: an
    // additive spread leaves every shed client retrying inside the same quarter
    // second, so the retry storm reproduces the overload that caused it.
    let ceiling = min(30_000, 1000 * (1 << 5))  // attempt 6
    var delays: [Int] = []
    for _ in 0..<1000 {
      delays.append(ReconnectBackoff.delayMs(attempts: 6, using: SystemRandomSource()))
    }

    let highest = delays.max() ?? 0
    XCTAssertGreaterThan(
      highest, ceiling / 2,
      "full jitter should occupy a healthy share of the window")
    let inFirstTenth = delays.filter { $0 < ceiling / 10 }.count
    XCTAssertLessThan(
      inFirstTenth, delays.count / 4,
      "too many samples piled into the first tenth of the window")
  }

  func test_SB42_theCapIsThirtySecondsHoweverManyAttemptsFailed() {
    for attempts in [1, 6, 12, 50, 1_000] {
      for _ in 0..<100 {
        let delay = ReconnectBackoff.delayMs(attempts: attempts, using: SystemRandomSource())
        XCTAssertLessThanOrEqual(delay, 30_000)
      }
    }
    // The ceiling itself saturates rather than overflowing on a long count.
    XCTAssertEqual(ReconnectBackoff.ceilingMs(attempts: 5), 16_000)
    XCTAssertEqual(ReconnectBackoff.ceilingMs(attempts: 6), 30_000)
    XCTAssertEqual(ReconnectBackoff.ceilingMs(attempts: 1_000), 30_000)
  }

  func test_SB42_aNonPositiveAttemptCountClampsToTheBaseWindow() {
    // The reference implementations disagree about what zero means (TypeScript
    // has no guard and would compute 500 ms, Kotlin `require`s `>= 1`). Neither
    // is right for a caller that got it wrong; the base window is.
    XCTAssertEqual(ReconnectBackoff.ceilingMs(attempts: 0), 1000)
    XCTAssertEqual(ReconnectBackoff.ceilingMs(attempts: -5), 1000)
  }

  // MARK: - SB-44 the reset is armed, not spent

  func test_SB44_helloAckZeroesTheBudgetAndArmsTheReset() {
    let harness = makeHarness(random: BackoffTests.nearTop)

    // Exhaust the budget the only way it accumulates: budget denials.
    for _ in 0..<3 {
      harness.handshake()
      harness.serverClose(reason: .poolFull, detail: "rate_limited")
      harness.scheduler.advance(by: 60_000)
    }
    XCTAssertEqual(harness.client.backoffState.attempts, 3)

    harness.handshake()

    XCTAssertEqual(harness.client.backoffState.attempts, 0)
    XCTAssertEqual(harness.recorder.current?.reconnectAttempts, 0)
    // Armed but unspent: the zeroing is a claim this session has not yet backed
    // up, which is what SB-45 can take away again.
    XCTAssertTrue(harness.client.backoffState.resetArmed)
  }

  func test_SB44_aHealthySessionStillStartsFromAttemptOne() {
    // Without this control the escalation test could pass for the wrong reason: a
    // client that never reset its budget on *any* handshake would also climb
    // 1, 2, 3 on a path that should stay at 1. A blip on a session that
    // genuinely established must stay cheap.
    let harness = makeHarness()
    var attemptsPerDrop: [Int] = []

    for _ in 0..<4 {
      harness.handshake()
      harness.serverClose(reason: .shutdown)
      attemptsPerDrop.append(harness.client.backoffState.attempts)
      harness.scheduler.advance(by: 60_000)
    }

    XCTAssertEqual(attemptsPerDrop, [1, 1, 1, 1])
  }

  // MARK: - SB-45 the forfeit

  func test_SB45_aBudgetDenialEscalatesInsteadOfRestartingAtAttemptOne() {
    let harness = makeHarness()
    var attemptsPerDenial: [Int] = []

    for _ in 0..<6 {
      harness.handshake()
      harness.serverClose(reason: .poolFull, detail: "rate_limited")
      attemptsPerDenial.append(harness.client.backoffState.attempts)
      harness.scheduler.advance(by: 60_000)
    }

    XCTAssertEqual(attemptsPerDenial, [1, 2, 3, 4, 5, 6])
  }

  func test_SB45_sustainedRefusalReachesTheThirtySecondCap() {
    let harness = makeHarness(random: BackoffTests.nearTop)

    for _ in 0..<8 {
      harness.handshake()
      harness.serverClose(reason: .poolFull, detail: "rate_limited")
      harness.scheduler.advance(by: 60_000)
    }
    XCTAssertEqual(harness.client.backoffState.attempts, 8)

    let before = harness.socketCount
    harness.handshake()
    harness.serverClose(reason: .poolFull, detail: "rate_limited")
    XCTAssertEqual(harness.client.backoffState.attempts, 9)

    // Attempt 9's ceiling is min(30s, 1s·2^8) = the 30 s cap, and the pinned
    // draw puts the delay at 29997 ms — so the cap is visible as a timer that
    // has not fired yet.
    harness.scheduler.advance(by: 29_900)
    XCTAssertEqual(harness.socketCount, before, "reconnected before the cap expired")
    harness.scheduler.advance(by: 200)
    XCTAssertEqual(harness.socketCount, before + 1)
  }

  func test_SB45_theForfeitIsKeyedOnTheReasonNotTheDetail() {
    // The reason is the exact discriminator today (all three `POOL_FULL`
    // emissions in the relay carry `rate_limited` and nothing else does) and it
    // survives a detail rename. Keying on the detail would quietly stop
    // forfeiting the moment the relay rewords it.
    let renamed = makeHarness()
    var attempts: [Int] = []
    for _ in 0..<3 {
      renamed.handshake()
      renamed.serverClose(reason: .poolFull, detail: "shed_by_a_newer_relay")
      attempts.append(renamed.client.backoffState.attempts)
      renamed.scheduler.advance(by: 60_000)
    }
    XCTAssertEqual(attempts, [1, 2, 3], "the forfeit must not depend on the detail text")

    // And a detail that *says* rate_limited on a non-shed reason must not
    // forfeit: it is ordinary pressure.
    let notShed = makeHarness()
    notShed.handshake()
    notShed.serverClose(reason: .shutdown, detail: "rate_limited")
    XCTAssertEqual(notShed.client.backoffState.attempts, 1)
  }

  // MARK: - SB-46 what spends the reset

  func test_SB46_aPooledMessageSpendsTheReset() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    escalateTo(harness, denials: 3)
    XCTAssertEqual(harness.client.backoffState.attempts, 3)

    // This handshake is refused too, but only after the session did real work.
    harness.handshake()
    XCTAssertTrue(harness.client.backoffState.resetArmed)
    harness.deliverMessage(pooledMessage(messageID: "msg-work"))
    XCTAssertFalse(harness.client.backoffState.resetArmed)

    harness.serverClose(reason: .poolFull, detail: "rate_limited")

    // One, not four: the session earned its cheap retry.
    XCTAssertEqual(harness.client.backoffState.attempts, 1)
  }

  func test_SB46_anAcceptedReportSpendsTheReset() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    escalateTo(harness, denials: 3)

    harness.handshake()
    // A host-reported status, so the report that gets answered is not the
    // DELIVERED that a message would have queued.
    harness.client.report(messageId: "msg-9", status: .displayed)
    harness.ack(accepted: true, token: "msg-9:2")
    XCTAssertFalse(harness.client.backoffState.resetArmed)

    harness.serverClose(reason: .poolFull, detail: "rate_limited")

    XCTAssertEqual(harness.client.backoffState.attempts, 1)
  }

  func test_SB46_aBarePollDoesNotSpendTheReset() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    escalateTo(harness, denials: 3)

    harness.handshake()
    XCTAssertTrue(harness.client.backoffState.resetArmed)

    // A poll that drains nothing is answered with silence: "a polite client
    // polling" and "a client about to be refused" are indistinguishable on the
    // wire, so the poll cannot be the signal.
    let pollsBefore = harness.polls.count
    harness.scheduler.advance(by: 5_000)
    XCTAssertGreaterThan(harness.polls.count, pollsBefore)
    XCTAssertTrue(harness.client.backoffState.resetArmed)

    harness.serverClose(reason: .poolFull, detail: "rate_limited")

    XCTAssertEqual(harness.client.backoffState.attempts, 4, "an unspent reset is forfeited")
  }

  func test_SB46_aRejectedReportDoesNotSpendTheReset() {
    // The relay correlates rejections with an ack_token and a failure code
    // (`internal/ws/handler.go:82-106`). A rejection is the session reporting
    // that it is under pressure, so spending the reset on it would undo the
    // whole mechanism — and `rate_limited` specifically is the report budget
    // shedding us.
    for error in ["rate_limited", "upstream_forward_failed"] {
      let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
      escalateTo(harness, denials: 3)
      XCTAssertEqual(harness.client.backoffState.attempts, 3, "precondition for \(error)")

      harness.handshake()
      harness.client.report(messageId: "msg-9", status: .displayed)
      harness.ack(accepted: false, error: error, token: "msg-9:2")
      XCTAssertTrue(
        harness.client.backoffState.resetArmed,
        "a rejection spent the reset (\(error))")

      harness.serverClose(reason: .poolFull, detail: "rate_limited")

      // Climbs to 4, exactly as if the report had never been sent.
      XCTAssertEqual(harness.client.backoffState.attempts, 4, "for \(error)")
    }
  }
}

// MARK: - Helpers

/// Burn `denials` budget denials so the next session starts with a spent budget
/// and a recorded pre-handshake count.
///
/// The pin is the whole trick: after this the forfeit restores a *non-zero*
/// count, so the next attempt is observably 4 rather than the 1 it would be
/// either way. Without it these tests pass for the wrong reason — which is how
/// the reference suite's first draft of B12 passed.
func escalateTo(_ harness: SocketHarness, denials: Int) {
  for _ in 0..<denials {
    harness.handshake()
    harness.serverClose(reason: .poolFull, detail: "rate_limited")
    harness.scheduler.advance(by: 60_000)
  }
}