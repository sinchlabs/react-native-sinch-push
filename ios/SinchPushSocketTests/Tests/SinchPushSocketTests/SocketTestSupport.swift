//  SocketTestSupport.swift — the fakes the socket conformance suite drives.
//
//  Four seams and nothing else: a clock/timer, a random draw, a WebSocket and a
//  place for state to live. Everything the client does that is not protocol
//  logic goes through one of them (see SocketDependencies.swift), and that is
//  what makes a full connection lifecycle — a 30 s backoff cap, a 1000-sample
//  jitter distribution, a restart with a persisted outbox — testable on a macOS
//  host with no clock, no network and no UserDefaults.
//
//  Two properties are load-bearing and worth stating plainly:
//
//  * `perform` runs inline. Every assertion in the suite is therefore about a
//    settled state: after `start()` returns, the socket exists and the state has
//    been published. With a real serial queue that would need an expectation per
//    test and would still leave the ordering to chance.
//  * `advance(by:)` fires timers *in the scheduled order, including timers
//    scheduled by the work it fires*, and `advance(by: 0)` fires whatever is due
//    now. That is what SB-43 ("advancing the clock by zero must produce no new
//    socket") is asserted against: a zero redial is visible as a socket created
//    by `advance(by: 0)`, so a client that hot-retried cannot pass by accident.
//
//  The transports and timers are deliberately *not* the live ones
//  (URLSessionWebSocketTransport, DispatchScheduler). Those are exercised by the
//  example app and the live-relay suite (SB-58); what is checked here is the
//  state machine those seams feed.

import Foundation

@testable import SinchPushSocket

// MARK: - Scheduler

/// A one-shot timer held until the test advances the clock.
final class ManualScheduledTask: ScheduledTask {
  let fireAtMs: Int64
  let work: () -> Void
  var isCancelled = false

  init(fireAtMs: Int64, work: @escaping () -> Void) {
    self.fireAtMs = fireAtMs
    self.work = work
  }

  func cancel() { isCancelled = true }
}

/// A clock the test owns, and the only place timers exist.
final class ManualScheduler: Scheduler {
  /// `1_770_000_000_000` is a real epoch millisecond value, so anything the
  /// client derives from `nowMs()` (a `reported_at_unix_millis`, a deferral
  /// deadline) is a plausible timestamp rather than an obvious zero.
  private var clockMs: Int64

  private var tasks: [ManualScheduledTask] = []

  /// `perform` calls, so a test can assert that every entry point really was
  /// serialised (SB-51's "no timer run at all", and the reason the whole client
  /// routes through the scheduler).
  private(set) var performCount = 0

  init(nowMs: Int64 = 1_770_000_000_000) {
    self.clockMs = nowMs
  }

  func nowMs() -> Int64 { clockMs }

  func perform(_ work: @escaping () -> Void) {
    performCount += 1
    work()
  }

  func schedule(after delayMs: Int, _ work: @escaping () -> Void) -> ScheduledTask {
    let task = ManualScheduledTask(
      fireAtMs: clockMs + Int64(max(0, delayMs)),
      work: work)
    tasks.append(task)
    return task
  }

  // MARK: Test drivers

  /// Move the clock forward, firing everything due on the way.
  ///
  /// Timers scheduled by the work being fired are picked up by the same sweep,
  /// which is how the poll timer re-arms itself: one `advance(by: 5000)` fires
  /// the tick, and the tick schedules the next one at `clockMs + 5000`, which is
  /// outside the window and so does not fire again in the same call.
  func advance(by ms: Int) {
    let target = clockMs + Int64(ms)
    while true {
      let due = tasks.enumerated()
        .filter { !$0.element.isCancelled && $0.element.fireAtMs <= target }
        .min { ($0.element.fireAtMs, $0.offset) < ($1.element.fireAtMs, $1.offset) }
      guard let due else { break }
      tasks.remove(at: due.offset)
      clockMs = max(clockMs, due.element.fireAtMs)
      due.element.work()
    }
    clockMs = target
  }

