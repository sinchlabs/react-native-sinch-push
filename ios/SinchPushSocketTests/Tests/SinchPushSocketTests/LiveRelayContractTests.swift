//  LiveRelayContractTests.swift — SB-58: the shipped Swift client against a
//  real `deliveryd` and `report-sink-stub`, over the real
//  URLSessionWebSocketTransport.
//
//  Golden vectors prove the bytes; this proves behaviour: a push arrives
//  unprompted, the report Ack is accepted, the report lands in the upstream sink,
//  SIGTERM lets the client come back, and a DISMISSED raised while disconnected
//  survives. Opt-in (`npm run contract:ios`, RELAY_CONTRACT=1) because it binds
//  real ports; skips with a message when the relay binaries are missing. The core
//  is platform-neutral, so a macOS host run is a faithful driver.

import XCTest

@testable import SinchPushSocket

final class LiveRelayContractTests: XCTestCase {

  private static var relay: RelayHarness?
  private static var skipReason = ""

  private let appID = "contract-app"

  override class func setUp() {
    super.setUp()
    let (harness, why) = RelayHarness.locate()
    guard let harness else {
      skipReason = why
      return
    }
    do {
      try harness.start()
      relay = harness
    } catch {
      harness.stop()
      skipReason = "relay failed to start: \(error)"
      failedStart = "\(error)"
    }
  }

  private static var failedStart: String?

  override class func tearDown() {
    relay?.stop()
    relay = nil
    super.tearDown()
  }

  private func requireRelay() throws -> RelayHarness {
    if let failed = Self.failedStart { XCTFail(failed) }
    guard let relay = Self.relay else { throw XCTSkip("live relay contract skipped: \(Self.skipReason)") }
    return relay
  }

  // MARK: - A live client

  private final class Live {
    private let lock = NSLock()
    private var _states: [SocketState] = []
    private var _messages: [SocketMessageEvent] = []
    private var _logs: [String] = []
    let client: SocketClient

    var states: [SocketState] { lock.lock(); defer { lock.unlock() }; return _states }
    var messages: [SocketMessageEvent] { lock.lock(); defer { lock.unlock() }; return _messages }
    var logs: [String] { lock.lock(); defer { lock.unlock() }; return _logs }
    var state: SocketState? { states.last }
    var connected: Bool { state?.status == .connected }

    private final class LockedLogger: SocketLogger {
      let sink: (String) -> Void
      init(_ sink: @escaping (String) -> Void) { self.sink = sink }
      func log(_ line: String) { sink(line) }
    }

    /// `store` shared between two instances is the "same store" of a restart (SB-28, SB-29);
    /// the default device-info provider carries no installation id, i.e. a legacy client (SB-59).
    init(
      relay: RelayHarness, appID: String, userID: String,
      store: InMemorySocketStateStore = InMemorySocketStateStore(),
      deviceInfo: DeviceInfoProviding = StaticDeviceInfoProvider(),
      seenRegistry: SeenMessageRegistry? = nil
    ) {
      let configuration = SocketConfiguration(
        url: relay.wsURL, authToken: "dev-token", projectID: "contract-project",
        appID: appID, userID: userID, pollIntervalMs: 0, displayNotifications: .never,
        sdkVersion: "rn-sinch-push-contract/1.0.0")
      var callbacks = SocketClient.Callbacks()
      let box = Box()
      let logger = LockedLogger { box.append(log: $0) }
      client = SocketClient(
        configuration: configuration,
        transportFactory: URLSessionWebSocketTransportFactory(),
        scheduler: DispatchScheduler(),
        random: SystemRandomSource(),
        store: store,
        tokenStore: InMemoryAuthTokenStore(token: "dev-token"),
        logger: logger,
        deviceInfo: deviceInfo,
        seenRegistry: seenRegistry)
      callbacks.onState = { box.append(state: $0) }
      callbacks.onMessage = { box.append(message: $0) }
      callbacks.onLog = { box.append(log: $0) }
      client.setCallbacks(callbacks)
      box.owner = self
    }

