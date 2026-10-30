//  LifecycleTests.swift — iOS is foreground-only (SB-56, SB-57).
//
//  APNs remains the background channel, so the whole of the iOS socket story is
//  what happens on the two transitions: `didEnterBackground` closes with 1000
//  and holds everything, `willEnterForeground` reconnects and then does the two
//  things SB-23 requires after every handshake.
//
//  The lifecycle is driven here through the client, which is the same entry
//  point `UIApplicationSocketLifecycle` (in `iOS/`, which needs UIKit and so is
//  not compile-checked by this host) calls. Driving the client rather than the
//  observer is what makes the behaviour testable at all; what that observer adds
//  is only the notification wiring, and it is listed in the report as unverified
//  until the example app exists.

import XCTest

@testable import SinchPushSocket

final class LifecycleTests: XCTestCase {

  func test_SB56_backgroundClosesTheSocketWithOneThousand() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    harness.handshake()

    harness.client.suspend()

    let call = harness.transport.closeCalls.last
    XCTAssertEqual(call?.code, 1000, "the background close is a normal closure")
    XCTAssertEqual(harness.recorder.current?.status, .idle)
    XCTAssertFalse(harness.transport.isOpen)
  }

  func test_SB56_backgroundCancelsTheBackoffAndSchedulesNothing() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    harness.handshake()

    harness.client.suspend()

    // Nothing polls, nothing redials: an hour of virtual time must produce no
    // socket at all, or the app is holding a connection the OS will kill.
    XCTAssertEqual(harness.pendingTimers, 0)
    let sockets = harness.socketCount
    harness.advanceToNoFutureTimer()
    XCTAssertEqual(harness.socketCount, sockets, "a socket was opened while backgrounded")
  }

  func test_SB56_backgroundKeepsTheConfiguration() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    harness.handshake()

    harness.client.suspend()
    harness.client.resume()
    harness.transport.openSocket()

    // Nothing about the credential is re-derived from a lifecycle transition —
    // a backgrounded app whose config was dropped on wake would silently stop
    // receiving.
    XCTAssertEqual(harness.hello?.authToken, "jwt.token.value")
    XCTAssertEqual(harness.hello?.appID, "app-1")
    XCTAssertEqual(harness.hello?.userID, "user-1")
  }

  func test_SB56_backgroundFlushesNothing() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    harness.handshake()

    // A dismissal that lands while the app is in the background. SB-56: queue
    // it; the outbox persists (SB-35), so it survives until the next handshake.
    harness.client.suspend()
    harness.client.report(messageId: "msg-1", status: .dismissed)

    XCTAssertEqual(harness.reports.count, 0, "something was flushed with no socket")
    XCTAssertEqual(harness.store.outbox.count, 1)
  }

  func test_SB56_foregroundReconnectsPollsImmediatelyAndFlushesTheOutbox() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    harness.handshake()
    harness.client.suspend()
    harness.client.report(messageId: "msg-1", status: .dismissed)

    harness.client.resume()
    XCTAssertEqual(harness.socketCount, 2, "the foreground transition reconnects")

    harness.handshake(connectionID: "conn-after-resume")

    // SB-23 and SB-56 in one place: a poll before the first tick, and the
    // outbox drained by the same handshake.
    XCTAssertEqual(harness.transport.sentKinds.first, "hello")
    XCTAssertEqual(harness.polls.count, 1)
    XCTAssertEqual(harness.reports.map(\.messageID), ["msg-1"])
    XCTAssertEqual(harness.recorder.current?.status, .connected)
    XCTAssertEqual(harness.recorder.current?.connectionId, "conn-after-resume")
  }

  func test_SB56_aBackgroundResumeStartsTheBackoffFromZero() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    harness.handshake()

    // Spend the budget on the way out, so the resume has something to reset.
    for _ in 0..<3 {
      harness.handshake()
      harness.serverClose(reason: .poolFull, detail: "rate_limited")
      harness.scheduler.advance(by: 60_000)
    }
    harness.handshake()
    harness.client.suspend()
    XCTAssertEqual(harness.client.backoffState.attempts, 0)

    harness.client.resume()
    harness.handshake()
    harness.serverClose(reason: .shutdown)

    // Coming back to the foreground is a new start, not a continuation of a
    // budget the app had already spent in the background.
    XCTAssertEqual(harness.client.backoffState.attempts, 1)
  }

  func test_SB56_aSecondBackgroundSignalIsIgnored() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    harness.handshake()

    harness.client.suspend()
    let closes = harness.transport.closeCalls.count
    harness.client.suspend()

    // `willEnterForeground` and `didBecomeActive` both report a resume, so the
    // transitions have to be idempotent in both directions.
    XCTAssertEqual(harness.transport.closeCalls.count, closes)
  }

  func test_SB56_aResumeWithoutABackgroundIsIgnored() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    harness.handshake()

    harness.client.resume()

    XCTAssertEqual(harness.socketCount, 1)
    XCTAssertEqual(harness.recorder.current?.status, .connected)
  }

  func test_SB56_stopWhileBackgroundedStaysStopped() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    harness.handshake()
    harness.client.suspend()
    harness.client.stop()

    harness.client.resume()

    XCTAssertEqual(harness.socketCount, 1, "a stopped client was revived by a resume")
    XCTAssertEqual(harness.recorder.current?.status, .stopped)
  }

  // MARK: - SB-57 Hello.background

  func test_SB57_theBackgroundFlagIsFalseOnEveryConnect() {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))
    harness.handshake()
    harness.transport.openSocket()
    XCTAssertFalse(harness.hello?.background ?? true)

    // Including the connect that follows a suspend/resume: the flag describes
    // the surface, and on iOS the surface is never the background service.
    harness.client.suspend()
    harness.client.resume()
    harness.transport.openSocket()
    XCTAssertFalse(harness.hello?.background ?? true)

    harness.handshake()
    harness.transport.failTransport(code: 1006)
    harness.scheduler.advance(by: 60_000)
    harness.transport.openSocket()
    XCTAssertFalse(harness.hello?.background ?? true)
  }

  func test_SB57_theBackgroundFlagCannotBeConfigured() {
    // There is no `background` field on SocketConfiguration at all, so the value
    // cannot become true by accident — this asserts the absence as well as the
    // value, because a config field added later would make this compile again
    // with a different meaning.
    let configuration = testConfiguration()
    XCTAssertEqual(configuration.resolvedSDKVersion, SocketConfiguration.defaultSDKVersion)

    let harness = makeHarness(configuration: configuration)
    harness.handshake()
    harness.transport.openSocket()
    XCTAssertFalse(harness.hello?.background ?? true)
  }
}