  /// Live timers. Zero is an assertion, not a default: "no reconnect is
  /// pending" and "the poll timer was cancelled" are only meaningful if the
  /// suite can count.
  var pendingTasks: [ManualScheduledTask] { tasks.filter { !$0.isCancelled } }

  /// Milliseconds until each live timer fires.
  var pendingDelays: [Int] { pendingTasks.map { Int($0.fireAtMs - clockMs) } }
}

// MARK: - Random

/// A draw the test pins, so a scheduled delay is exact.
final class ScriptedRandomSource: RandomSource {
  private var values: [Double]
  private var index = 0
  private(set) var drawCount = 0

  /// Always the same value. `0.5` makes attempt 1 a 500 ms delay and attempt 6
  /// a 16 s one, so the *shape* of the backoff is observable without depending
  /// on `SystemRandomNumberGenerator`.
  init(fixed value: Double = 0.5) {
    self.values = [value]
  }

  /// A sequence, then the last value forever. An empty draw is a bug in the
  /// test, not something to paper over with a real generator.
  init(_ sequence: [Double]) {
    precondition(!sequence.isEmpty, "ScriptedRandomSource needs at least one draw")
    self.values = sequence
  }

  func nextUnitDouble() -> Double {
    drawCount += 1
    let value = values[min(index, values.count - 1)]
    index += 1
    return value
  }
}

// MARK: - Transport

/// One fake socket, and the only way a test can drive the inbound side.
final class FakeSocketTransport: SocketTransport {
  private(set) var connectCalls: [URL] = []
  private(set) var sent: [Data] = []
  private(set) var closeCalls: [(code: Int, reason: String?)] = []

  var isOpen = false

  var onOpen: (() -> Void)?

  /// Computed for the same reason as ``onClose``: the client clears both on a
  /// replaced socket, so a test can only prove it stopped listening by firing
  /// the handler it *had* installed.
  var onBinary: ((Data) -> Void)? {
    get { installedBinary }
    set {
      installedBinary = newValue
      if newValue != nil { retainedBinary = newValue }
    }
  }

  private var installedBinary: ((Data) -> Void)?

  /// Computed rather than stored so the *installed* handler can be retained
  /// when the client sets it — the client clears it to make a replaced socket
  /// inert (SB-51), which is exactly what makes the retained copy interesting.
  var onClose: ((SocketTransportClose) -> Void)? {
    get { installedClose }
    set {
      installedClose = newValue
      if newValue != nil { retainedClose = newValue }
    }
  }

  private var installedClose: ((SocketTransportClose) -> Void)?

  /// The handlers the client installed while this socket was current, kept
  /// *after* the client cleared them.
  ///
  /// SB-51 is about a replaced socket that keeps talking: OkHttp delivers
  /// `onClosed`/`onMessage` for a socket the app already threw away, and one
  /// trailing callback is enough to schedule a second reconnect and corrupt the
  /// attempt counter. Retaining the closures lets a test reproduce that peer
  /// rather than only checking that the client let go of them.
  fileprivate var retainedClose: ((SocketTransportClose) -> Void)?
  fileprivate var retainedBinary: ((Data) -> Void)?

  init() {}

  // MARK: SocketTransport

  func connect(to url: URL) {
    connectCalls.append(url)
  }

  func send(_ data: Data) {
    guard isOpen else { return }
    sent.append(data)
  }

  func close(code: Int, reason: String?) {
    closeCalls.append((code: code, reason: reason))
    isOpen = false
  }

  // MARK: Inbound drivers

  /// The socket opened. Only then does the client send anything.
  func openSocket() {
    isOpen = true
    onOpen?()
  }

  /// Deliver one server frame.
  func deliver(_ frame: Sinch_Push_Delivery_V1beta1_Ws_ServerFrame) {
    onBinary?(try! FrameCodec.encodeServerFrame(frame))
  }