    /// Callbacks arrive on the scheduler's queue; this funnels them under a lock.
    final class Box {
      weak var owner: Live?
      func append(state: SocketState) { owner.map { l in l.lock.lock(); l._states.append(state); l.lock.unlock() } }
      func append(message: SocketMessageEvent) { owner.map { l in l.lock.lock(); l._messages.append(message); l.lock.unlock() } }
      func append(log: String) { owner.map { l in l.lock.lock(); l._logs.append(log); l.lock.unlock() } }
    }
  }

  private func withClient(
    _ relay: RelayHarness, user: String, _ body: (Live) throws -> Void
  ) rethrows {
    let live = Live(relay: relay, appID: appID, userID: user)
    live.client.start()
    defer { live.client.stop(); Thread.sleep(forTimeInterval: 0.1) }
    try body(live)
  }

  /// Fails the test on timeout and returns whether the predicate held, so a caller
  /// whose next step needs the precondition can stop instead of cascading.
  @discardableResult
  private func waitFor(
    _ timeout: TimeInterval, _ what: String, extra: () -> String = { "" },
    file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() { return true }
      Thread.sleep(forTimeInterval: 0.02)
    }
    XCTFail("timed out after \(timeout)s waiting for \(what)\n\(extra())", file: file, line: line)
    return false
  }

  private func uniqueUser(_ tag: String) -> String { "contract-user-\(tag)-\(DispatchTime.now().uptimeNanoseconds)" }

  // MARK: - Scenarios

  func test_SB58_handshakeWithin2sLearnsTheSessionParameters() throws {
    let relay = try requireRelay()
    withClient(relay, user: uniqueUser("hs")) { live in
      let started = Date()
      waitFor(2, "connected within 2 s", extra: { relay.relayTail() }) { live.connected }
      XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 2.5)
      XCTAssertFalse(live.state?.connectionId.isEmpty ?? true)
      XCTAssertGreaterThan(live.state?.pollIntervalMs ?? 0, 0)
      XCTAssertTrue(live.states.contains { $0.status == .connecting })
    }
  }

  func test_SB58_anEnqueuedMessageIsPushedWithoutAPoll() throws {
    let relay = try requireRelay()
    let user = uniqueUser("push")
    let sinchID = "contract-push-\(DispatchTime.now().uptimeNanoseconds)"
    try withClient(relay, user: user) { live in
      waitFor(10, "connected", extra: { relay.relayTail() }) { live.connected }
      try relay.enqueue(
        appID: appID, userID: user, sinchMessageID: sinchID, title: "Hello from SDK contract",
        body: "contract body")
      // Strictly shorter than one poll interval, so a coincidental poll cannot pass this.
      XCTAssertGreaterThan(live.state?.pollIntervalMs ?? 0, 1000)
      waitFor(1, "push delivery within 1 s of enqueue", extra: { relay.relayTail() }) { !live.messages.isEmpty }
      guard let message = live.messages.first else { return }
      XCTAssertEqual(message.sinchMessageId, sinchID)
      XCTAssertEqual(message.title, "Hello from SDK contract")
      XCTAssertEqual(message.body, "contract body")
      XCTAssertEqual(message.ackToken, message.id)
      XCTAssertFalse(message.id.isEmpty)
    }
  }

  func test_SB58_exactlyOneDeliveredReachesTheSinkWithAnAcceptedAckAndACorrelatedChannelID() throws {
    let relay = try requireRelay()
    let user = uniqueUser("delivered")
    let sinchID = "contract-report-\(DispatchTime.now().uptimeNanoseconds)"
    try withClient(relay, user: user) { live in
      waitFor(10, "connected", extra: { relay.relayTail() }) { live.connected }
      try relay.enqueue(appID: appID, userID: user, sinchMessageID: sinchID, title: "report correlation")
      waitFor(10, "the report to reach the sink", extra: { relay.sinkTail() + relay.relayTail() }) {
        relay.sinkReports().contains { $0.sinchMessageID == sinchID }
      }
      // Give a poll tick or a redelivery the chance to produce a duplicate.
      Thread.sleep(forTimeInterval: 1)
      let reports = relay.sinkReports().filter { $0.sinchMessageID == sinchID }
      XCTAssertEqual(reports.count, 1, "\(reports)")
      XCTAssertEqual(reports.first?.status, "DELIVERED")

      let delivered = live.messages.first { $0.sinchMessageId == sinchID }
      XCTAssertNotNil(delivered)
      let channelID = reports.first?.channelMessageID ?? ""
      // SB-37's four parts: present, equals the delivered id, is not the
      // Sinch id, and equals the Ack token.
      XCTAssertFalse(channelID.isEmpty, "channel_message_id missing upstream")
      XCTAssertEqual(channelID, delivered?.id)
      XCTAssertNotEqual(channelID, sinchID)
      XCTAssertEqual(channelID, delivered?.ackToken)

      waitFor(5, "the report Ack", extra: { live.logs.joined(separator: "\n") }) {
        live.logs.contains { $0.contains("ack accepted=true") }
      }
      XCTAssertFalse(live.logs.contains { $0.contains("ack accepted=false") })
    }
  }

  func test_SB58_displayedAndDismissedReachTheSinkAfterReport() throws {
    let relay = try requireRelay()
    let user = uniqueUser("status")
    let sinchID = "contract-status-\(DispatchTime.now().uptimeNanoseconds)"
    try withClient(relay, user: user) { live in
      waitFor(10, "connected", extra: { relay.relayTail() }) { live.connected }
      try relay.enqueue(appID: appID, userID: user, sinchMessageID: sinchID, title: "status")
      waitFor(10, "message", extra: { relay.relayTail() }) { !live.messages.isEmpty }
      guard let id = live.messages.first?.id else { return }
      live.client.report(messageId: id, status: .displayed)
      live.client.report(messageId: id, status: .dismissed)
      waitFor(10, "DISPLAYED and DISMISSED at the sink", extra: { relay.sinkTail() }) {
        let statuses = relay.sinkReports().filter { $0.sinchMessageID == sinchID }.map(\.status)
        return statuses.contains("DISPLAYED") && statuses.contains("DISMISSED")
      }
      let reports = relay.sinkReports().filter { $0.sinchMessageID == sinchID }
      XCTAssertEqual(reports.count, 3, "\(reports)")
      XCTAssertTrue(reports.allSatisfy { $0.channelMessageID == id })
    }
  }

  func test_SB58_reconnectsWithANewSessionAfterSIGTERM() throws {
    let relay = try requireRelay()
    try withClient(relay, user: uniqueUser("sigterm")) { live in
      waitFor(10, "connected", extra: { relay.relayTail() }) { live.connected }
      let first = live.state?.connectionId ?? ""
      XCTAssertFalse(first.isEmpty)

      try relay.sigtermRelayAndAwaitExit()
      waitFor(10, "the client to notice the shutdown", extra: { "\(live.states)" }) {
        live.states.contains { $0.status == .reconnecting }
      }
      // Respawn on process exit, not on the signal (the relay holds its ports while draining).
      try relay.startRelay()
      waitFor(30, "a reconnect with a fresh connection id", extra: {
        "\(live.states)\n\(live.logs.joined(separator: "\n"))\n\(relay.relayTail(30))"
      }) { live.connected && live.state?.connectionId != first }
      XCTAssertNotEqual(live.state?.connectionId, first)
      XCTAssertEqual(live.state?.status, .connected)
    }
  }

  func test_SB58_aDismissedRaisedWhileDisconnectedArrivesAfterTheReconnect() throws {
    let relay = try requireRelay()
    let user = uniqueUser("outbox")
    let sinchID = "contract-outbox-\(DispatchTime.now().uptimeNanoseconds)"
    try withClient(relay, user: user) { live in
      waitFor(10, "connected", extra: { relay.relayTail() }) { live.connected }
      try relay.enqueue(appID: appID, userID: user, sinchMessageID: sinchID, title: "outbox")
      waitFor(10, "message", extra: { relay.relayTail() }) { !live.messages.isEmpty }
      guard let id = live.messages.first?.id else { return }
      waitFor(10, "DELIVERED at the sink", extra: { relay.sinkTail() }) {
        relay.sinkReports().contains { $0.sinchMessageID == sinchID && $0.status == "DELIVERED" }
      }

      try relay.sigtermRelayAndAwaitExit()
      waitFor(10, "the client to notice the shutdown", extra: { "\(live.states)" }) { !live.connected }
      live.client.report(messageId: id, status: .dismissed)
      Thread.sleep(forTimeInterval: 0.3)
      XCTAssertFalse(
        relay.sinkReports().contains { $0.sinchMessageID == sinchID && $0.status == "DISMISSED" },
        "nothing may reach the sink while the relay is down")

      try relay.startRelay()
      waitFor(30, "the outboxed DISMISSED at the sink", extra: { relay.sinkTail() + "\n" + live.logs.joined(separator: "\n") }) {
        relay.sinkReports().contains { $0.sinchMessageID == sinchID && $0.status == "DISMISSED" }
      }
      let dismissed = relay.sinkReports().filter { $0.sinchMessageID == sinchID && $0.status == "DISMISSED" }
      XCTAssertEqual(dismissed.count, 1)
      XCTAssertEqual(dismissed.first?.channelMessageID, id)
    }
  }

  func test_SB58_aHelloCarryingTheFullDeviceInfoIsAcceptedAndTheRelayRegistersTheInstallation() throws {
    let relay = try requireRelay()
    let user = uniqueUser("devinfo")
    let installationID = UUID().uuidString.lowercased()
    // The shipped provider over fake reads (SB-59, SB-60): iOS reports UNSUPPORTED.
    final class Counter: @unchecked Sendable {
      private let lock = NSLock()
      private var value = 0
      func increment() { lock.lock(); value += 1; lock.unlock() }
      var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    let installationIDCalls = Counter()
    let deviceInfo = SystemDeviceInfoProvider(
      installationId: { installationIDCalls.increment(); return installationID },
      osVersion: { "17.5.1" },
      bundleId: { "com.example.contract" },
      relaySwitch: InMemoryRelaySwitchStore(enabled: true))
    let live = Live(relay: relay, appID: appID, userID: user, deviceInfo: deviceInfo)
    live.client.start()
    defer { live.client.stop(); Thread.sleep(forTimeInterval: 0.1) }

    let started = Date()
    waitFor(2, "connected within 2 s", extra: { relay.relayTail() + "\n" + live.logs.joined(separator: "\n") }) {
      live.connected
    }
    XCTAssertLessThanOrEqual(Date().timeIntervalSince(started), 2.5)
    let connectionID = live.state?.connectionId ?? ""
    XCTAssertFalse(connectionID.isEmpty)
    XCTAssertGreaterThan(live.state?.pollIntervalMs ?? 0, 0)
    XCTAssertEqual(installationIDCalls.count, 1)

    // The relay logs `registered` with the installation id it parsed from the
    // Hello, after it has already sent the HelloAck, hence the wait.
    waitFor(5, "the relay to register the session", extra: { relay.relayTail() }) {
      relay.relayEvents("registered").contains { $0["connection_id"] as? String == connectionID }
    }
    let registered = relay.relayEvents("registered").first { $0["connection_id"] as? String == connectionID }
    XCTAssertEqual(registered?["installation_id"] as? String, installationID)
    XCTAssertEqual(registered?["key"] as? String, "sess:\(appID):\(user):\(installationID)")
    XCTAssertTrue(
      relay.relayEvents("ws hello refused: installation_id must be a canonical uuid").isEmpty,
      "a refused Hello would have been logged")
  }

  func test_SB58_afterARestartOverTheSameStoreOnlyTheMessagesMissedWhileDisconnectedAreEmittedOnceEach() throws {
    let relay = try requireRelay()
    let user = uniqueUser("replay")
    let store = InMemorySocketStateStore()
    let stamp = DispatchTime.now().uptimeNanoseconds
    let a = "contract-replay-a-\(stamp)"
    let b = "contract-replay-b-\(stamp)"
    let c = "contract-replay-c-\(stamp)"

    // Legacy key (empty installation_id): plain `enqueue`, no `-installation`; the per-installation case is below.
    let first = Live(relay: relay, appID: appID, userID: user, store: store)
    first.client.start()
    // A thrown enqueue must not leave the first client connected.
    defer { first.client.stop() }
    waitFor(10, "connected", extra: { relay.relayTail() }) { first.connected }
    try relay.enqueue(appID: appID, userID: user, sinchMessageID: a, title: "A")
    // Pushed, not polled: the poll interval is 5 s.
    XCTAssertGreaterThan(first.state?.pollIntervalMs ?? 0, 2000)
    waitFor(2, "A pushed within 2 s", extra: { relay.relayTail() }) { !first.messages.isEmpty }
    XCTAssertEqual(first.messages.map(\.sinchMessageId), [a])
    let firstMessage = try XCTUnwrap(first.messages.first)
    waitFor(10, "DELIVERED for A at the sink", extra: { relay.sinkTail() }) {
      relay.sinkReports().contains { $0.sinchMessageID == a && $0.status == "DELIVERED" }
    }
    let firstConnection = first.states.last { !$0.connectionId.isEmpty }?.connectionId ?? ""
    XCTAssertFalse(firstConnection.isEmpty)
    first.client.stop()
    waitFor(5, "the first client to stop", extra: { "\(first.states)" }) { first.state?.status == .stopped }
    // The relay must have dropped the session before B is enqueued, or B would be
    // pushed into the closing socket instead of waiting in the pool.
    guard waitFor(10, "the relay to unregister the first connection", extra: { relay.relayTail() }, {
      relay.relayEvents("unregistered").contains { $0["connection_id"] as? String == firstConnection }
    }) else { return }

    try relay.enqueue(appID: appID, userID: user, sinchMessageID: b, title: "B")
    try relay.enqueue(appID: appID, userID: user, sinchMessageID: c, title: "C")
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertEqual(first.messages.count, 1, "a stopped client emits nothing")

    // A new client over the same persisted store: seen set and cursor survive.
    // The relay's hello-replay is a no-op for the legacy key, so B and C arrive
    // with the immediate Poll after HelloAck, and A may come along with them (the
    // pool is not emptied by a push): the seen set must swallow it.
    let second = Live(relay: relay, appID: appID, userID: user, store: store)
    second.client.start()
    defer { second.client.stop(); Thread.sleep(forTimeInterval: 0.1) }
    waitFor(20, "B and C emitted after the restart", extra: {
      second.logs.joined(separator: "\n") + "\n" + relay.relayTail(30)
    }) { second.messages.count >= 2 }
    XCTAssertEqual(second.messages.map(\.sinchMessageId), [b, c])
    waitFor(10, "DELIVERED for B and C at the sink", extra: { relay.sinkTail() }) {
      let delivered = relay.sinkReports().filter { $0.status == "DELIVERED" }.map(\.sinchMessageID)
      return delivered.contains(b) && delivered.contains(c)
    }
    // More than one poll interval (5 s): catches a late duplicate event or report
    // (the legacy first Poll already drained the pool).
    Thread.sleep(forTimeInterval: 6)

    XCTAssertEqual(second.messages.map(\.sinchMessageId), [b, c], "exactly B and C, in order, A not again")
    XCTAssertTrue(
      second.logs.contains { $0.contains("duplicate message \(firstMessage.id)") },
      "the relay re-sent A and the seen set swallowed it")
    XCTAssertEqual(first.messages.map(\.sinchMessageId), [a], "A was emitted once, by the first client")
    for id in [a, b, c] {
      let reports = relay.sinkReports().filter { $0.sinchMessageID == id }
      XCTAssertEqual(reports.map(\.status), ["DELIVERED"], "\(reports)")
    }
  }

  /// The push-path decider over the registry the client marks, as the facade wires them.
  private func providerPushDecider(
    store: InMemorySocketStateStore, registry: SeenMessageRegistry
  ) -> (decider: PushPresentationDecider, outbox: ReportOutbox) {
    let outbox = ReportOutbox(store: store, now: { Int64(Date().timeIntervalSince1970 * 1000) })
    return (PushPresentationDecider(registry: registry, outbox: outbox), outbox)
  }

  func test_SB67_theProviderCopyOfASocketDeliveredMessageIsSuppressedAndNothingIsQueued() throws {
    let relay = try requireRelay()
    let user = uniqueUser("providercopy")
    let sinchID = "contract-provider-copy-\(DispatchTime.now().uptimeNanoseconds)"
    let store = InMemorySocketStateStore()
    let registry = SeenMessageRegistry(store: store)
    let (decider, outbox) = providerPushDecider(store: store, registry: registry)
    let live = Live(relay: relay, appID: appID, userID: user, store: store, seenRegistry: registry)
    live.client.start()
    defer { live.client.stop(); Thread.sleep(forTimeInterval: 0.1) }
    waitFor(10, "connected", extra: { relay.relayTail() }) { live.connected }
    try relay.enqueue(appID: appID, userID: user, sinchMessageID: sinchID, title: "provider copy")
    waitFor(10, "the message over the socket", extra: { relay.relayTail() }) { !live.messages.isEmpty }
    waitFor(5, "the report Ack", extra: { live.logs.joined(separator: "\n") }) {
      live.logs.contains { $0.contains("ack accepted=true") }
    }
    guard let id = live.messages.first?.id else { return }

    let userInfo: [AnyHashable: Any] = [
      PushMessageIdentity.metadataKey: id,
      PushMessageIdentity.subscriberIdKey: "subscriber-\(user)",
    ]
    XCTAssertEqual(
      decider.decideRemoteNotification(userInfo: userInfo, appIsActive: false), .suppress)
    XCTAssertEqual(decider.decideRemoteNotification(userInfo: userInfo, appIsActive: true), .suppress)
    XCTAssertTrue(outbox.snapshot().isEmpty, "a socket-delivered message is never reported by the push path")
    XCTAssertTrue(store.loadReportOutbox().isEmpty)
  }

  func test_SB67_aProviderPushForAMessageTheSocketNeverDeliveredIsQueuedExactlyOnce() throws {
    let relay = try requireRelay()
    let user = uniqueUser("providerqueue")
    let store = InMemorySocketStateStore()
    let registry = SeenMessageRegistry(store: store)
    let (decider, outbox) = providerPushDecider(store: store, registry: registry)
    let live = Live(relay: relay, appID: appID, userID: user, store: store, seenRegistry: registry)
    live.client.start()
    defer { live.client.stop(); Thread.sleep(forTimeInterval: 0.1) }
    waitFor(10, "connected", extra: { relay.relayTail() }) { live.connected }

    let id = "contract-provider-only-\(DispatchTime.now().uptimeNanoseconds)"
    let subscriberID = "subscriber-\(user)"
    let userInfo: [AnyHashable: Any] = [
      PushMessageIdentity.metadataKey: id,
      PushMessageIdentity.subscriberIdKey: subscriberID,
    ]
    XCTAssertEqual(decider.decideRemoteNotification(userInfo: userInfo, appIsActive: false), .present)
    XCTAssertEqual(decider.decideRemoteNotification(userInfo: userInfo, appIsActive: false), .suppress)
    let queued = outbox.snapshot()
    XCTAssertEqual(queued.map(\.messageId), [id])
    XCTAssertEqual(queued.map(\.subscriberId), [subscriberID])
    XCTAssertTrue(live.messages.isEmpty, "the socket delivered nothing")
  }

  /// A client whose provider reports `installationID`; two of them over one store are "the same install" restarting.
  private func installationClient(
    _ relay: RelayHarness, user: String, installationID: String, store: InMemorySocketStateStore
  ) -> Live {
    let deviceInfo = SystemDeviceInfoProvider(
      installationId: { installationID },
      osVersion: { "17.5.1" },
      bundleId: { "com.example.contract" },
      relaySwitch: InMemoryRelaySwitchStore(enabled: true))
    return Live(relay: relay, appID: appID, userID: user, store: store, deviceInfo: deviceInfo)
  }

  func test_SB58_perInstallationReplayAfterARestartOverTheSameStoreResendsOnlyBAndCANeverAgain() throws {
    let relay = try requireRelay()
    let user = uniqueUser("instreplay")
    let installationID = UUID().uuidString.lowercased()
    let store = InMemorySocketStateStore()
    let stamp = DispatchTime.now().uptimeNanoseconds
    let a = "contract-inst-a-\(stamp)"
    let b = "contract-inst-b-\(stamp)"
    let c = "contract-inst-c-\(stamp)"

    let first = installationClient(relay, user: user, installationID: installationID, store: store)
    first.client.start()
    // A thrown enqueue must not leave the first client connected.
    defer { first.client.stop() }
    waitFor(10, "connected", extra: { relay.relayTail() }) { first.connected }
    let connectionID = first.state?.connectionId ?? ""
    waitFor(5, "the relay to register the installation session", extra: { relay.relayTail() }) {
      relay.relayEvents("registered").contains { $0["connection_id"] as? String == connectionID }
    }
    let outA = try relay.enqueue(
      appID: appID, userID: user, sinchMessageID: a, title: "A", installation: installationID)
    XCTAssertTrue(outA.contains("outcome=PUSHED"), "A is pushed to the live session: \(outA)")
    XCTAssertGreaterThan(first.state?.pollIntervalMs ?? 0, 2000)
    waitFor(2, "A pushed within 2 s", extra: { relay.relayTail() }) { !first.messages.isEmpty }
    XCTAssertEqual(first.messages.map(\.sinchMessageId), [a])
    let firstMessage = try XCTUnwrap(first.messages.first)
    waitFor(10, "DELIVERED for A at the sink", extra: { relay.sinkTail() }) {
      relay.sinkReports().contains { $0.sinchMessageID == a && $0.status == "DELIVERED" }
    }
    let firstConnection = first.states.last { !$0.connectionId.isEmpty }?.connectionId ?? ""
    XCTAssertFalse(firstConnection.isEmpty)
    first.client.stop()
    waitFor(5, "the first client to stop", extra: { "\(first.states)" }) { first.state?.status == .stopped }
    guard waitFor(10, "the relay to unregister the first connection", extra: { relay.relayTail() }, {
      relay.relayEvents("unregistered").contains { $0["connection_id"] as? String == firstConnection }
    }) else { return }

    let outB = try relay.enqueue(
      appID: appID, userID: user, sinchMessageID: b, title: "B", installation: installationID)
    let outC = try relay.enqueue(
      appID: appID, userID: user, sinchMessageID: c, title: "C", installation: installationID)
    XCTAssertTrue(outB.contains("outcome=STORED_OFFLINE"), "B is stored: \(outB)")
    XCTAssertTrue(outC.contains("outcome=STORED_OFFLINE"), "C is stored: \(outC)")
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertEqual(first.messages.count, 1, "a stopped client emits nothing")

    // Same persisted store: last_seen = A, so the relay replays only what is after
    // A's cursor. Unlike the legacy key, A does not come back at all.
    let second = installationClient(relay, user: user, installationID: installationID, store: store)
    second.client.start()
    defer { second.client.stop(); Thread.sleep(forTimeInterval: 0.1) }
    waitFor(20, "B and C emitted after the restart", extra: {
      second.logs.joined(separator: "\n") + "\n" + relay.relayTail(30)
    }) { second.messages.count >= 2 }
    XCTAssertEqual(second.messages.map(\.sinchMessageId), [b, c])
    waitFor(10, "DELIVERED for B and C at the sink", extra: { relay.sinkTail() }) {
      let delivered = relay.sinkReports().filter { $0.status == "DELIVERED" }.map(\.sinchMessageID)
      return delivered.contains(b) && delivered.contains(c)
    }
    // More than one poll interval (5 s): a late duplicate event, re-send or report would show.
    Thread.sleep(forTimeInterval: 6)

    XCTAssertEqual(second.messages.map(\.sinchMessageId), [b, c], "exactly B and C, in order")
    XCTAssertFalse(
      second.logs.contains { $0.contains("duplicate message \(firstMessage.id)") },
      "A did not arrive at all (cursor replay): no seen-set hit for it")
    XCTAssertEqual(first.messages.map(\.sinchMessageId), [a], "A was emitted once, by the first client")
    for id in [a, b, c] {
      let reports = relay.sinkReports().filter { $0.sinchMessageID == id }
      XCTAssertEqual(reports.map(\.status), ["DELIVERED"], "\(reports)")
      XCTAssertEqual(reports.map(\.installationID), [installationID], "\(reports)")
    }
  }

  func test_SB58_aMessageEnqueuedToADifferentInstallationOfTheSameUserDoesNotReachThisClient() throws {
    let relay = try requireRelay()
    let user = uniqueUser("instisolation")
    let mine = UUID().uuidString.lowercased()
    let other = UUID().uuidString.lowercased()
    let stamp = DispatchTime.now().uptimeNanoseconds
    let elsewhere = "contract-inst-other-\(stamp)"
    let here = "contract-inst-mine-\(stamp)"

    let live = installationClient(
      relay, user: user, installationID: mine, store: InMemorySocketStateStore())
    live.client.start()
    defer { live.client.stop(); Thread.sleep(forTimeInterval: 0.1) }
    waitFor(10, "connected", extra: { relay.relayTail() }) { live.connected }
    let connectionID = live.state?.connectionId ?? ""
    waitFor(5, "the relay to register the session", extra: { relay.relayTail() }) {
      relay.relayEvents("registered").contains { $0["connection_id"] as? String == connectionID }
    }
    let out = try relay.enqueue(
      appID: appID, userID: user, sinchMessageID: elsewhere, title: "other", installation: other)
    // The "no sink entry for the other installation" assertion at the end holds trivially:
    // nothing is connected for it and the ack deadline is 0, so there is no NOT_CONNECTED
    // report either. The isolation proof is the empty message list after 6 s plus this
    // installation's own outcome=PUSHED.
    XCTAssertTrue(out.contains("outcome=STORED_OFFLINE"), "no session for the other installation: \(out)")
    // Longer than one poll interval (5 s): neither a push nor a poll may carry it over.
    Thread.sleep(forTimeInterval: 6)
    XCTAssertTrue(live.messages.isEmpty, "nothing reached this client")

    let outMine = try relay.enqueue(
      appID: appID, userID: user, sinchMessageID: here, title: "mine", installation: mine)
    XCTAssertTrue(outMine.contains("outcome=PUSHED"), "pushed to this installation: \(outMine)")
    waitFor(2, "this installation's own message", extra: { relay.relayTail() }) { !live.messages.isEmpty }
    XCTAssertEqual(live.messages.map(\.sinchMessageId), [here])
    XCTAssertFalse(relay.sinkReports().contains { $0.sinchMessageID == elsewhere })
  }
}
