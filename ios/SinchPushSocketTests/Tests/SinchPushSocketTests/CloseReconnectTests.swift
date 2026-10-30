//  CloseReconnectTests.swift — the close-reason matrix and what happens after
//  it (SB-41 … SB-53).
//
//  These are the paths the relay's rate limiting drives, and the ones the
//  reference TypeScript suite (`pushSocketClient.test.ts`, cases B1–B7) pins:
//  four retryable reasons that must behave identically, two terminal ones that
//  must stay terminal, one that reconnects instantly, and the timer bookkeeping
//  that keeps any of them from opening a second socket.
//
//  Every test here is about *what happens next*, so the fake clock is used
//  explicitly rather than implicitly: a scheduler with no work to do proves
//  nothing, and an hour of virtual time costs nothing.

import XCTest

@testable import SinchPushSocket

final class CloseReconnectTests: XCTestCase {

  // MARK: - SB-41 the matrix

  func test_SB41_poolFullIsRetryablePressureNotTerminal() {
    let harness = makeHarness()
    harness.handshake()

    // The relay's rate-limit shed: a live session that exceeded its budget.
    harness.serverClose(reason: .poolFull, detail: "rate_limited")

    XCTAssertEqual(harness.recorder.current?.status, .reconnecting)
    XCTAssertEqual(harness.recorder.current?.reconnectAttempts, 1)
    XCTAssertEqual(harness.recorder.current?.lastError, "rate_limited")
    XCTAssertFalse(harness.published(.stopped))
    XCTAssertFalse(harness.published(.error))
  }

  func test_SB41_shutdownInternalAndUnspecifiedAreAllJustRetryablePressure() {
    // "The four retryable reasons MUST be handled identically" — so this loops
    // the whole set and asserts the identical outcome rather than four
    // near-identical tests that could each drift.
    let retryable: [Sinch_Push_Delivery_V1beta1_Ws_CloseReason] = [
      .poolFull, .shutdown, .internal, .unspecified,
    ]

    for reason in retryable {
      let harness = makeHarness()
      harness.handshake()
      harness.serverClose(reason: reason, detail: "whatever")

      XCTAssertEqual(
        harness.recorder.current?.status, .reconnecting,
        "reason \(reason.rawValue) should be retryable")
      XCTAssertEqual(harness.recorder.current?.reconnectAttempts, 1)

      harness.scheduler.advance(by: 500)
      XCTAssertEqual(harness.socketCount, 2, "reason \(reason.rawValue) should reconnect")
    }
  }

  func test_SB41_aPoolFullCloseIsIndistinguishableFromOtherPressure() {
    // SB-41's last paragraph: the shed must not be special-cased into something
    // the relay can tell apart. Same reason, different detail; same detail,
    // different reason. Nothing may change because of the string.
    let withDetail = makeHarness()
    withDetail.handshake()
    withDetail.serverClose(reason: .poolFull, detail: "rate_limited")
    let pooledState = withDetail.recorder.current

    let withOtherDetail = makeHarness()
    withOtherDetail.handshake()
    withOtherDetail.serverClose(reason: .poolFull, detail: "renamed_by_the_relay")
    let renamedState = withOtherDetail.recorder.current

    XCTAssertEqual(pooledState?.status, renamedState?.status)
    XCTAssertEqual(pooledState?.reconnectAttempts, renamedState?.reconnectAttempts)
    XCTAssertEqual(withOtherDetail.scheduler.pendingDelays, withDetail.scheduler.pendingDelays)
  }

  // MARK: - SB-43 no hot redial

  func test_SB43_aShedDoesNotRedialInTheSameTick() {
    let harness = makeHarness()
    harness.handshake()

    harness.serverClose(reason: .poolFull, detail: "rate_limited")
    XCTAssertEqual(harness.socketCount, 1)

    // The whole point of shedding: the client must wait, not redial into the
    // limiter that just rejected it. The jitter draw is pinned at 0.5, so
    // attempt 1 is a 500 ms delay and a hot retry would show up here as a
    // second socket.
    harness.scheduler.advance(by: 0)
    XCTAssertEqual(harness.socketCount, 1)
    XCTAssertEqual(harness.scheduler.pendingDelays, [500])

    // ...and it does come back, on its own schedule.
    harness.scheduler.advance(by: 500)
    XCTAssertEqual(harness.socketCount, 2)
  }