  /// Deliver raw bytes, for the malformed-envelope cases the codec must survive.
  func deliverRaw(_ bytes: [UInt8]) {
    onBinary?(Data(bytes))
  }

  /// The relay closed the protocol session *and* the socket, in that order.
  ///
  /// The trailing transport close is delivered for real: the client is expected
  /// to have cleared the handlers by then, so this is a regression guard on
  /// SB-51's "clear before close" rather than a second close event.
  func serverClose(reason: Sinch_Push_Delivery_V1beta1_Ws_CloseReason, detail: String = "") {
    var close = Sinch_Push_Delivery_V1beta1_Ws_Close()
    close.reason = reason
    close.detail = detail
    deliver(ServerFrame(close))
    failTransport(code: 1006)
  }

  /// The socket went away with no protocol frame — a refused upgrade, a dropped
  /// TCP connection, an app backgrounding a socket the relay has not noticed
  /// (SB-50).
  func failTransport(code: Int, reason: String? = nil) {
    isOpen = false
    onClose?(SocketTransportClose(code: code, reason: reason))
  }

  /// Re-fire the callback the client detached, as a peer that keeps delivering
  /// from a socket the app has already replaced.
  func replayRetainedClose(code: Int = 1006) {
    retainedClose?(SocketTransportClose(code: code, reason: nil))
  }

  /// The same, for an inbound frame.
  func replayRetainedBinary(_ frame: Sinch_Push_Delivery_V1beta1_Ws_ServerFrame) {
    retainedBinary?(try! FrameCodec.encodeServerFrame(frame))
  }

  // MARK: Outbound inspection

  /// Every frame the client sent, decoded.
  var sentFrames: [Sinch_Push_Delivery_V1beta1_Ws_ClientFrame] {
    sent.map { try! FrameCodec.decodeClientFrame($0) }
  }

  var hellos: [Sinch_Push_Delivery_V1beta1_Ws_Hello] {
    sentFrames.compactMap {
      guard case .hello(let hello) = $0.payload else { return nil }
      return hello
    }
  }

  var hello: Sinch_Push_Delivery_V1beta1_Ws_Hello? { hellos.first }

  var polls: [Sinch_Push_Delivery_V1beta1_Ws_Poll] {
    sentFrames.compactMap {
      guard case .poll(let poll) = $0.payload else { return nil }
      return poll
    }
  }

  var reports: [Sinch_Push_Delivery_V1beta1_Ws_DeliveryReport] {
    sentFrames.compactMap {
      guard case .deliveryReport(let report) = $0.payload else { return nil }
      return report
    }
  }

  var pongs: [Sinch_Push_Delivery_V1beta1_Ws_Pong] {
    sentFrames.compactMap {
      guard case .pong(let pong) = $0.payload else { return nil }
      return pong
    }
  }

  /// The payload kinds sent, in order — the cheapest way to assert "Hello was
  /// first" or "the poll came before the first tick".
  var sentKinds: [String] {
    sentFrames.map { frame in
      switch frame.payload {
      case .hello: return "hello"
      case .poll: return "poll"
      case .deliveryReport: return "report"
      case .pong: return "pong"
      case nil: return "none"
      }
    }
  }
}

/// Creates one fake socket per attempt and keeps them, so a test can assert on
/// "no second socket was created" (SB-43) and can still talk to a replaced one
/// (SB-51).
final class FakeSocketTransportFactory: SocketTransportFactory {
  private(set) var sockets: [FakeSocketTransport] = []

  var createdCount: Int { sockets.count }

  /// The socket of the current attempt.
  var current: FakeSocketTransport? { sockets.last }

  func makeTransport() -> SocketTransport {
    let socket = FakeSocketTransport()
    sockets.append(socket)
    return socket
  }

  func reset() { sockets.removeAll() }
}

// MARK: - Lifecycle

