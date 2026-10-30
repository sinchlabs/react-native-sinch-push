//  ReportOutboxTests.swift — the provider-push report outbox (SB-67).

import XCTest

@testable import SinchPushSocket

final class ReportOutboxTests: XCTestCase {
  private let messageKey = PushMessageIdentity.metadataKey
  private let subscriberKey = PushMessageIdentity.subscriberIdKey

  /// A fixed clock, so `enqueuedAt` is a fact rather than a reading.
  private func makeOutbox(
    store: FakeSocketStateStore = FakeSocketStateStore(),
    nowMs: Int64 = 1_770_000_000_000
  ) -> ReportOutbox {
    ReportOutbox(store: store, now: { nowMs })
  }

  private func makeDecider(
    store: FakeSocketStateStore,
    outbox: ReportOutbox,
    onQueued: (() -> Void)? = nil
  ) -> PushPresentationDecider {
    PushPresentationDecider(
      registry: SeenMessageRegistry(store: store), outbox: outbox, onQueued: onQueued)
  }

  // MARK: - Where the report is queued

  func testSB67_anUnseenForegroundPushWithBothKeysIsQueued() {
    let store = FakeSocketStateStore()
    let outbox = makeOutbox(store: store)
    var queued = 0
    let decider = makeDecider(store: store, outbox: outbox, onQueued: { queued += 1 })

    let decision = decider.decide(
      userInfo: [messageKey: "m-1", subscriberKey: "s-1"], requestIdentifier: "m-1")

    XCTAssertEqual(decision, .present)
    XCTAssertEqual(outbox.snapshot().count, 1)
    XCTAssertEqual(outbox.snapshot().first?.messageId, "m-1")
    XCTAssertEqual(outbox.snapshot().first?.subscriberId, "s-1")
    XCTAssertEqual(outbox.snapshot().first?.enqueuedAtMs, 1_770_000_000_000)
    XCTAssertEqual(queued, 1)
  }

  func testSB67_anUnseenBackgroundPushIsQueued() {
    let store = FakeSocketStateStore()
    let outbox = makeOutbox(store: store)
    let decider = makeDecider(store: store, outbox: outbox)

    let decision = decider.decideRemoteNotification(
      userInfo: [messageKey: "m-1", subscriberKey: "s-1", "aps": ["alert": "hi"]],
      appIsActive: false)

    XCTAssertEqual(decision, .present)
    XCTAssertEqual(outbox.snapshot().count, 1)
    XCTAssertEqual(outbox.snapshot().first?.messageId, "m-1")
    XCTAssertEqual(outbox.snapshot().first?.subscriberId, "s-1")
  }

  func testSB67_theActiveAppsAlertBranchOnlyLooksUpAndNeverQueues() {
    let store = FakeSocketStateStore()
    let outbox = makeOutbox(store: store)
    let decider = makeDecider(store: store, outbox: outbox)
    let info: [AnyHashable: Any] = [
      messageKey: "m-1", subscriberKey: "s-1", "aps": ["alert": ["title": "t"]],
    ]

    // The lookup branch marks nothing, so it queues nothing.
    XCTAssertEqual(decider.decideRemoteNotification(userInfo: info, appIsActive: true), .present)
    XCTAssertEqual(outbox.snapshot().count, 0)

    XCTAssertEqual(decider.decide(userInfo: info, requestIdentifier: "m-1"), .present)
    XCTAssertEqual(outbox.snapshot().count, 1)
  }

  func testSB67_aMessageTheSocketDeliveredFirstIsNeverQueued() {
    let store = FakeSocketStateStore()
    let outbox = makeOutbox(store: store)
    // The socket marked the id before it delivered the message.
    let registry = SeenMessageRegistry(store: store)
    XCTAssertTrue(registry.markSeen("m-1"))
    var queued = 0
    let decider = PushPresentationDecider(
      registry: registry, outbox: outbox, onQueued: { queued += 1 })

    let decision = decider.decide(
      userInfo: [messageKey: "m-1", subscriberKey: "s-1"], requestIdentifier: "m-1")

    XCTAssertEqual(decision, .suppress)
    XCTAssertEqual(outbox.snapshot().count, 0, "the socket's own ack is the report")
    XCTAssertEqual(queued, 0)
  }