  // MARK: - SB-47 STALE

  func test_SB47_staleReconnectsImmediatelyWithNoTimerAtAll() {
    let harness = makeHarness()
    harness.handshake()

    harness.serverClose(reason: .stale, detail: "session expired")

    // No clock movement, no timer: the credential is fine, only a fresh Hello
    // was missing.
    XCTAssertEqual(harness.socketCount, 2)
    XCTAssertEqual(harness.pendingTimers, 0)
    XCTAssertTrue(harness.logger.contains("session stale"))
  }

  func test_SB47_staleResetsTheBackoffBudget() {
    let harness = makeHarness()

    // Spend the budget first, so a reset is observable at all. Only a budget
    // denial accumulates attempts across sessions, because a completed
    // handshake resets them — which is the whole of SB-45.
    for _ in 0..<3 {
      harness.handshake()
      harness.serverClose(reason: .poolFull, detail: "rate_limited")
      harness.scheduler.advance(by: 60_000)
    }
    XCTAssertEqual(harness.client.backoffState.attempts, 3)

    // The session hit its server-side TTL. The credential is fine; only a fresh
    // Hello is missing, and the next failure is a genuinely new one.
    harness.handshake()
    harness.serverClose(reason: .stale)
    XCTAssertEqual(harness.client.backoffState.attempts, 0)

    harness.handshake(connectionID: "conn-after-stale")
    harness.serverClose(reason: .internal)

    // Attempt 1, not attempt 4: the reset is what makes the blip cheap.
    XCTAssertEqual(harness.client.backoffState.attempts, 1)
    XCTAssertEqual(harness.recorder.current?.reconnectAttempts, 1)
  }

  // MARK: - SB-48 UNAUTHORIZED

  func test_SB48_unauthorizedIsTerminal() {
    let harness = makeHarness()
    harness.handshake()

    harness.serverClose(reason: .unauthorized, detail: "bad token")

    XCTAssertEqual(harness.recorder.current?.status, .authRequired)
    XCTAssertEqual(harness.recorder.current?.lastError, "bad token")

    let sockets = harness.socketCount
    harness.advanceToNoFutureTimer()
    XCTAssertEqual(harness.socketCount, sockets, "an unauthorized close must not reconnect")
    XCTAssertEqual(harness.pendingTimers, 0)
  }

  func test_SB48_unauthorizedWithoutADetailStillNamesTheReason() {
    let harness = makeHarness()
    harness.handshake()

    harness.serverClose(reason: .unauthorized)

    XCTAssertEqual(
      harness.recorder.current?.lastError,
      "server closed (reason=\(Sinch_Push_Delivery_V1beta1_Ws_CloseReason.unauthorized.rawValue))")
  }

  func test_SB48_theHostIsAskedToRefreshTheCredentialExactlyOnce() throws {
    let harness = makeHarness()
    harness.handshake()

    harness.serverClose(reason: .unauthorized, detail: "expired")

    // OPEN-6: a status the 1.0.x vocabulary could not express, plus one refresh
    // attempt. Not once per close — the client is terminal, so a second one
    // could only be a reconnect loop.
    XCTAssertEqual(harness.recorder.authRequiredCount, 1)
    XCTAssertEqual(harness.recorder.current?.status, .authRequired)
  }

  func test_SB48_aRefreshedCredentialIsTheOnlyWayBack() {
    let harness = makeHarness()
    harness.handshake()
    harness.serverClose(reason: .unauthorized, detail: "expired")
    let sockets = harness.socketCount

    // A credential refresh is an identity-layer action, so the caller has to
    // hand the new token over explicitly — nothing retries on its own.
    harness.client.updateConfiguration(testConfiguration(authToken: "fresh.token.value"))
    XCTAssertEqual(harness.socketCount, sockets + 1)

    harness.transport.openSocket()
    XCTAssertEqual(harness.hello?.authToken, "fresh.token.value")
    XCTAssertNil(harness.recorder.current?.lastError)
  }