/// The lifecycle observer a test owns (SB-56, SB-66).
///
/// Bound to its client in `init` rather than taking handlers from the facade,
/// exactly as `UIApplicationSocketLifecycle` does: the two must be
/// interchangeable, and an observer that watches transitions without driving
/// the client is the failure this protocol exists to rule out.
///
/// `startCount`/`stopCount` are the point of it for the facade: "the observer is
/// still attached" is not observable otherwise, since
/// `UIApplicationSocketLifecycle` is behind `#if canImport(UIKit)` and is not
/// even compiled by the SwiftPM harness.
final class FakeLifecycleObserver: AppLifecycleObserving {
  var onBackground: (() -> Void)?
  var onForeground: (() -> Void)?

  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var isObserving = false

  init(client: SocketClient) {
    self.onBackground = { [weak client] in client?.suspend() }
    self.onForeground = { [weak client] in client?.resume() }
  }

  func startObserving() {
    startCount += 1
    isObserving = true
  }

  func stopObserving() {
    stopCount += 1
    isObserving = false
  }

  // MARK: Transition drivers

  /// `UIApplication.didEnterBackgroundNotification`.
  func goBackground() { onBackground?() }

  /// `willEnterForegroundNotification` and `didBecomeActiveNotification`.
  func goForeground() { onForeground?() }
}

// MARK: - Logger

/// Records every diagnostic line. SB-16 makes "the two failures are logged
/// separately" and SB-33/SB-39 make logging part of the contract, so this is a
/// spy rather than a convenience.
final class RecordingLogger: SocketLogger {
  private(set) var lines: [String] = []

  func log(_ line: String) { lines.append(line) }

  func contains(_ fragment: String) -> Bool {
    lines.contains { $0.contains(fragment) }
  }
}

// MARK: - Notifications

/// Posts (or refuses to post) without `UNUserNotificationCenter`, and records
/// what it was asked to show.
///
/// `acceptsPost` defaults to `false`: a presenter that silently succeeds would
/// make every DISPLAYED assertion pass for the wrong reason, since DISPLAYED is
/// only queued when the post was accepted.
final class FakeNotificationPresenter: NotificationPresenting {
  var handlerRegistered = false
  /// Whether the system accepted the post.
  var acceptsPost = false
  private(set) var posted: [SocketMessageEvent] = []
  /// `alerting` of each post, parallel to ``posted`` (SB-63).
  private(set) var postedAlerting: [Bool] = []
  /// Runs inside `post`, before the completion — for asserting what had already
  /// happened by the time the notification work started (SB-62).
  var onPost: ((SocketMessageEvent) -> Void)?

  func post(
    _ message: SocketMessageEvent, alerting: Bool, completion: @escaping (Bool) -> Void
  ) {
    posted.append(message)
    postedAlerting.append(alerting)
    onPost?(message)
    completion(acceptsPost)
  }
}

/// The notification centre's delivered list, held by the test (RN-045, SB-65).
final class FakeDeliveredNotifications: DeliveredNotificationLookup {
  /// Identifiers the "system" already shows.
  var delivered: Set<String> = []
  private(set) var asked: [String] = []
  /// When `false` the answer is held until ``flush()``, like the real
  /// asynchronous `getDeliveredNotifications`.
  var answersInline = true
  private var pending: [() -> Void] = []

  func isDelivered(identifier: String, completion: @escaping (Bool) -> Void) {
    asked.append(identifier)
    let answer = { completion(self.delivered.contains(identifier)) }
    if answersInline { answer() } else { pending.append(answer) }
  }

  func flush() {
    let work = pending
    pending = []
    work.forEach { $0() }
  }
}

// MARK: - Store

/// An in-memory store that hands the harness the persisted value back, so a
/// test can assert that a mutation was made durable and not merely queued.
final class FakeSocketStateStore: SocketStateStore {
  private(set) var seen: [String] = []
  private(set) var reported: [String] = []
  private(set) var lastSeen = ""
  private(set) var lastSeenEnqueuedAt: Int64 = 0
  private(set) var outbox: [PendingReport] = []
  private(set) var reportOutbox: [ReportOutboxEntry] = []
  private(set) var messages: [SocketMessageEvent] = []
  private(set) var configuration: PersistedSocketConfiguration?
  private(set) var clearConfigurationCount = 0
  /// Runs inside `saveLastSeenMessageID`, before the value lands (SB-62).
  var onSaveLastSeen: (() -> Void)?
  /// Called on every configuration write; see ``saveConfiguration(_:)``.
  var onSaveConfiguration: ((PersistedSocketConfiguration) -> Void)?

