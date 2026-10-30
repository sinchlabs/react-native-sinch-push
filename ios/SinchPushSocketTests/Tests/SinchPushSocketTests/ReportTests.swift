//  ReportTests.swift — delivery reports, dedupe and the outbox
//  (SB-25 … SB-35, SB-37, SB-40).
//
//  The relay pushes on enqueue *and* re-offers the same message on the next
//  poll, so the dedupe set and the report tracker are the two things standing
//  between one delivery and two `DELIVERED` records for it. Every assertion here
//  is about a frame the client actually put on the wire or a log line it did
//  not — the tracker is asserted through the socket, not around it, because the
//  interesting failures are integration failures (flushed at the wrong moment,
//  flushed twice, never flushed).
//
//  The two rules with no natural client-side trigger are marked where they
//  appear: SB-40's `FAILED` path can only be reached by a `Message` frame that
//  carries no message id, so the tracker's part of it is asserted directly.

import XCTest

@testable import SinchPushSocket

final class ReportTests: XCTestCase {

  /// Reports nothing locally: most of these tests are about the report frames,
  /// and a notification in the way adds a second DISPLAYED to every count.
  private func harness(
    draw: Double = 0.5,
    store: FakeSocketStateStore = FakeSocketStateStore()
  ) -> SocketHarness {
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = false
    return makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      random: draw,
      store: store,
      presenter: presenter)
  }

  // MARK: - SB-25 / SB-26 the dedupe key

  func test_SB25_theDedupeKeyIsThePooledMessageIdNotTheAckToken() throws {
    let harness = self.harness()
    harness.handshake()

    // The same message with two *different* ack tokens. Dedupe is keyed on
    // `message_id`, so the second is a hit; a token-shaped key would treat the
    // first as new whenever the relay mints tokens independently (OPEN-2).
    harness.deliverMessage(pooledMessage(messageID: "msg-1"), ackToken: "token-a")
    harness.deliverMessage(pooledMessage(messageID: "msg-1"), ackToken: "token-b")

    XCTAssertEqual(harness.deliveredMessageIDs, ["msg-1"])
    XCTAssertEqual(harness.reports(.delivered).count, 1)
  }

  func test_SB25_aColonInAMessageIdNeedsNoEscaping() {
    let harness = self.harness()
    harness.handshake()

    // The Ack correlation appends `:<status>` to the id, so a colon-shaped id is
    // exactly the case a token-shaped key could not survive.
    harness.deliverMessage(pooledMessage(messageID: "a:b:c"), ackToken: "token-a")
    harness.deliverMessage(pooledMessage(messageID: "a:b:c"), ackToken: "token-b")

    XCTAssertEqual(harness.deliveredMessageIDs, ["a:b:c"])
    XCTAssertEqual(harness.reports(.delivered).map(\.messageID), ["a:b:c"])
  }

  func test_SB26_anAckTokenThatDiffersFromTheMessageIdIsNotBranchedOn() throws {
    let harness = self.harness()
    harness.handshake()

    // OPEN-2 records both readings of the relay's invariant. Correct under
    // either: the token is carried through to the host and never interpreted.
    harness.deliverMessage(pooledMessage(messageID: "msg-1"), ackToken: "an-independent-token")

    let pending = try XCTUnwrap(harness.client.currentPendingMessages.first)
    XCTAssertEqual(pending.id, "msg-1")
    XCTAssertEqual(pending.ackToken, "an-independent-token")
  }

  // MARK: - SB-27 a dedupe hit does not present the message again

  func test_SB27_aSocketDuplicateIsNotPresentedAndSendsNoSecondReport() {
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      presenter: presenter)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "msg-1"))
    let reportsAfterFirst = harness.reports.count
    let eventsAfterFirst = harness.deliveredMessageIDs
    // DELIVERED and DISPLAYED — the two reports one delivery produces.
    XCTAssertEqual(reportsAfterFirst, 2)

    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    // The hit is still acked, so this no longer follows from the dedupe. What
    // holds it is SB-30 — one DELIVERED per `(message_id, status)` — and that
    // is the right reason to hold it: a second DELIVERED counts one delivery
    // twice at the sink.
    XCTAssertEqual(harness.reports.count, reportsAfterFirst, "a socket duplicate reported again")
    XCTAssertEqual(harness.reports(.delivered).count, 1)
    XCTAssertEqual(harness.reports(.displayed).count, 1)
    XCTAssertEqual(harness.deliveredMessageIDs, eventsAfterFirst)
    XCTAssertEqual(presenter.posted.count, 1, "a socket duplicate posted a notification")
  }

  func test_SB27_aMessageWithAnEmptyIdIsDroppedWithoutAReport() {
    let harness = self.harness()
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: ""))

    // The relay refuses such a report as `missing_message_id`, so the only two
    // options are "drop it" and "send a report that will be refused".
    XCTAssertEqual(harness.reports.count, 0)
    XCTAssertEqual(harness.deliveredMessageIDs, [])
    XCTAssertTrue(harness.logger.contains("empty message_id"))
  }

  // MARK: - The bounded sent set

  private func makeTracker(_ store: FakeSocketStateStore) -> ReportTracker {
    ReportTracker(
      store: store, logger: SilentSocketLogger(), random: ScriptedRandomSource(fixed: 0.5),
      now: { 0 })
  }

  func test_RN053_theSentSetIsBoundedAtEightThousandAndEvictsOldestFirst() {
    XCTAssertEqual(ReportTracker.sentSetCapacity, 8000)
    XCTAssertEqual(ReportTracker.sentSetCapacity, SeenSet.capacity * 4)

    let store = FakeSocketStateStore()
    let tracker = makeTracker(store)
    let suffix = SocketDeliveryStatus.delivered.tokenSuffix
    func accept(_ id: String) {
      XCTAssertTrue(tracker.queue(messageId: id, sinchMessageId: "s", status: .delivered))
      var ack = Sinch_Push_Delivery_V1beta1_Ws_Ack()
      ack.ackToken = "\(id):\(suffix)"
      ack.accepted = true
      XCTAssertEqual(tracker.handle(ack), .accepted)
    }
    for index in 0..<ReportTracker.sentSetCapacity { accept("m-\(index)") }
    XCTAssertEqual(tracker.reportedKeys.count, ReportTracker.sentSetCapacity)

    accept("m-new")

    let keys = tracker.reportedKeys
    XCTAssertEqual(keys.count, ReportTracker.sentSetCapacity)
    XCTAssertFalse(keys.contains("m-0:\(suffix)"), "oldest kept")
    XCTAssertEqual(keys.first, "m-1:\(suffix)")
    XCTAssertEqual(keys.last, "m-new:\(suffix)")
    // The evicted key can be queued again; a retained one cannot.
    XCTAssertTrue(tracker.queue(messageId: "m-0", sinchMessageId: "s", status: .delivered))
    XCTAssertFalse(tracker.queue(messageId: "m-5", sinchMessageId: "s", status: .delivered))

    // Order survives a reload.
    XCTAssertEqual(makeTracker(store).reportedKeys, keys)
  }

  // MARK: - The sent set is written only where it changes

  private func ack(_ id: String, accepted: Bool, error: String = "")
    -> Sinch_Push_Delivery_V1beta1_Ws_Ack
  {
    var frame = Sinch_Push_Delivery_V1beta1_Ws_Ack()
    frame.ackToken = "\(id):\(SocketDeliveryStatus.delivered.tokenSuffix)"
    frame.accepted = accepted
    frame.error = error
    return frame
  }

  func test_RN055_queueWritesTheOutboxButNotTheSentKeys() {
    let store = FakeSocketStateStore()
    let tracker = makeTracker(store)

    XCTAssertTrue(tracker.queue(messageId: "m-1", sinchMessageId: "s", status: .delivered))

    XCTAssertEqual(store.saveOutboxCount, 1)
    XCTAssertEqual(store.outbox.map(\.messageId), ["m-1"])
    XCTAssertEqual(store.saveReportedKeysCount, 0)
  }

  func test_RN055_anAcceptedAckWritesTheSentKeysOnce() {
    let store = FakeSocketStateStore()
    let tracker = makeTracker(store)
    tracker.queue(messageId: "m-1", sinchMessageId: "s", status: .delivered)

    XCTAssertEqual(tracker.handle(ack("m-1", accepted: true)), .accepted)

    XCTAssertEqual(store.saveReportedKeysCount, 1)
    XCTAssertEqual(store.reported, ["m-1:\(SocketDeliveryStatus.delivered.tokenSuffix)"])
    XCTAssertEqual(store.outbox, [], "the accepted entry leaves the persisted outbox")
  }

  func test_RN055_aRejectedAckDoesNotWriteTheSentKeys() {
    for error in ["rate_limited", "upstream_forward_failed", "unsupported_status", "other"] {
      let store = FakeSocketStateStore()
      let tracker = makeTracker(store)
      tracker.queue(messageId: "m-1", sinchMessageId: "s", status: .delivered)

      XCTAssertEqual(
        tracker.handle(ack("m-1", accepted: false, error: error)), .rejected(error: error))

      XCTAssertEqual(store.saveReportedKeysCount, 0, error)
      XCTAssertEqual(store.reported, [], error)
    }
  }

  func test_RN055_theAcceptedKeyIsStillKnownAfterARestart() {
    let store = FakeSocketStateStore()
    let first = makeTracker(store)
    first.queue(messageId: "m-1", sinchMessageId: "s", status: .delivered)
    first.handle(ack("m-1", accepted: true))

    let restarted = makeTracker(store)

    XCTAssertEqual(restarted.reportedKeys, first.reportedKeys)
    XCTAssertFalse(restarted.queue(messageId: "m-1", sinchMessageId: "s", status: .delivered))
    // Another status of the same message is a different key and still goes out.
    XCTAssertTrue(restarted.queue(messageId: "m-1", sinchMessageId: "s", status: .displayed))
  }

  // MARK: - SB-28 the bounded seen set

  func test_SB28_theSeenSetIsBoundedAtTwoThousand() {
    var seen = SeenSet()
    for index in 0..<SeenSet.capacity {
      XCTAssertTrue(seen.insert("msg-\(index)"))
    }
    XCTAssertEqual(seen.count, 2000)
    XCTAssertEqual(SeenSet.capacity, 2000)

    // The 2001st evicts the least-recently-inserted id.
    XCTAssertTrue(seen.insert("msg-2000"))
    XCTAssertEqual(seen.count, 2000)
    XCTAssertFalse(seen.contains("msg-0"))
    XCTAssertTrue(seen.contains("msg-2000"))
    XCTAssertEqual(seen.persisted.first, "msg-1")
  }

  func test_SB28_theEvictedMessageCanBeDeliveredAgain() {
    let harness = self.harness()
    harness.handshake()

    // The bound's cost, asserted rather than assumed: an evicted id is no longer
    // deduped, so the relay may count it twice. That is the trade SB-28 accepts,
    // and it only holds if eviction really happens.
    for index in 0..<(SeenSet.capacity + 1) {
      harness.deliverMessage(pooledMessage(messageID: "msg-\(index)"))
    }
    XCTAssertEqual(harness.deliveredMessageIDs.count, SeenSet.capacity + 1)

    harness.deliverMessage(pooledMessage(messageID: "msg-0"))

    XCTAssertEqual(
      harness.deliveredMessageIDs.count, SeenSet.capacity + 2, "msg-0 was never evicted")
    XCTAssertEqual(harness.deliveredMessageIDs.filter { $0 == "msg-0" }.count, 2)
  }

  func test_SB28_theSeenSetSurvivesARestart() {
    let store = FakeSocketStateStore()

    let first = harness(store: store)
    first.handshake()
    first.deliverMessage(pooledMessage(messageID: "msg-1"))
    // Answer the report so the restart is about dedupe only — an unacked report
    // is in the outbox, and SB-35 says it must be flushed by the new client.
    first.ack(accepted: true, token: "msg-1:1")
    XCTAssertEqual(store.seen, ["msg-1"])
    XCTAssertEqual(store.outbox.count, 0)

    // A new client over the same store is what a relaunch is.
    let second = harness(store: store)
    second.handshake()
    second.deliverMessage(pooledMessage(messageID: "msg-1"))

    XCTAssertEqual(second.deliveredMessageIDs, [], "dedupe did not survive the restart")
    // SB-30: the hit is acked, but `msg-1:DELIVERED` was already reported to
    // the relay before the restart, so nothing is sent again.
    XCTAssertEqual(second.reports.count, 0)
  }

  // MARK: - SB-29 last_seen_message_id

  func test_SB29_theNewestProcessedIdIsEchoedInTheNextHello() {
    let harness = self.harness()
    harness.handshake()
    XCTAssertEqual(harness.hello?.lastSeenMessageID, "", "empty on a first connect")

    harness.deliverMessage(pooledMessage(messageID: "msg-1"))
    harness.deliverMessage(pooledMessage(messageID: "msg-2"))
    XCTAssertEqual(harness.store.lastSeen, "msg-2")

    harness.serverClose(reason: .shutdown)
    harness.scheduler.advance(by: 60_000)
    harness.transport.openSocket()

    XCTAssertEqual(harness.hello?.lastSeenMessageID, "msg-2")
  }

  // MARK: - SB-30 the report state machine

  func test_SB30_aDedupeMissReportsDeliveredOnce() {
    let harness = self.harness()
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    let delivered = harness.reports(.delivered)
    XCTAssertEqual(delivered.count, 1)
    XCTAssertEqual(delivered.first?.messageID, "msg-1")
  }

  func test_SB30_aPostedNotificationReportsDisplayed() throws {
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      presenter: presenter)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    XCTAssertEqual(presenter.posted.map(\.id), ["msg-1"])
    XCTAssertEqual(harness.reports(.displayed).count, 1)
    // `shown` is the host-facing half of the same fact: it is what
    // `getPendingPushMessages` reports back to JS.
    let pending = try XCTUnwrap(harness.client.currentPendingMessages.first)
    XCTAssertTrue(pending.shown)
  }

  func test_SB30_aRefusedNotificationDoesNotReportDisplayed() {
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = false
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      presenter: presenter)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    // Nothing was shown, so DISPLAYED would be a lie the sink would record.
    XCTAssertEqual(harness.reports(.delivered).count, 1)
    XCTAssertEqual(harness.reports(.displayed).count, 0)
  }

  func test_SB30_theWhenUnhandledRuleFollowsTheHostRegistration() {
    // `whenUnhandled` is the default, and it means "post unless the host app
    // has an in-app handler". DELIVERED is reported either way — it is about
    // delivery, not about display.
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .whenUnhandled),
      presenter: presenter)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "msg-1"))
    XCTAssertEqual(presenter.posted.count, 1)

    harness.client.setHandlerRegistered(true)
    harness.deliverMessage(pooledMessage(messageID: "msg-2"))
    XCTAssertEqual(presenter.posted.map(\.id), ["msg-1"])
    XCTAssertEqual(harness.reports(.delivered).count, 2)
    XCTAssertEqual(harness.reports(.displayed).count, 1)
  }

  func test_SB30_theNeverRulePostsNothingAtAll() {
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .never),
      presenter: presenter)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    XCTAssertEqual(presenter.posted.count, 0)
    XCTAssertEqual(harness.reports(.displayed).count, 0)
    XCTAssertEqual(harness.reports(.delivered).count, 1)
  }

  func test_SB30_aDismissedReportIsSentOnceWithTheOriginalMessageId() {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))
    harness.ack(accepted: true, token: "msg-1:1")

    // The notification was swiped away. The pooled id is what the relay
    // correlates on; the sinch id is the upstream message's, retained by the
    // tracker because it is gone from the host's hands by now.
    harness.client.report(messageId: "msg-1", status: .dismissed)

    let dismissed = harness.reports(.dismissed)
    XCTAssertEqual(dismissed.count, 1)
    XCTAssertEqual(dismissed.first?.messageID, "msg-1")
    XCTAssertEqual(dismissed.first?.sinchMessageID, "sinch-msg-1")
  }

  func test_SB30_theSameMessageAndStatusIsNeverReportedTwice() {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    // Three calls, one queued entry: SB-30's "at most once per
    // `(message_id, status)`" is what stops a double-tapped dismiss button from
    // producing two records at the sink.
    harness.client.report(messageId: "msg-1", status: .dismissed)
    harness.client.report(messageId: "msg-1", status: .dismissed)
    harness.client.report(messageId: "msg-1", status: .dismissed)

    XCTAssertEqual(harness.reports(.dismissed).count, 1)

    // ...and once the relay has accepted it, still one.
    harness.ack(accepted: true, token: "msg-1:4")
    harness.client.report(messageId: "msg-1", status: .dismissed)
    XCTAssertEqual(harness.reports(.dismissed).count, 1)
    XCTAssertTrue(harness.store.reported.contains("msg-1:4"))
  }

  func test_SB30_differentStatusesForOneMessageAreBothReported() {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    harness.client.report(messageId: "msg-1", status: .displayed)
    harness.client.report(messageId: "msg-1", status: .dismissed)

    // The key is the pair, not the id.
    XCTAssertEqual(harness.reports(.displayed).count, 1)
    XCTAssertEqual(harness.reports(.dismissed).count, 1)
  }

  // MARK: - SB-31 report fields

  func test_SB31_aReportCarriesEveryFieldTheRelayRequires() throws {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    let report = try XCTUnwrap(harness.reports.first)
    XCTAssertEqual(report.messageID, "msg-1")
    XCTAssertEqual(report.sinchMessageID, "sinch-msg-1")
    XCTAssertEqual(report.status, .delivered)
    XCTAssertEqual(report.reason, "")
    // SB-15: 64-bit fields survive the round trip exactly, so this is an
    // integer and not a rounded double.
    XCTAssertEqual(report.reportedAtUnixMillis, harness.scheduler.nowMs())
  }

  func test_SB31_theTrackersFailedReasonIsPrefixedWithDecode() {
    // SB-40's format, asserted on the tracker because the client cannot reach
    // it: the only in-band trigger is a `Message` frame with no pooled message,
    // and that frame carries no id either, so the report it would name cannot be
    // sent (see the SB-40 test below).
    let store = FakeSocketStateStore()
    let scheduler = ManualScheduler()
    let tracker = ReportTracker(
      store: store,
      logger: SilentSocketLogger(),
      random: ScriptedRandomSource(fixed: 0.5),
      now: { scheduler.nowMs() })

    tracker.queueFailure(messageId: "msg-7", sinchMessageId: "sinch-7", detail: "no payload")

    XCTAssertEqual(store.outbox.count, 1)
    XCTAssertEqual(store.outbox.first?.status, .failed)
    XCTAssertEqual(store.outbox.first?.reason, "decode: no payload")
  }

  func test_SB31_aReportCanNeverCarryAnEmptyMessageId() {
    let store = FakeSocketStateStore()
    let tracker = ReportTracker(
      store: store,
      logger: SilentSocketLogger(),
      random: ScriptedRandomSource(fixed: 0.5),
      now: { 1 })

    // The relay refuses this as `missing_message_id`; the Kotlin client sends it
    // anyway (`ProtoCodec.kt:173-176`). Logged, not sent.
    tracker.queueFailure(messageId: "", sinchMessageId: "", detail: "message frame without a pooled message")

    XCTAssertEqual(store.outbox.count, 0)
    XCTAssertEqual(tracker.reportsToSend(nowMs: 1, mode: .all).count, 0)
  }

  // MARK: - SB-32 the correlation token

  func test_SB32_theAckTokenIsTheNumericStatusSuffix() {
    // Never the enum name: the relay builds this string and states it never
    // parses it, so both sides only have to agree on the number.
    XCTAssertEqual(SocketDeliveryStatus.delivered.tokenSuffix, "1")
    XCTAssertEqual(SocketDeliveryStatus.displayed.tokenSuffix, "2")
    XCTAssertEqual(SocketDeliveryStatus.failed.tokenSuffix, "3")
    XCTAssertEqual(SocketDeliveryStatus.dismissed.tokenSuffix, "4")
    XCTAssertEqual(
      PendingReport(
        messageId: "msg-1", sinchMessageId: "s", status: .displayed,
        reason: "", attempts: 0, deferUntilMs: nil).ackToken,
      "msg-1:2")
  }

  func test_SB32_aTokenForAnUnknownReportChangesNothing() {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    harness.ack(accepted: false, error: "rate_limited", token: "msg-other:1")

    XCTAssertEqual(harness.store.outbox.count, 1, "an uncorrelated Ack changed the entry")
    XCTAssertTrue(harness.logger.contains("matches no queued report"))
  }

  func test_SB32_anEmptyTokenIsUncorrelatableRatherThanTheEmptyIdReport() {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    // An empty `message_id` yields an empty token, not `":1"`. Correlating this
    // as a real report would mean parsing the token to find that out.
    harness.ack(accepted: true, token: "")

    XCTAssertEqual(harness.store.outbox.count, 1)
    XCTAssertTrue(harness.logger.contains("empty token is uncorrelatable"))
  }

  // MARK: - SB-33 the Ack.error vocabulary

  func test_SB33_rateLimitedDefersTheReportInsteadOfRetryingOnThePoll() {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))
    XCTAssertEqual(harness.reports.count, 1)

    harness.ack(accepted: false, error: "rate_limited", token: "msg-1:1")

    // Deferral deadline: attempt 1, draw 0.5 -> 500 ms from now.
    XCTAssertEqual(
      harness.store.outbox.first?.deferUntilMs, harness.scheduler.nowMs() + 500)
    // Every rejection sets lastError, and none of them changes the status: the
    // session is up, it is just being shed.
    XCTAssertEqual(harness.recorder.current?.lastError, "rate_limited")
    XCTAssertEqual(harness.recorder.current?.status, .connected)
  }

  func test_SB33_aDeferralIsRetriedOnItsOwnTimerNotOnThePoll() {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))
    harness.ack(accepted: false, error: "rate_limited", token: "msg-1:1")

    // Nothing fires before the deferral expires.
    harness.scheduler.advance(by: 499)
    XCTAssertEqual(harness.reports.count, 1)

    // The deferral timer, one-shot, fires at the end of the backoff the tracker
    // chose. This is the *only* thing that retries a rate-limited report.
    harness.scheduler.advance(by: 1)
    XCTAssertEqual(harness.reports.count, 2)

    // Twenty seconds of polling later, the report is still out there once: the
    // relay has not answered it and nothing re-sent it.
    harness.scheduler.advance(by: 20_000)
    XCTAssertEqual(harness.reports.count, 2)
    XCTAssertGreaterThan(harness.polls.count, 2, "the poll timer kept running")
  }

  func test_SB33_aPollTickDoesNotRetryADeferredReport() {
    // A 1 s poll interval and a deferral that outlasts it — the only way to put
    // a poll tick between a rejection and the end of its deferral, which is
    // what SB-33's first row forbids.
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = false
    let harness = makeHarness(
      configuration: testConfiguration(
        pollIntervalMs: 1000, displayNotifications: .always),
      random: 0.999,
      presenter: presenter)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "msg-1"))
    // First refusal: deferred by floor(0.999 · 1000) = 999 ms.
    harness.ack(accepted: false, error: "rate_limited", token: "msg-1:1")
    harness.scheduler.advance(by: 999)
    XCTAssertEqual(harness.reports.count, 2, "the first deferral was never retried")

    // Second refusal: deferred by floor(0.999 · 2000) = 1998 ms, which is longer
    // than the poll interval, so a poll tick lands inside the deferral.
    harness.ack(accepted: false, error: "rate_limited", token: "msg-1:1")
    harness.scheduler.advance(by: 1_000)

    XCTAssertEqual(harness.polls.count, 2, "a poll tick happened inside the deferral")
    XCTAssertEqual(
      harness.reports.count, 2, "the poll tick retried a deferred report")

    // ...and the deferral still fires on its own timer.
    harness.scheduler.advance(by: 2_000)
    XCTAssertEqual(harness.reports.count, 3)
  }

  func test_SB33_aForwardFailureRetriesOnThePollTickUpToThreeTimes() {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    // Bounded, because a permanently unreachable sink must not make the outbox
    // retry forever. Three retries, then the entry is dropped with a log line.
    for attempt in 1...3 {
      harness.ack(accepted: false, error: "upstream_forward_failed", token: "msg-1:1")
      harness.scheduler.advance(by: 5_000)
      XCTAssertEqual(harness.reports.count, attempt + 1, "retry \(attempt)")
    }

    harness.ack(accepted: false, error: "upstream_forward_failed", token: "msg-1:1")
    XCTAssertEqual(harness.store.outbox.count, 0)
    XCTAssertTrue(harness.logger.contains("after 4 forward failures"))

    harness.scheduler.advance(by: 20_000)
    XCTAssertEqual(harness.reports.count, 4, "a dropped entry is not retried again")
  }

  func test_SB33_anUnsupportedStatusIsDroppedPermanently() {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    harness.ack(accepted: false, error: "unsupported_status", token: "msg-1:1")

    XCTAssertEqual(harness.store.outbox.count, 0)
    XCTAssertEqual(harness.recorder.current?.lastError, "unsupported_status")
    XCTAssertTrue(harness.logger.contains("does not support this status"))

    harness.scheduler.advance(by: 20_000)
    XCTAssertEqual(harness.reports.count, 1)
  }

  func test_SB33_anUnrecognisedErrorIsLoggedAndChangesNoEntry() {
    for error in ["", "some_future_code"] {
      let harness = self.harness()
      harness.handshake()
      harness.deliverMessage(pooledMessage(messageID: "msg-1"))

      harness.ack(accepted: false, error: error, token: "msg-1:1")

      // Log only: never clear, fail or retry a specific entry.
      XCTAssertEqual(harness.store.outbox.count, 1, "for '\(error)'")
      XCTAssertTrue(harness.logger.contains("ack refused with error '\(error)'"))
      XCTAssertEqual(
        harness.store.outbox.first?.attempts, 0,
        "a retry counter moved on an unknown error")
    }
  }

  func test_SB33_everyRejectionSetsLastError() {
    for error in ["rate_limited", "upstream_forward_failed", "unsupported_status", ""] {
      let harness = self.harness()
      harness.handshake()
      harness.deliverMessage(pooledMessage(messageID: "msg-1"))
      XCTAssertNil(harness.recorder.current?.lastError, "precondition for '\(error)'")

      harness.ack(accepted: false, error: error, token: "msg-1:1")

      XCTAssertNotNil(
        harness.recorder.current?.lastError,
        "a rejection of '\(error)' left lastError unset")
    }
  }

  // MARK: - SB-34 accepted vs. rejected

  func test_SB34_anAcceptedAckIsLoggedAsAccepted() {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    harness.ack(accepted: true, token: "msg-1:1")

    XCTAssertTrue(harness.logger.contains("ack accepted=true"))
    XCTAssertEqual(harness.store.outbox.count, 0, "an accepted report leaves the outbox")
    XCTAssertTrue(harness.store.reported.contains("msg-1:1"))
  }

  // MARK: - SB-35 the outbox

  func test_SB35_aReportQueuedWhileDisconnectedIsSentAfterTheNextHandshake() {
    let harness = self.harness()
    XCTAssertEqual(harness.recorder.current?.status, .connecting)

    // The iOS case that matters: a notification is dismissed while the socket is
    // closed, so the report has to be held rather than dropped.
    harness.client.report(messageId: "msg-1", status: .dismissed)
    XCTAssertEqual(harness.reports.count, 0)
    XCTAssertEqual(harness.store.outbox.count, 1)

    harness.handshake()

    XCTAssertEqual(harness.reports.map(\.messageID), ["msg-1"])
    XCTAssertEqual(harness.store.outbox.count, 1, "still in flight until the relay answers")
  }

  func test_SB35_aQueuedReportSurvivesAClientRestart() throws {
    let store = FakeSocketStateStore()

    let before = harness(store: store)
    before.client.report(messageId: "msg-1", status: .dismissed)
    XCTAssertEqual(store.outbox.count, 1)
    XCTAssertEqual(store.outbox.first?.status, .dismissed)

    // A new client over the same store is what a relaunch is: the point is that
    // the report is in the *store*, not in the tracker that died with the
    // process.
    let after = harness(store: store)
    after.handshake()

    let sent = try XCTUnwrap(after.reports.first)
    XCTAssertEqual(sent.messageID, "msg-1")
    XCTAssertEqual(sent.status, .dismissed)
  }

  func test_SB35_theOutboxIsBoundedAtTwoHundredEntries() {
    let existing = (0..<ReportTracker.outboxCapacity).map { index in
      PendingReport(
        messageId: "old-\(index)", sinchMessageId: "s", status: .delivered,
        reason: "", attempts: 0, deferUntilMs: nil)
    }
    XCTAssertEqual(ReportTracker.outboxCapacity, 200)
    let harness = self.harness(store: FakeSocketStateStore(outbox: existing))

    harness.client.report(messageId: "new-1", status: .dismissed)

    // Oldest evicted, with a log line: an unbounded outbox is a slow leak on a
    // long-lived app, and a silent one is worse.
    XCTAssertEqual(harness.store.outbox.count, 200)
    XCTAssertNil(harness.store.outbox.first { $0.messageId == "old-0" })
    XCTAssertEqual(harness.store.outbox.last?.messageId, "new-1")
    XCTAssertTrue(harness.logger.contains("outbox full"))
  }

  func test_SB35_aReportInFlightIsResentAfterTheConnectionDrops() {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))
    XCTAssertEqual(harness.reports.count, 1)

    // The socket dies before the Ack. The Ack can never arrive, so the report
    // has to go back to queued — otherwise the report is lost to a connection
    // that was not the relay's fault.
    harness.transport.failTransport(code: 1006)
    harness.scheduler.advance(by: 500)
    harness.handshake(connectionID: "conn-2")

    XCTAssertEqual(harness.reports.map(\.messageID), ["msg-1"])
  }

  // MARK: - SB-36 proto3 empty strings

  func test_SB36_anExplicitlyEmptyAlertFieldIsAbsentRatherThanEmpty() throws {
    let harness = self.harness()
    harness.handshake()

    harness.deliverMessage(blankPooledMessage(messageID: "msg-1"))

    let pending = try XCTUnwrap(harness.client.currentPendingMessages.first)
    // proto3 cannot tell "never set" from "set to empty", and `""` is a value
    // nobody typed: the display layer then renders the app label.
    XCTAssertNil(pending.title)
    XCTAssertNil(pending.body)
    XCTAssertNil(pending.imageUrl)
    XCTAssertNil(pending.trigger)
    // ...and absent is absent on the JS surface too, not `"title": null`.
    let dictionary = pending.dictionary
    XCTAssertNil(dictionary["title"])
    XCTAssertNil(dictionary["trigger"])
  }

  func test_SB36_aPopulatedAlertArrivesIntact() throws {
    let harness = self.harness()
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    let pending = try XCTUnwrap(harness.client.currentPendingMessages.first)
    // Astral-plane text included: this is a Swift String end to end, and the
    // protobuf layer is the only place bytes become characters.
    XCTAssertEqual(pending.title, "Grüße 🎉")
    XCTAssertEqual(pending.body, "body ✓")
    XCTAssertEqual(pending.imageUrl, "https://example.test/i.png")
    XCTAssertEqual(pending.trigger, "push")
    XCTAssertEqual(pending.metadata, ["campaign": "spring", "locale": "de-DE"])
  }

  func test_SB36_aCloseWithoutADetailIsAbsentNotEmpty() {
    // The same mapping on the close path: an empty `detail` becomes
    // `server closed (reason=n)` rather than a state whose lastError is `""`.
    let harness = self.harness()
    harness.handshake()
    harness.serverClose(reason: .shutdown)

    XCTAssertEqual(
      harness.recorder.current?.lastError, "server closed (reason=6)")
    XCTAssertNotEqual(harness.recorder.current?.lastError, "")
  }

  // MARK: - SB-37 channel_message_id

  func test_SB37_theReportedIdIsTheChannelMessageIdAndNothingElse() throws {
    let harness = self.harness()
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "msg-1"))

    let report = try XCTUnwrap(harness.reports.first)
    // Four facts, not one equality: asserting only `== pooled.id` passes on a
    // value that was never correlated, and asserting against `sinchMessageId` or
    // the Ack token passes for the wrong reason (both were confirmed by
    // mutation on the relay side).
    XCTAssertFalse(report.messageID.isEmpty)
    XCTAssertEqual(report.messageID, "msg-1")
    XCTAssertNotEqual(report.messageID, report.sinchMessageID)
    XCTAssertNotEqual(report.messageID, "msg-1:1")
    XCTAssertNotEqual(report.messageID, harness.hello?.authToken)
  }

  // MARK: - SB-40 the decode failure

  func test_SB40_aMessageFrameWithNoPooledMessageIsNotSilentlyDropped() {
    let harness = self.harness()
    harness.handshake()

    // A `Message` frame whose `message` field is unset. There is no id to name a
    // FAILED report with, so the tracker logs the refusal instead of sending a
    // report the relay would reject as `missing_message_id` (SB-31, OPEN-5).
    var empty = Sinch_Push_Delivery_V1beta1_Ws_Message()
    empty.ackToken = "ack-only"
    harness.transport.deliver(ServerFrame(empty))

    XCTAssertTrue(harness.logger.contains("message frame without a pooled message"))
    XCTAssertEqual(harness.reports.count, 0, "a report with an empty message_id was sent")
    XCTAssertEqual(harness.deliveredMessageIDs, [])
    // The socket stays up: one bad frame is not a reason to reconnect.
    XCTAssertEqual(harness.recorder.current?.status, .connected)
    XCTAssertEqual(harness.socketCount, 1)
  }
}