  // MARK: - SB-49 BG_RESUMED

  func test_SB49_bgResumedStopsWithoutFightingTheOtherSurface() {
    let harness = makeHarness()
    harness.handshake()

    harness.serverClose(reason: .bgResumed)

    // OPEN-6's resolved value: `replaced`, so a host can tell this apart from a
    // relay that shut down (`stopped`) or refused our token (`auth_required`).
    XCTAssertEqual(harness.recorder.current?.status, .replaced)

    let sockets = harness.socketCount
    harness.advanceToNoFutureTimer()
    XCTAssertEqual(harness.socketCount, sockets, "the other surface owns the session")
    XCTAssertEqual(harness.pendingTimers, 0)
  }

  // MARK: - SB-50 never-connected failures

  func test_SB50_aTransportFailureBeforeTheSocketEverOpenedIsRetryable() {
    let harness = makeHarness()
    XCTAssertEqual(harness.socketCount, 1)
    XCTAssertFalse(harness.transport.isOpen)

    // With upgrade rate limiting armed the relay answers 429/503 on the HTTP
    // upgrade, which a WebSocket client cannot see — only a 1006. Treating that
    // as terminal turns a rate refusal into permanent silence.
    harness.transport.failTransport(code: 1006)

    XCTAssertEqual(harness.recorder.current?.status, .reconnecting)
    XCTAssertEqual(harness.recorder.current?.reconnectAttempts, 1)

    // Attempt 1 from the base delay, full jitter: pinned draw 0.5 -> 500 ms.
    XCTAssertEqual(harness.scheduler.pendingDelays, [500])
    harness.scheduler.advance(by: 500)
    XCTAssertEqual(harness.socketCount, 2)
  }

  // MARK: - SB-51 idempotent reconnects, inert sockets

  func test_SB51_oneDisconnectSchedulesExactlyOneReconnect() {
    let harness = makeHarness()

    // Three sessions, three disconnects. Each `serverClose` is *two* events — the
    // protocol Close frame and then the transport close — and the client must
    // still leave one timer and open one socket. A stacked timer is what turns
    // one relay hiccup into two connections and a corrupted attempt counter.
    for round in 1...3 {
      harness.handshake()
      harness.serverClose(reason: .shutdown)

      XCTAssertEqual(harness.pendingTimers, 1, "round \(round) stacked timers")
      XCTAssertEqual(harness.client.backoffState.attempts, 1, "round \(round) double-counted")

      let before = harness.socketCount
      harness.scheduler.advance(by: 30_000)
      XCTAssertEqual(harness.socketCount, before + 1, "one timer, one socket (round \(round))")
    }
  }

  func test_SB51_aReplacedSocketCannotDriveASecondReconnect() {
    let harness = makeHarness()
    harness.handshake()
    let replaced = harness.transport

    // A new session, so the old socket has been replaced.
    harness.transport.failTransport(code: 1006)
    harness.scheduler.advance(by: 500)
    harness.handshake(connectionID: "conn-2")
    XCTAssertEqual(harness.socketCount, 2)

    let sockets = harness.socketCount
    let states = harness.recorder.statuses.count

    // OkHttp keeps delivering `onClosed` for a socket the app threw away, and
    // one trailing callback is enough to schedule a second reconnect and
    // corrupt the attempt counter.
    replaced.replayRetainedClose()

    XCTAssertEqual(harness.socketCount, sockets)
    XCTAssertEqual(harness.recorder.statuses.count, states, "a replaced socket must be inert")
    XCTAssertEqual(harness.client.backoffState.attempts, 0)
  }

  func test_SB51_aReplacedSocketCannotDeliverAMessageEither() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    harness.handshake()
    let replaced = harness.transport

    harness.transport.failTransport(code: 1006)
    harness.scheduler.advance(by: 500)
    harness.handshake(connectionID: "conn-2")