  init(
    seen: [String] = [],
    reported: [String] = [],
    lastSeen: String = "",
    lastSeenEnqueuedAt: Int64 = 0,
    outbox: [PendingReport] = [],
    reportOutbox: [ReportOutboxEntry] = [],
    messages: [SocketMessageEvent] = [],
    configuration: PersistedSocketConfiguration? = nil
  ) {
    self.seen = seen
    self.reported = reported
    self.lastSeen = lastSeen
    self.lastSeenEnqueuedAt = lastSeenEnqueuedAt
    self.outbox = outbox
    self.reportOutbox = reportOutbox
    self.messages = messages
    self.configuration = configuration
  }

  func loadSeenMessageIDs() -> [String] { seen }
  func saveSeenMessageIDs(_ ids: [String]) { seen = ids }

  func loadReportedKeys() -> [String] { reported }
  /// RN-055: how often each report collection was written.
  private(set) var saveReportedKeysCount = 0
  private(set) var saveOutboxCount = 0
  func saveReportedKeys(_ keys: [String]) {
    reported = keys
    saveReportedKeysCount += 1
  }

  func loadLastSeenMessageID() -> String { lastSeen }
  func saveLastSeenMessageID(_ id: String) {
    onSaveLastSeen?()
    lastSeen = id
  }
  func loadLastSeenEnqueuedAtMs() -> Int64 { lastSeenEnqueuedAt }
  func saveLastSeenEnqueuedAtMs(_ ms: Int64) { lastSeenEnqueuedAt = ms }

  func loadOutbox() -> [PendingReport] { outbox }
  func saveOutbox(_ reports: [PendingReport]) {
    outbox = reports
    saveOutboxCount += 1
  }

  func loadReportOutbox() -> [ReportOutboxEntry] { reportOutbox }
  func saveReportOutbox(_ entries: [ReportOutboxEntry]) {
    reportOutbox = entries
  }

  func loadPendingMessages() -> [SocketMessageEvent] { messages }
  func savePendingMessages(_ messages: [SocketMessageEvent]) { self.messages = messages }

  func loadConfiguration() -> PersistedSocketConfiguration? { configuration }
  func saveConfiguration(_ value: PersistedSocketConfiguration) {
    configuration = value
    // The facade persists asynchronously on its own queue, so a test that needs
    // to observe the write needs a hook rather than a read after the fact.
    onSaveConfiguration?(value)
  }
  func clearConfiguration() {
    clearConfigurationCount += 1
    configuration = nil
  }

  /// True when any persisted slice mentions `value` — used by the "the token
  /// never lands in the plist" assertion (SB-18), where the store is opaque and
  /// JSON is not.
  func persistedText(contains value: String) -> Bool {
    let encoder = JSONEncoder()
    let slices: [AnyEncodableBox] = [
      AnyEncodableBox(seen), AnyEncodableBox(reported), AnyEncodableBox(lastSeen),
      AnyEncodableBox(outbox), AnyEncodableBox(reportOutbox), AnyEncodableBox(messages),
      AnyEncodableBox(configuration),
    ]
    return slices.contains { box in
      guard let data = try? encoder.encode(box) else { return false }
      return String(decoding: data, as: UTF8.self).contains(value)
    }
  }
}

/// `AnyEncodable` without the dependency, for the containment check above.
private struct AnyEncodableBox: Encodable {
  private let encodeValue: (Encoder) throws -> Void

  init<T: Encodable>(_ value: T) {
    self.encodeValue = { encoder in
      var container = encoder.singleValueContainer()
      try container.encode(value)
    }
  }

