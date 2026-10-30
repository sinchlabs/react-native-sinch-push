//  PersistenceTests.swift — the store itself, and a relaunch (SB-28, SB-29,
//  SB-35, SB-18).
//
//  The socket suites use an in-memory store and hand the *same* instance to a
//  second client, which is how "survives a restart" is tested there. This file
//  covers the two things that fake cannot: that `UserDefaultsSocketStateStore`
//  actually round-trips every slice through JSON, and that a client built with
//  no configuration at all picks its session back up from the store plus the
//  token store — the relaunch path RN-008 cares about, where the app was
//  killed and relaunched by the user with no `startPushSocket` call.
//
//  `UserDefaults(suiteName:)` is used rather than `.standard` so a failing test
//  cannot leave state behind in the developer's own defaults, and the suite
//  domain is removed in `tearDown`.

import XCTest

@testable import SinchPushSocket

final class PersistenceTests: XCTestCase {
  private var suiteName: String = ""
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    try super.setUpWithError()
    suiteName = "com.sinch.push.socket.tests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
    super.tearDown()
  }

  // MARK: - The store

  func test_SB35_theOutboxRoundTripsThroughUserDefaults() {
    let store = UserDefaultsSocketStateStore(defaults: defaults)
    store.saveOutbox([
      PendingReport(
        messageId: "msg-1", sinchMessageId: "sinch-1", status: .dismissed,
        reason: "swiped", attempts: 2, deferUntilMs: 1_770_000_000_500),
      PendingReport(
        messageId: "msg-2", sinchMessageId: "sinch-2", status: .delivered,
        reason: "", attempts: 0, deferUntilMs: nil),
    ])

    // A second store over the same defaults is what a relaunch looks like.
    let reloaded = UserDefaultsSocketStateStore(defaults: defaults)
    XCTAssertEqual(reloaded.loadOutbox().count, 2)
    let first = try! XCTUnwrap(reloaded.loadOutbox().first)
    XCTAssertEqual(first.messageId, "msg-1")
    XCTAssertEqual(first.status, .dismissed)
    XCTAssertEqual(first.reason, "swiped")
    XCTAssertEqual(first.attempts, 2)
    // The deferral deadline has to survive: losing it would resend a report the
    // relay is still shedding.
    XCTAssertEqual(first.deferUntilMs, 1_770_000_000_500)
  }

  func test_SB28_theSeenSetAndTheSentSetRoundTripTogether() {
    let store = UserDefaultsSocketStateStore(defaults: defaults)
    store.saveSeenMessageIDs(["msg-1", "msg-2"])
    store.saveReportedKeys(["msg-1:1", "msg-1:2"])
    store.saveLastSeenMessageID("msg-2")

    let reloaded = UserDefaultsSocketStateStore(defaults: defaults)
    XCTAssertEqual(reloaded.loadSeenMessageIDs(), ["msg-1", "msg-2"])
    XCTAssertEqual(Set(reloaded.loadReportedKeys()), ["msg-1:1", "msg-1:2"])
    XCTAssertEqual(reloaded.loadLastSeenMessageID(), "msg-2")
  }

  func test_SB36_pendingMessagesRoundTripWithAbsentFieldsStillAbsent() throws {
    let store = UserDefaultsSocketStateStore(defaults: defaults)
    let blank = SocketMessageEvent(
      pooled: blankPooledMessage(messageID: "msg-1"), ackToken: "", receivedAt: 42)
    store.savePendingMessages([blank])

    let reloaded = UserDefaultsSocketStateStore(defaults: defaults)
    let message = try XCTUnwrap(reloaded.loadPendingMessages().first)
    XCTAssertEqual(message.id, "msg-1")
    XCTAssertNil(message.title, "an absent field came back as an empty one")
    XCTAssertNil(message.imageUrl)
    XCTAssertEqual(message.receivedAt, 42)
  }

  func test_SB18_theConfigurationRoundTripsWithoutTheToken() throws {
    let store = UserDefaultsSocketStateStore(defaults: defaults)
    store.saveConfiguration(testConfiguration(sdkVersion: "rn-sinch-push/1.1.0").persistable)

    let reloaded = UserDefaultsSocketStateStore(defaults: defaults)
    let persisted = try XCTUnwrap(reloaded.loadConfiguration())
    XCTAssertEqual(persisted.url, "ws://127.0.0.1:8080/ws")
    XCTAssertEqual(persisted.displayNotifications, "always")
    XCTAssertEqual(persisted.sdkVersion, "rn-sinch-push/1.1.0")
    // The token is not part of this shape at all: there is no field to leak it
    // into, which is why ``SocketConfiguration/persistable`` exists.
    let encoded = try JSONEncoder().encode(persisted)
    XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("jwt.token.value"))

    // Rebuilding from the store plus a token from the Keychain is the relaunch
    // path, and it must restore the session exactly.
    let rebuilt = persisted.configuration(authToken: "jwt.token.value")
    XCTAssertEqual(rebuilt, testConfiguration(sdkVersion: "rn-sinch-push/1.1.0"))
  }

  func test_SB18_anUnreadableSliceIsDroppedRatherThanFailingTheLaunch() {
    // A build that wrote a different shape, or a partially written value. The
    // worst case of dropping it is a re-delivered message, which the relay
    // tolerates; the worst case of keeping it is a state nothing can act on.
    defaults.set("not json at all".data(using: .utf8), forKey: "com.sinch.push.socket.outbox")

    let store = UserDefaultsSocketStateStore(defaults: defaults)
    XCTAssertEqual(store.loadOutbox().count, 0)
    XCTAssertEqual(store.loadSeenMessageIDs(), [])
    XCTAssertNil(store.loadConfiguration())
  }

  // MARK: - Relaunch

  func test_SB35_aRelaunchedClientResumesFromPersistedStateAndTheToken() throws {
    let store = UserDefaultsSocketStateStore(defaults: defaults)
    let tokenStore = InMemoryAuthTokenStore(token: "jwt.token.value")
    let factory = FakeSocketTransportFactory()
    let scheduler = ManualScheduler()

    // First run: start from a config the way the facade does, connect, and queue
    // a report the relay never answered.
    let first = SocketClient(
      configuration: testConfiguration(),
      transportFactory: factory,
      scheduler: scheduler,
      random: ScriptedRandomSource(fixed: 0.5),
      store: store,
      tokenStore: tokenStore,
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger())
    first.start()
    let socket = try XCTUnwrap(factory.sockets.last)
    socket.openSocket()
    var ack = Sinch_Push_Delivery_V1beta1_Ws_HelloAck()
    ack.connectionID = "conn-1"
    socket.deliver(ServerFrame(ack))
    first.report(messageId: "msg-1", status: .dismissed)
    first.stop()
    XCTAssertEqual(store.loadOutbox().count, 1)

    // Second run: no `startPushSocket` call at all — a relaunch that finds the
    // persisted config and the Keychain token, and comes back up.
    let second = SocketClient(
      configuration: nil,
      transportFactory: factory,
      scheduler: scheduler,
      random: ScriptedRandomSource(fixed: 0.5),
      store: store,
      tokenStore: tokenStore,
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger())
    second.start()

    let reopened = try XCTUnwrap(factory.sockets.last)
    XCTAssertEqual(reopened.connectCalls.count, 1)
    reopened.openSocket()
    XCTAssertEqual(reopened.hello?.authToken, "jwt.token.value",
      "the relaunched client did not pick up the token")
    XCTAssertEqual(
      reopened.connectCalls.first?.absoluteString, "ws://127.0.0.1:8080/ws",
      "the relaunched client did not pick up the persisted config")

    var secondAck = Sinch_Push_Delivery_V1beta1_Ws_HelloAck()
    secondAck.connectionID = "conn-2"
    reopened.deliver(ServerFrame(secondAck))

    // SB-35: the outbox goes out on the first handshake after the relaunch.
    XCTAssertEqual(reopened.reports.map(\.messageID), ["msg-1"])
    second.stop()
  }
}