    replaced.replayRetainedBinary(
      ServerFrame(.message(messageFrame(pooled: pooledMessage(messageID: "msg-ghost")))))

    XCTAssertEqual(harness.deliveredMessageIDs, [], "a replaced socket must not deliver")
  }

  // MARK: - SB-52 SHUTDOWN must not latch

  func test_SB52_shutdownRetriesIntoAFreshSessionWithoutLatching() {
    let harness = makeHarness()
    harness.handshake(connectionID: "conn-1")

    // A relay SIGTERM drains gracefully for ~5 s and the Close may or may not
    // get out, so the guarantee is the transition and the new session, not the
    // frame.
    harness.serverClose(reason: .shutdown)

    XCTAssertFalse(harness.published(.stopped))
    XCTAssertFalse(harness.published(.error))
    XCTAssertFalse(harness.published(.authRequired))
    XCTAssertFalse(harness.published(.replaced))

    harness.scheduler.advance(by: 500)
    harness.handshake(connectionID: "conn-2")

    XCTAssertEqual(harness.recorder.current?.status, .connected)
    XCTAssertEqual(harness.recorder.current?.connectionId, "conn-2")
  }

  // MARK: - SB-53 timers

  func test_SB53_terminalTransitionsLeaveNoTimerBehind() {
    // Stopping, UNAUTHORIZED, BG_RESUMED and STALE all cancel the poll timer
    // and any pending reconnect *before* the socket is closed.
    let terminal: [(String, Sinch_Push_Delivery_V1beta1_Ws_CloseReason)] = [
      ("UNAUTHORIZED", .unauthorized), ("BG_RESUMED", .bgResumed),
    ]

    for (name, reason) in terminal {
      let harness = makeHarness()
      harness.handshake()
      XCTAssertEqual(harness.pendingTimers, 1, "\(name): a connected client polls")

      harness.serverClose(reason: reason)

      XCTAssertEqual(harness.pendingTimers, 0, "\(name) left a timer behind")
    }

    // STALE reconnects immediately, so its assertion is that nothing is
    // pending *and* the new socket already exists.
    let stale = makeHarness()
    stale.handshake()
    stale.serverClose(reason: .stale)
    XCTAssertEqual(stale.pendingTimers, 0, "STALE left a timer behind")
    XCTAssertEqual(stale.socketCount, 2)
  }

  func test_SB53_aStoppedClientCannotBeRevivedByAClock() {
    let harness = makeHarness()
    harness.handshake()

    harness.client.stop()

    XCTAssertEqual(harness.recorder.current?.status, .stopped)
    XCTAssertEqual(harness.pendingTimers, 0)
    let sockets = harness.socketCount
    harness.advanceToNoFutureTimer()
    XCTAssertEqual(harness.socketCount, sockets)
  }

  func test_SB53_stopCancelsAPendingReconnect() {
    let harness = makeHarness()
    harness.handshake()
    harness.transport.failTransport(code: 1006)
    XCTAssertEqual(harness.pendingTimers, 1, "a reconnect is pending")

    harness.client.stop()

    XCTAssertEqual(harness.pendingTimers, 0)
    let sockets = harness.socketCount
    harness.scheduler.advance(by: 60_000)
    XCTAssertEqual(harness.socketCount, sockets)
  }

  // MARK: - Stop vs. start

  func test_SB53_startAfterStopReconnects() {
    let harness = makeHarness()
    harness.handshake()
    harness.client.stop()
    let sockets = harness.socketCount

    harness.client.start()

    XCTAssertEqual(harness.socketCount, sockets + 1)
    XCTAssertEqual(harness.recorder.statuses.last, .connecting)
  }
}

// MARK: - Helpers

/// A `Message` frame wrapping `pooled`, with no ack token.
func messageFrame(pooled: Sinch_Push_Delivery_V1beta1_Ws_PooledMessage)
  -> Sinch_Push_Delivery_V1beta1_Ws_Message
{
  var message = Sinch_Push_Delivery_V1beta1_Ws_Message()
  message.message = pooled
  return message
}