  func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
}

// MARK: - Harness

/// The state a test collects and asserts on.
final class StateRecorder {
  private(set) var states: [SocketState] = []
  /// SB-27: a message event, which a dedupe hit must not produce.
  private(set) var messages: [SocketMessageEvent] = []
  /// SB-48 / OPEN-6: how many times the host was asked to refresh the token.
  private(set) var authRequiredCount = 0

  /// Every status published, in order.
  var statuses: [SocketStatus] { states.map(\.status) }

  /// The last state published.
  var current: SocketState? { states.last }

  /// The ids of the message events published, in order.
  var deliveredMessageIDs: [String] { messages.map(\.id) }

  func record(_ state: SocketState) { states.append(state) }
  func record(_ message: SocketMessageEvent) { messages.append(message) }
  func recordAuthRequired() { authRequiredCount += 1 }
}

/// A client plus every fake it was built from.
///
/// One `makeHarness()` per test rather than shared fixtures: the interesting
/// assertions here are about counters (sockets created, frames sent, timers
/// pending), and a shared harness would make every one of them a diff against
/// whatever ran before.
struct SocketHarness {
  let scheduler: ManualScheduler
  let factory: FakeSocketTransportFactory
  let random: ScriptedRandomSource
  let store: FakeSocketStateStore
  let tokenStore: InMemoryAuthTokenStore
  let presenter: FakeNotificationPresenter
  let logger: RecordingLogger
  let recorder: StateRecorder
  let client: SocketClient

  /// The socket of the current attempt, or `nil` before the first one.
  var transport: FakeSocketTransport { factory.current! }

  /// How many sockets have been created in total (SB-43, SB-51).
  var socketCount: Int { factory.createdCount }

  /// Live timers.
  var pendingTimers: Int { scheduler.pendingTasks.count }

  /// `true` when any published state carries `status`.
  func published(_ status: SocketStatus) -> Bool {
    recorder.statuses.contains(status)
  }

  /// Message events the client published (SB-27: none on a dedupe hit).
  var deliveredMessageIDs: [String] { recorder.deliveredMessageIDs }

  /// Reports for one status, in the order they were sent.
  func reports(_ status: Sinch_Push_Delivery_V1beta1_Ws_DeliveryReport.Status)
    -> [Sinch_Push_Delivery_V1beta1_Ws_DeliveryReport]
  {
    reports.filter { $0.status == status }
  }

  /// Move the clock far enough that no timer in the suite can still fire: 100
  /// reconnect attempts at the 30 s cap is an hour, and a test that asserts
  /// "nothing more happens" has to mean it.
  func advanceToNoFutureTimer() {
    scheduler.advance(by: 3_600_000)
  }

  /// Every outbound frame on the current socket.
  var sentFrames: [Sinch_Push_Delivery_V1beta1_Ws_ClientFrame] { transport.sentFrames }

  var hellos: [Sinch_Push_Delivery_V1beta1_Ws_Hello] { transport.hellos }
  /// The `Hello` of the current socket.
  var hello: Sinch_Push_Delivery_V1beta1_Ws_Hello? { transport.hello }
  var polls: [Sinch_Push_Delivery_V1beta1_Ws_Poll] { transport.polls }
  var reports: [Sinch_Push_Delivery_V1beta1_Ws_DeliveryReport] { transport.reports }
  var pongs: [Sinch_Push_Delivery_V1beta1_Ws_Pong] { transport.pongs }

  // MARK: Inbound helpers

  /// Open the current socket and complete the handshake.
  @discardableResult
  func handshake(
    connectionID: String = "conn-1",
    pollIntervalMs: Int32 = 0,
    messages: [Sinch_Push_Delivery_V1beta1_Ws_PooledMessage] = []
  ) -> FakeSocketTransport {
    transport.openSocket()
    var ack = Sinch_Push_Delivery_V1beta1_Ws_HelloAck()
    ack.connectionID = connectionID
    ack.pollIntervalMs = pollIntervalMs
    ack.messages = messages
    transport.deliver(ServerFrame(ack))
    return transport
  }