  func testSB67_aPushWithoutASubscriberIdIsNeverQueued() {
    let store = FakeSocketStateStore()
    let outbox = makeOutbox(store: store)
    let decider = makeDecider(store: store, outbox: outbox)

    let decision = decider.decide(
      userInfo: [messageKey: "m-1"], requestIdentifier: "m-1")

    XCTAssertEqual(decision, .present, "the push itself is still handled")
    XCTAssertEqual(outbox.snapshot().count, 0)
  }

  func testSB67_theRequestIdentifierFallbackIsNeverQueued() {
    let store = FakeSocketStateStore()
    let outbox = makeOutbox(store: store)
    let decider = makeDecider(store: store, outbox: outbox)

    // The id comes from the request identifier, which is not a message id.
    let decision = decider.decide(
      userInfo: [subscriberKey: "s-1"], requestIdentifier: "m-1")

    XCTAssertEqual(decision, .present)
    XCTAssertEqual(outbox.snapshot().count, 0)
  }

  func testSB67_onQueuedFiresOncePerAddedEntry() {
    let store = FakeSocketStateStore()
    let outbox = makeOutbox(store: store)
    var queued = 0
    let decider = makeDecider(store: store, outbox: outbox, onQueued: { queued += 1 })
    let info: [AnyHashable: Any] = [messageKey: "m-1", subscriberKey: "s-1"]

    _ = decider.decide(userInfo: info, requestIdentifier: "m-1")
    _ = decider.decide(userInfo: info, requestIdentifier: "m-1")

    XCTAssertEqual(queued, 1)
    XCTAssertEqual(outbox.snapshot().count, 1)
  }

  // MARK: - The queue itself

  func testSB67_theSamePairIsQueuedOnceAndKeepsItsFirstTimestamp() {
    let store = FakeSocketStateStore()
    var now: Int64 = 1_000
    let outbox = ReportOutbox(store: store, now: { now })

    XCTAssertTrue(outbox.enqueue(messageId: "m-1", subscriberId: "s-1"))
    now = 2_000
    XCTAssertFalse(outbox.enqueue(messageId: "m-1", subscriberId: "s-1"))

    XCTAssertEqual(outbox.snapshot().count, 1)
    XCTAssertEqual(outbox.snapshot().first?.enqueuedAtMs, 1_000)
  }

  func testSB67_theSameMessageForAnotherSubscriberIsAnotherEntry() {
    let outbox = makeOutbox()

    XCTAssertTrue(outbox.enqueue(messageId: "m-1", subscriberId: "s-1"))
    XCTAssertTrue(outbox.enqueue(messageId: "m-1", subscriberId: "s-2"))

    XCTAssertEqual(outbox.snapshot().count, 2)
    XCTAssertEqual(outbox.snapshot().map(\.subscriberId), ["s-1", "s-2"])
  }

  func testSB67_aFullOutboxDropsItsOldestEntry() {
    let outbox = makeOutbox()

    for index in 0...ReportOutbox.capacity {
      XCTAssertTrue(outbox.enqueue(messageId: "m-\(index)", subscriberId: "s-1"))
    }

    XCTAssertEqual(outbox.snapshot().count, ReportOutbox.capacity)
    XCTAssertEqual(outbox.snapshot().first?.messageId, "m-1", "the oldest one is gone")
    XCTAssertEqual(outbox.snapshot().last?.messageId, "m-\(ReportOutbox.capacity)")
  }

  func testSB67_anEmptyIdOrSubscriberIsNeverQueued() {
    let outbox = makeOutbox()

    XCTAssertFalse(outbox.enqueue(messageId: "", subscriberId: "s-1"))
    XCTAssertFalse(outbox.enqueue(messageId: "m-1", subscriberId: ""))

    XCTAssertEqual(outbox.snapshot().count, 0)
  }

  func testSB67_removingEntriesDropsOnlyTheNamedOnes() {
    let outbox = makeOutbox()
    outbox.enqueue(messageId: "m-1", subscriberId: "s-1")
    outbox.enqueue(messageId: "m-2", subscriberId: "s-1")
    outbox.enqueue(messageId: "m-1", subscriberId: "s-2")

    outbox.remove(keys: [(messageId: "m-1", subscriberId: "s-1")])

    XCTAssertEqual(outbox.snapshot().count, 2)
    XCTAssertFalse(
      outbox.snapshot().contains {
        $0.messageId == "m-1" && $0.subscriberId == "s-1"
      })
  }

