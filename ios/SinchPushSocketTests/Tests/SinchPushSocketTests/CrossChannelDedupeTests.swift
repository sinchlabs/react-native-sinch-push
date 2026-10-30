//  CrossChannelDedupeTests.swift — one seen set for the socket, FCM and APNs
//  (RN-045, SB-28, SB-64, SB-65).
//
//  The registry is shared by construction: the client and the push path both go
//  through one `SeenMessageRegistry`, so these tests drive both halves over the
//  same instance and assert what the *other* one then does. The UserNotifications
//  parts (`willPresent`, the notification centre) are iOS-only and answered
//  through `PushPresentationDecider` and `DeliveredNotificationLookup`, which is
//  where their rules live.

import XCTest

@testable import SinchPushSocket

final class CrossChannelDedupeTests: XCTestCase {

  private let key = PushMessageIdentity.metadataKey

  // MARK: - The registry

  func test_SB64_markSeenIsTrueOnceAndFalseOnARepeat() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())

    XCTAssertTrue(registry.markSeen("m-1"))
    XCTAssertFalse(registry.markSeen("m-1"))
    XCTAssertTrue(registry.contains("m-1"))
    XCTAssertFalse(registry.contains("m-2"))
    XCTAssertFalse(registry.markSeen(""), "an empty id is never a message")
  }

  func test_SB28_theRegistryPersistsEveryNewIdUnderTheExistingKey() {
    let store = FakeSocketStateStore()
    let registry = SeenMessageRegistry(store: store)

    registry.markSeen("m-1")
    registry.markSeen("m-2")
    registry.markSeen("m-1")

    XCTAssertEqual(store.seen, ["m-1", "m-2"])
    XCTAssertEqual(SeenMessageRegistry(store: store).snapshot, ["m-1", "m-2"])
  }

  func test_SB28_anExistingFiveHundredSetLoadsIntoTheTwoThousandSet() {
    let old = (0..<500).map { "old-\($0)" }
    let store = FakeSocketStateStore(seen: old)
    let registry = SeenMessageRegistry(store: store)

    XCTAssertTrue(registry.contains("old-0"))
    XCTAssertTrue(registry.contains("old-499"))
    XCTAssertFalse(registry.markSeen("old-250"), "a migrated id still dedupes")

    // 1500 more fit before the first migrated id is evicted.
    for index in 0..<1500 { XCTAssertTrue(registry.markSeen("new-\(index)")) }
    XCTAssertEqual(registry.snapshot.count, 2000)
    XCTAssertTrue(registry.contains("old-0"))
    XCTAssertTrue(registry.markSeen("one-more"))
    XCTAssertFalse(registry.contains("old-0"))
  }

  func test_SB28_aStoreWrittenAtTheOldBoundIsNotRewrittenOnLoad() {
    let store = FakeSocketStateStore(seen: ["a", "b"])
    _ = SeenMessageRegistry(store: store).contains("a")
    XCTAssertEqual(store.seen, ["a", "b"])
  }

  func test_SB64_concurrentMarkSeenAdmitsEachIdExactlyOnce() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    let lock = NSLock()
    var admitted: [String: Int] = [:]

    // Eight threads race over the same 200 ids, four times each: the winner of
    // each id is whoever got the lock first, and there must be exactly one.
    DispatchQueue.concurrentPerform(iterations: 8) { _ in
      for _ in 0..<4 {
        for index in 0..<200 {
          let id = "m-\(index)"
          if registry.markSeen(id) {
            lock.lock()
            admitted[id, default: 0] += 1
            lock.unlock()
          }
        }
      }
    }

    XCTAssertEqual(admitted.count, 200)
    XCTAssertTrue(admitted.values.allSatisfy { $0 == 1 })
    XCTAssertEqual(registry.snapshot.count, 200)
  }

  // MARK: - Shared by the client and the push path

  func test_SB64_aMessageTheSocketDeliveredFirstIsASuppressedApnsCopy() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .never), registry: registry)
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "m-1"))
    XCTAssertEqual(harness.deliveredMessageIDs, ["m-1"])

    let decision = PushPresentationDecider(registry: registry)
      .decide(userInfo: [key: "m-1"], requestIdentifier: "m-1")

    XCTAssertEqual(decision, .suppress)
  }

  func test_SB64_aMessageApnsDeliveredFirstIsADedupeHitForTheSocket() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    let decider = PushPresentationDecider(registry: registry)
    XCTAssertEqual(decider.decide(userInfo: [key: "m-1"], requestIdentifier: "x"), .present)

    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      presenter: presenter, registry: registry)
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "m-1"))

    // RN-049: the dedupe suppressed the event and the notification, not the
    // ack. This socket was handed the message and the relay is waiting for its
    // DELIVERED, so the report goes out.
    XCTAssertEqual(harness.deliveredMessageIDs, [])
    XCTAssertEqual(harness.reports(.delivered).map(\.messageID), ["m-1"])
    XCTAssertEqual(presenter.posted.count, 0)
  }

  func test_SB64_aClientBuiltWithoutARegistryStillDedupesOverItsOwnStore() {
    let store = FakeSocketStateStore()
    let first = makeHarness(
      configuration: testConfiguration(displayNotifications: .never), store: store)
    first.handshake()
    first.deliverMessage(pooledMessage(messageID: "m-1"))
    XCTAssertEqual(store.seen, ["m-1"])

    let second = makeHarness(
      configuration: testConfiguration(displayNotifications: .never), store: store)
    second.handshake()
    second.deliverMessage(pooledMessage(messageID: "m-1"))
    XCTAssertEqual(second.deliveredMessageIDs, [])
  }

  // MARK: - RN-049 the dedupe suppresses the presentation, never the ack

  /// The failure RN-049 exists to stop: the relay handed this message to the
  /// socket and waits 3 s for DELIVERED before it falls back to APNs. If a hit
  /// stayed silent the relay books an ACK_TIMEOUT and sinch-push sends the same
  /// message again — even though APNs already delivered it.
  func test_RN049_aMessageApnsMarkedFirstIsStillAckedOnceOverTheSocket() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    XCTAssertEqual(
      PushPresentationDecider(registry: registry)
        .decide(userInfo: [key: "m-1"], requestIdentifier: "u"),
      .present)
    XCTAssertTrue(registry.contains("m-1"), "the APNs path marked it")

    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      presenter: presenter, registry: registry)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "m-1"))

    XCTAssertEqual(harness.reports(.delivered).map(\.messageID), ["m-1"], "one DELIVERED went out")
    XCTAssertEqual(harness.reports.count, 1, "and nothing else")
    // Presentation stays suppressed: the id already went through `willPresent`.
    XCTAssertEqual(harness.deliveredMessageIDs, [])
    XCTAssertEqual(presenter.posted.count, 0)
  }

  func test_RN049_aSocketDuplicateIsAckedOnlyOnce() {
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .never))
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "m-1"))
    harness.deliverMessage(pooledMessage(messageID: "m-1"))

    // SB-30 is what holds this line: one DELIVERED per `(message_id, status)`.
    XCTAssertEqual(harness.reports(.delivered).map(\.messageID), ["m-1"])
    XCTAssertEqual(harness.reports.count, 1)
    XCTAssertEqual(harness.deliveredMessageIDs, ["m-1"])
  }

  // MARK: - willPresent (PushPresentationDecider)

  func test_SB64_aSocketOriginatedNotificationPassesThroughAndIsNotMarked() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    // The socket marks the id before it presents, so the registry already has it.
    registry.markSeen("m-1")
    let decider = PushPresentationDecider(registry: registry)

    let decision = decider.decide(
      userInfo: [key: "m-1", "source": "socket", "messageId": "m-1"], requestIdentifier: "m-1")

    XCTAssertEqual(decision, .present)
  }

  func test_SB64_aSeenApnsMessageIsSuppressed() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    registry.markSeen("m-1")

    XCTAssertEqual(
      PushPresentationDecider(registry: registry)
        .decide(userInfo: [key: "m-1"], requestIdentifier: "ignored"),
      .suppress)
  }

  func test_SB64_anUnseenApnsMessageIsMarkedAndPresentedOnce() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    let decider = PushPresentationDecider(registry: registry)

    XCTAssertEqual(decider.decide(userInfo: [key: "m-1"], requestIdentifier: "u"), .present)
    XCTAssertTrue(registry.contains("m-1"))
    XCTAssertEqual(decider.decide(userInfo: [key: "m-1"], requestIdentifier: "u"), .suppress)
  }

  func test_SB64_aPushWithoutAnIdIsNeverDeduped() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    let decider = PushPresentationDecider(registry: registry)

    XCTAssertEqual(decider.decide(userInfo: ["aps": ["alert": "hi"]], requestIdentifier: "abc"), .present)
    XCTAssertEqual(decider.decide(userInfo: ["aps": ["alert": "hi"]], requestIdentifier: "abc"), .present)
    XCTAssertEqual(registry.snapshot, [])
  }

  func test_SB64_theRequestIdentifierIsTheFallbackOnlyForARecognisableSinchPush() {
    let sinch: [AnyHashable: Any] = ["sinch.push.subscriber_id": "s-1"]

    XCTAssertEqual(
      PushMessageIdentity.messageId(userInfo: sinch, requestIdentifier: "m-1"), "m-1")
    // Not a Sinch push: someone else's identifier means nothing to us.
    XCTAssertNil(PushMessageIdentity.messageId(userInfo: [:], requestIdentifier: "m-1"))
    // A system-assigned UUID identifier is not a message id.
    XCTAssertNil(
      PushMessageIdentity.messageId(
        userInfo: sinch, requestIdentifier: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
    XCTAssertNil(PushMessageIdentity.messageId(userInfo: sinch, requestIdentifier: ""))
    // The metadata key wins over the identifier.
    XCTAssertEqual(
      PushMessageIdentity.messageId(
        userInfo: [key: "m-2"], requestIdentifier: "m-1"), "m-2")
  }

  // MARK: - didReceiveRemoteNotification

  func test_SB64_aBackgroundPushIsMarkedSoTheSocketsCopyIsADuplicate() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    let decider = PushPresentationDecider(registry: registry)

    let decision = decider.decideRemoteNotification(
      userInfo: [key: "m-1", "aps": ["alert": "hi"]], appIsActive: false)

    XCTAssertEqual(decision, .present)
    XCTAssertTrue(registry.contains("m-1"))
  }

  func test_SB64_anUnseenActiveAppsAlertPushIsLeftToWillPresentAndNotMarked() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    let decider = PushPresentationDecider(registry: registry)
    let info: [AnyHashable: Any] = [key: "m-1", "aps": ["alert": ["title": "t"]]]

    // Marking it here would make `willPresent` swallow the only copy.
    XCTAssertEqual(decider.decideRemoteNotification(userInfo: info, appIsActive: true), .present)
    XCTAssertFalse(registry.contains("m-1"))
    XCTAssertEqual(decider.decide(userInfo: info, requestIdentifier: "m-1"), .present)
  }

  func test_SB64_anActiveAppsAlertPushTheSocketAlreadyDeliveredIsACopyAndEmitsNothing() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .never), registry: registry)
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "m-1"))
    XCTAssertTrue(registry.contains("m-1"))

    // `+didReceiveRemoteNotification:` would otherwise post onPushReceived for it.
    let decision = PushPresentationDecider(registry: registry).decideRemoteNotification(
      userInfo: [key: "m-1", "aps": ["alert": "hi"]], appIsActive: true)

    XCTAssertEqual(decision, .suppress)
    XCTAssertEqual(registry.snapshot, ["m-1"], "looked up, not re-marked")
  }

  func test_SB64_aSilentPushInTheForegroundIsMarked() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    let decider = PushPresentationDecider(registry: registry)

    _ = decider.decideRemoteNotification(
      userInfo: [key: "m-1", "aps": ["content-available": 1]], appIsActive: true)

    XCTAssertTrue(registry.contains("m-1"))
  }

  func test_SB64_aSeenBackgroundPushIsACopyAndEmitsNothing() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    registry.markSeen("m-1")

    XCTAssertEqual(
      PushPresentationDecider(registry: registry)
        .decideRemoteNotification(userInfo: [key: "m-1"], appIsActive: false),
      .suppress)
  }

  func test_SB64_aBackgroundPushWithoutAnIdIsLeftAlone() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    XCTAssertEqual(
      PushPresentationDecider(registry: registry)
        .decideRemoteNotification(userInfo: ["aps": ["content-available": 1]], appIsActive: false),
      .present)
    XCTAssertEqual(registry.snapshot, [])
  }

  // MARK: - SB-65 notification identity and the delivered-notification check

  func test_SB65_theSocketNotificationIdentifierIsTheMessageId() {
    XCTAssertEqual(socketNotificationIdentifier(messageId: "m-1"), "m-1")
    XCTAssertEqual(socketNotificationIdentifier(messageId: "a:b:c"), "a:b:c")
  }

  func test_SB65_aMessageAlreadyInTheNotificationCentreIsNotPostedAgain() {
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let delivered = FakeDeliveredNotifications()
    delivered.delivered = ["m-1"]
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      presenter: presenter, delivered: delivered)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "m-1"))

    XCTAssertEqual(delivered.asked, ["m-1"])
    XCTAssertEqual(presenter.posted.count, 0, "the APNs copy is on screen already")
    // Handled like any new message: event and DELIVERED stay (SB-27, SB-62) ...
    XCTAssertEqual(harness.deliveredMessageIDs, ["m-1"])
    XCTAssertEqual(harness.reports(.delivered).count, 1)
    // ... but nothing was posted, so DISPLAYED is not claimed.
    XCTAssertEqual(harness.reports(.displayed).count, 0)
    XCTAssertTrue(harness.logger.contains("already in the notification centre"))
  }

  func test_SB65_aMessageNotInTheNotificationCentreIsPostedAndDisplayed() {
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let delivered = FakeDeliveredNotifications()
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      presenter: presenter, delivered: delivered)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "m-1"))

    XCTAssertEqual(delivered.asked, ["m-1"])
    XCTAssertEqual(presenter.posted.map(\.id), ["m-1"])
    XCTAssertEqual(harness.reports(.displayed).count, 1)
  }

  func test_SB65_theLookupIsNotConsultedWhenNothingWouldBePosted() {
    let delivered = FakeDeliveredNotifications()
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .never), delivered: delivered)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "m-1"))

    XCTAssertEqual(delivered.asked, [])
  }

  func test_SB65_anAsynchronousLookupDelaysOnlyThePost() {
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let delivered = FakeDeliveredNotifications()
    delivered.answersInline = false
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      presenter: presenter, delivered: delivered)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "m-1"))

    // Event and DELIVERED do not wait for the notification centre (SB-62).
    XCTAssertEqual(harness.deliveredMessageIDs, ["m-1"])
    XCTAssertEqual(harness.reports(.delivered).count, 1)
    XCTAssertEqual(presenter.posted.count, 0)

    delivered.flush()
    XCTAssertEqual(presenter.posted.map(\.id), ["m-1"])
  }

  func test_SB65_aSkippedPostDoesNotSpendTheAlertWindow() {
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let delivered = FakeDeliveredNotifications()
    delivered.delivered = ["m-1"]
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      presenter: presenter, delivered: delivered)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "m-1"))
    harness.deliverMessage(pooledMessage(messageID: "m-2"))

    XCTAssertEqual(presenter.posted.map(\.id), ["m-2"])
    XCTAssertEqual(presenter.postedAlerting, [true])
  }

  // MARK: - SB-29 a hit on an id another channel saw still advances the cursor

  func test_SB29_anIdApnsSawAdvancesTheCursorWhenItArrivesOverTheSocket() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    _ = PushPresentationDecider(registry: registry)
      .decide(userInfo: [key: "m-1"], requestIdentifier: "x")
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      presenter: presenter, registry: registry)
    harness.handshake()

    harness.deliverMessage(pooledMessage(messageID: "m-1", enqueuedAt: 5_000))

    XCTAssertEqual(harness.store.lastSeen, "m-1")
    XCTAssertEqual(harness.store.lastSeenEnqueuedAt, 5_000)
    // RN-049: the cursor moved, the ack went out, the presentation did not.
    XCTAssertEqual(harness.deliveredMessageIDs, [])
    XCTAssertEqual(harness.reports(.delivered).map(\.messageID), ["m-1"])
    XCTAssertEqual(presenter.posted.count, 0)
  }

  func test_SB29_aHitOnAnOlderIdDoesNotWalkTheCursorBack() {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    registry.markSeen("m-1")
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .never), registry: registry)
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "m-2", enqueuedAt: 9_000))

    harness.deliverMessage(pooledMessage(messageID: "m-1", enqueuedAt: 1_000))

    XCTAssertEqual(harness.store.lastSeen, "m-2")
  }

  /// Cursor at m-2/9_000, then a hit on an already-seen m-1 carrying `hitAt`.
  private func cursorAfterAHit(at hitAt: Int64) -> (String, Int64) {
    let registry = SeenMessageRegistry(store: FakeSocketStateStore())
    registry.markSeen("m-1")
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .never), registry: registry)
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "m-2", enqueuedAt: 9_000))
    harness.deliverMessage(pooledMessage(messageID: "m-1", enqueuedAt: hitAt))
    return (harness.store.lastSeen, harness.store.lastSeenEnqueuedAt)
  }

  func test_SB29_aHitWithAnUnknownTimestampDoesNotMoveTheCursor() {
    let cursor = cursorAfterAHit(at: 0)
    XCTAssertEqual(cursor.0, "m-2")
    XCTAssertEqual(cursor.1, 9_000)
  }

  func test_SB29_aHitWithAnEqualTimestampDoesNotMoveTheCursor() {
    let cursor = cursorAfterAHit(at: 9_000)
    XCTAssertEqual(cursor.0, "m-2")
    XCTAssertEqual(cursor.1, 9_000)
  }

  func test_SB29_aHitWithAStrictlyNewerTimestampMovesTheCursor() {
    let cursor = cursorAfterAHit(at: 9_001)
    XCTAssertEqual(cursor.0, "m-1")
    XCTAssertEqual(cursor.1, 9_001)
  }

  // MARK: - SB-65 the lookup answers after the client was stopped

  func test_SB65_aLookupThatAnswersAfterStopPostsNothingAndReportsNoDisplayed() {
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let delivered = FakeDeliveredNotifications()
    delivered.answersInline = false
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      presenter: presenter, delivered: delivered)
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "m-1"))
    XCTAssertEqual(delivered.asked, ["m-1"])

    harness.client.stop()
    delivered.flush()

    XCTAssertEqual(presenter.posted.count, 0)
    XCTAssertEqual(harness.reports(.displayed).count, 0)
  }

  func test_SB65_aLookupThatAnswersAfterAReconfigurePostsNothing() {
    let presenter = FakeNotificationPresenter()
    presenter.acceptsPost = true
    let delivered = FakeDeliveredNotifications()
    delivered.answersInline = false
    let harness = makeHarness(
      configuration: testConfiguration(displayNotifications: .always),
      presenter: presenter, delivered: delivered)
    harness.handshake()
    harness.deliverMessage(pooledMessage(messageID: "m-1"))

    harness.client.updateConfiguration(testConfiguration(displayNotifications: .always))
    delivered.flush()

    XCTAssertEqual(presenter.posted.count, 0)
    XCTAssertEqual(harness.reports(.displayed).count, 0)
  }
}