  /// Push one pooled message on the current socket.
  func deliverMessage(
    _ pooled: Sinch_Push_Delivery_V1beta1_Ws_PooledMessage,
    ackToken: String = ""
  ) {
    var message = Sinch_Push_Delivery_V1beta1_Ws_Message()
    message.message = pooled
    message.ackToken = ackToken
    transport.deliver(ServerFrame(message))
  }

  /// The relay's answer to a delivery report.
  func ack(accepted: Bool, error: String = "", token: String) {
    var frame = Sinch_Push_Delivery_V1beta1_Ws_Ack()
    frame.ackToken = token
    frame.accepted = accepted
    frame.error = error
    transport.deliver(ServerFrame(frame))
  }

  /// Close the protocol session with `reason`, then the socket.
  func serverClose(
    reason: Sinch_Push_Delivery_V1beta1_Ws_CloseReason,
    detail: String = ""
  ) {
    transport.serverClose(reason: reason, detail: detail)
  }
}

/// Build a client over the fakes.
func makeHarness(
  configuration overrides: SocketConfiguration? = nil,
  random draw: Double = 0.5,
  store: FakeSocketStateStore = FakeSocketStateStore(),
  presenter: FakeNotificationPresenter? = nil,
  deviceInfo: DeviceInfoProviding = testDeviceInfo(),
  delivered: DeliveredNotificationLookup = NoDeliveredNotifications(),
  registry: SeenMessageRegistry? = nil,
  onMessage: ((SocketMessageEvent) -> Void)? = nil,
  start: Bool = true
) -> SocketHarness {
  let scheduler = ManualScheduler()
  let factory = FakeSocketTransportFactory()
  let random = ScriptedRandomSource(fixed: draw)
  let tokenStore = InMemoryAuthTokenStore()
  let presenter = presenter ?? FakeNotificationPresenter()
  let logger = RecordingLogger()
  let recorder = StateRecorder()

  let client = SocketClient(
    configuration: overrides ?? testConfiguration(),
    transportFactory: factory,
    scheduler: scheduler,
    random: random,
    store: store,
    tokenStore: tokenStore,
    presenter: presenter,
    logger: logger,
    deviceInfo: deviceInfo,
    deliveredNotifications: delivered,
    seenRegistry: registry,
    callbacks: SocketClient.Callbacks(
      onState: { recorder.record($0) },
      onMessage: {
        recorder.record($0)
        onMessage?($0)
      },
      // `onLog` is deliberately not mirrored into `logger`: the client writes
      // every line to both sinks, and recording it twice would make a "logged
      // separately" assertion count each line twice.
      onAuthRequired: { recorder.recordAuthRequired() }))
  // The store's persisted slices are read on the first `open()`, and a few
  // tests hand the client a configuration up front; both paths are exercised
  // deliberately, so this is just the ordinary ordering.
  if start { client.start() }

  return SocketHarness(
    scheduler: scheduler,
    factory: factory,
    random: random,
    store: store,
    tokenStore: tokenStore,
    presenter: presenter,
    logger: logger,
    recorder: recorder,
    client: client)
}

// MARK: - Fixtures

/// The device facts every Hello carries in the suite (SB-59). Fixed values, so
/// a test asserts a field by its literal rather than by re-deriving it.
func testDeviceInfo(
  installationId: String = "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11",
  osVersion: String = "17.5.1",
  bundleId: String = "com.example.host"
) -> StaticDeviceInfoProvider {
  StaticDeviceInfoProvider(
    installationId: installationId, osVersion: osVersion, bundleId: bundleId)
}