  func testSB67_clearingDropsEverything() {
    let outbox = makeOutbox()
    outbox.enqueue(messageId: "m-1", subscriberId: "s-1")
    outbox.enqueue(messageId: "m-2", subscriberId: "s-1")

    outbox.clear()

    XCTAssertEqual(outbox.snapshot().count, 0)
  }

  // MARK: - Persistence

  func testSB67_aQueuedReportIsPersistedBeforeTheEnqueueReturns() {
    let store = FakeSocketStateStore()
    let outbox = makeOutbox(store: store)

    outbox.enqueue(messageId: "m-1", subscriberId: "s-1")

    XCTAssertEqual(store.reportOutbox.count, 1)
    XCTAssertEqual(store.reportOutbox.first?.messageId, "m-1")
  }

  func testSB67_aFreshOutboxOverTheSameStoreSeesTheQueuedReports() {
    let store = FakeSocketStateStore()
    let first = makeOutbox(store: store, nowMs: 5)
    first.enqueue(messageId: "m-1", subscriberId: "s-1")

    // A second outbox over the same store is what a relaunch looks like.
    let second = makeOutbox(store: store, nowMs: 6)

    XCTAssertEqual(second.snapshot().count, 1)
    XCTAssertEqual(second.snapshot().first?.enqueuedAtMs, 5, "the original timestamp is kept")
  }

  func testSB67_theOutboxRoundTripsThroughUserDefaults() throws {
    let suiteName = "com.sinch.push.socket.tests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = UserDefaultsSocketStateStore(defaults: defaults)
    let outbox = ReportOutbox(store: store, now: { 1_770_000_000_000 })
    outbox.enqueue(messageId: "m-1", subscriberId: "s-1")

    // A second store over the same defaults is what a relaunch looks like.
    let reloaded = ReportOutbox(
      store: UserDefaultsSocketStateStore(defaults: defaults), now: { 0 })

    XCTAssertEqual(reloaded.snapshot().count, 1)
    XCTAssertEqual(reloaded.snapshot().first?.messageId, "m-1")
    XCTAssertEqual(reloaded.snapshot().first?.subscriberId, "s-1")
    XCTAssertEqual(reloaded.snapshot().first?.enqueuedAtMs, 1_770_000_000_000)
  }

  // MARK: - The bridge surface

  func testSB67_theFacadeHandsTheQueuedReportsToJs() {
    let facade = SinchPushSocketFacade(
      store: FakeSocketStateStore(),
      tokenStore: InMemoryAuthTokenStore(),
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger(),
      scheduler: ManualScheduler())

    facade.shouldPresentPush(
      userInfo: [messageKey: "m-1", subscriberKey: "s-1"], requestIdentifier: "m-1")

    let entries = facade.reportOutboxEntries()
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0]["messageId"] as? String, "m-1")
    XCTAssertEqual(entries[0]["subscriberId"] as? String, "s-1")
    XCTAssertEqual((entries[0]["enqueuedAt"] as? NSNumber)?.int64Value, 1_770_000_000_000)

    facade.removeReportOutboxEntries([
      ["messageId": "m-1", "subscriberId": "s-1"] as NSDictionary,
    ])
    XCTAssertEqual(facade.reportOutboxEntries().count, 0)
  }

  func testSB67_theFacadeClearsTheWholeOutbox() {
    let facade = SinchPushSocketFacade(
      store: FakeSocketStateStore(),
      tokenStore: InMemoryAuthTokenStore(),
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger(),
      scheduler: ManualScheduler())

    facade.shouldPresentPush(
      userInfo: [messageKey: "m-1", subscriberKey: "s-1"], requestIdentifier: "m-1")
    facade.shouldPresentPush(
      userInfo: [messageKey: "m-2", subscriberKey: "s-1"], requestIdentifier: "m-2")
    XCTAssertEqual(facade.reportOutboxEntries().count, 2)

    facade.clearReportOutbox()

    XCTAssertEqual(facade.reportOutboxEntries().count, 0)
  }
}