/// The config every test starts from, so a difference in behaviour is a
/// difference in the test rather than in the fixture.
func testConfiguration(
  url: String = "ws://127.0.0.1:8080/ws",
  authToken: String = "jwt.token.value",
  projectID: String = "project-1",
  appID: String = "app-1",
  userID: String = "user-1",
  pollIntervalMs: Int = 0,
  displayNotifications: SocketDisplayRule = .always,
  sdkVersion: String? = nil
) -> SocketConfiguration {
  SocketConfiguration(
    url: url,
    authToken: authToken,
    projectID: projectID,
    appID: appID,
    userID: userID,
    pollIntervalMs: pollIntervalMs,
    displayNotifications: displayNotifications,
    sdkVersion: sdkVersion)
}

/// Wrap a payload in a server frame.
func ServerFrame(_ payload: Sinch_Push_Delivery_V1beta1_Ws_ServerFrame.OneOf_Payload)
  -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame
{
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
  frame.payload = payload
  return frame
}

func ServerFrame(_ payload: Sinch_Push_Delivery_V1beta1_Ws_HelloAck)
  -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame
{
  ServerFrame(.helloAck(payload))
}

func ServerFrame(_ payload: Sinch_Push_Delivery_V1beta1_Ws_Message)
  -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame
{
  ServerFrame(.message(payload))
}

func ServerFrame(_ payload: Sinch_Push_Delivery_V1beta1_Ws_Ack)
  -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame
{
  ServerFrame(.ack(payload))
}

func ServerFrame(_ payload: Sinch_Push_Delivery_V1beta1_Ws_Ping)
  -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame
{
  ServerFrame(.ping(payload))
}

func ServerFrame(_ payload: Sinch_Push_Delivery_V1beta1_Ws_Close)
  -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame
{
  ServerFrame(.close(payload))
}

func ServerFrame(_ payload: Sinch_Push_Delivery_V1beta1_Ws_AuthChallenge)
  -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame
{
  ServerFrame(.authChallenge(payload))
}

func ServerFrame(_ payload: Sinch_Push_Delivery_V1beta1_Ws_Pong)
  -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame
{
  ServerFrame(.pong(payload))
}

/// A pooled message with an alert that says nothing useful.
///
/// Every optional string is *set* and empty, which is the case proto3 cannot
/// distinguish from "never set" — SB-36's reason for mapping `""` to absent.
func blankPooledMessage(
  messageID: String,
  sinchMessageID: String? = nil,
  enqueuedAt: Int64 = 1_770_000_000_000
) -> Sinch_Push_Delivery_V1beta1_Ws_PooledMessage {
  var alert = Sinch_Push_V1beta1_Resources_Alert()
  alert.title = ""
  alert.message = ""
  alert.imageURL = ""

  var notification = Sinch_Push_V1beta1_Resources_PushNotification()
  notification.alert = alert
  notification.trigger = ""
  notification.metadata = [:]

  var pooled = Sinch_Push_Delivery_V1beta1_Ws_PooledMessage()
  pooled.messageID = messageID
  pooled.sinchMessageID = sinchMessageID ?? "sinch-\(messageID)"
  pooled.pushNotification = notification
  pooled.enqueuedAtUnixMillis = enqueuedAt
  return pooled
}

// MARK: - package.json

/// The repository root, found by walking up from this file.
///
/// SB-19 pins `sdk_version` to the published package version, and the point of
/// pinning it in Swift is that the Kotlin copy of the same string cannot drift
/// without a test failing. That only works if the test reads the real
/// `package.json` rather than a second hard-coded copy of its version.
func repositoryRoot(from file: StaticString = #filePath) -> URL {
  var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
  for _ in 0..<8 {
    let manifest = url.appendingPathComponent("package.json")
    if FileManager.default.fileExists(atPath: manifest.path),
      FileManager.default.fileExists(
        atPath: url.appendingPathComponent("ios/SinchPushSocket").path)
    {
      return url
    }
    url = url.deletingLastPathComponent()
  }
  fatalError("could not find the package root above \(file)")
}

/// The `version` field of the repository's `package.json`.
func packageVersion() -> String {
  let manifest = repositoryRoot().appendingPathComponent("package.json")
  let data = try! Data(contentsOf: manifest)
  let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
  return object["version"] as! String
}