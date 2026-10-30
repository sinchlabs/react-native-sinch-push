//  SocketClient.swift — the delivery-channel state machine (RN-032).
//
//  Behaviour is normative in docs/socket-behaviour-spec.md (RN-035), rules
//  SB-18 … SB-58; this file is the Swift implementation of it. Where the
//  implementation and the spec differ, the spec wins and the difference is
//  called out where it happens.
//
//  Everything time-, network- or storage-shaped is injected (see
//  SocketDependencies.swift), which is what makes the conformance suite able to
//  drive a full connection lifecycle, a 1000-sample backoff distribution and a
//  restart with a persisted outbox on a macOS test host.

import Foundation

/// The foreground-only delivery-channel client.
final class SocketClient {

  // MARK: - Constants (spec §2)

  /// Used when neither the config nor the server supplies an interval (SB-22).
  static let defaultPollIntervalMs = 5000

  /// Floor on the poll cadence (SB-22). The server may legitimately ask for
  /// less — during local testing, or when a client is far behind — but a mobile
  /// SDK polling faster than once a second turns a missed notification into a
  /// battery problem, so the request is honoured only down to this bound.
  static let minPollIntervalMs = 1000

  /// How many delivered messages are kept for `getPendingPushMessages`. Same
  /// bound as the outbox and for the same reason: JS re-reads this store to
  /// recover what arrived while it was detached, and an unbounded list is a slow
  /// leak on a long-lived app.
  static let pendingMessageCapacity = 200

  /// At most one *alerting* system notification per window; the rest are posted
  /// silently (SB-63). Spec §2 `NOTIFICATION_ALERT_WINDOW_MS`.
  static let notificationAlertWindowMs: Int64 = 2000

  // MARK: - Callbacks

  /// Host-facing events. Everything the JS facade needs is here, so the bridge
  /// in SinchPush.mm stays a translation of these five calls.
  struct Callbacks {
    /// SB-24. Published on every transition.
    var onState: ((SocketState) -> Void)?
    /// One delivered pooled message (SB-27: never fired for a dedupe hit).
    var onMessage: ((SocketMessageEvent) -> Void)?
    /// Diagnostics, including the two distinct SB-16 lines.
    var onLog: ((String) -> Void)?
    /// SB-48: `Close(UNAUTHORIZED)`. Fired at most once per start, so the
    /// host can refresh the credential and call back with
    /// ``updateConfiguration(_:)``.
    var onAuthRequired: (() -> Void)?
  }

  // MARK: - Dependencies

  private let transportFactory: SocketTransportFactory
  private let scheduler: Scheduler
  private let random: RandomSource
  private let store: SocketStateStore
  private let tokenStore: AuthTokenStore
  private let presenter: NotificationPresenting
  private let logger: SocketLogger
  private let deviceInfo: DeviceInfoProviding
  private let deliveredNotifications: DeliveredNotificationLookup
  /// The process-wide dedupe set (SB-28, SB-64), shared with the push path.
  private let seen: SeenMessageRegistry
  private var callbacks: Callbacks

  // MARK: - State

  private var configuration: SocketConfiguration?
  private var transport: SocketTransport?

  /// Monotonic socket id. Every callback carries the generation it was
  /// installed on and is ignored unless it still matches, which is SB-51: a
  /// replaced socket must be inert, or a `close()` that fires one trailing
  /// callback schedules a second reconnect and corrupts the attempt counter.
  private var generation = 0

  private var pollTask: ScheduledTask?
  private var reconnectTask: ScheduledTask?
  private var deferralTask: ScheduledTask?

  private var attempts = 0
  /// `attempts` as it stood before this session's handshake zeroed it, so a
  /// forfeited reset can restore it instead of inventing a count (SB-45).
  private var attemptsBeforeHelloAck = 0
  /// Whether the current session's `HelloAck` reset is armed but unspent
  /// (SB-44). "Armed" means the zeroing is a claim about this session that the
  /// session has not yet backed up.
  private var helloAckResetArmed = false

  private var pollIntervalMs = SocketClient.defaultPollIntervalMs
  private var state = SocketState(status: .idle)

  private var lastSeenMessageID = ""
  /// `enqueued_at_unix_millis` of the message `lastSeenMessageID` names; 0 when
  /// the relay did not say (SB-29).
  private var lastSeenEnqueuedAtMs: Int64 = 0
  /// When the last alerting notification was posted; nil before the first (SB-63).
  private var lastAlertAtMs: Int64?
  private var tracker: ReportTracker!
  private var pendingMessages: [SocketMessageEvent] = []

  /// Terminal: `stop()`, `Close(UNAUTHORIZED)`, `Close(BG_RESUMED)`.
  private var stopped = false
  /// Bumped whenever the running client is invalidated — `stop()`, a terminal
  /// stop, a reconfigure. Deferred work that outlives the call that queued it
  /// (the delivered-notifications lookup, SB-65) captures it and does nothing
  /// once it has moved. Not `generation`: an ordinary reconnect bumps that, and
  /// must not cost a received message its notification.
  private var sessionEpoch = 0
  /// Backgrounded (SB-56). Config is kept, nothing is flushed, nothing retries.
  private var suspended = false
  /// OPEN-6: one credential refresh attempt per start.
  private var authRefreshAttempted = false
  /// Whether the store has been read into memory yet.
  private var didLoadPersistedState = false

  // MARK: - Init

  init(
    configuration: SocketConfiguration? = nil,
    transportFactory: SocketTransportFactory,
    scheduler: Scheduler,
    random: RandomSource,
    store: SocketStateStore,
    tokenStore: AuthTokenStore,
    presenter: NotificationPresenting = NoopNotificationPresenter(),
    logger: SocketLogger = SilentSocketLogger(),
    deviceInfo: DeviceInfoProviding = StaticDeviceInfoProvider(),
    deliveredNotifications: DeliveredNotificationLookup = NoDeliveredNotifications(),
    seenRegistry: SeenMessageRegistry? = nil,
    callbacks: Callbacks = Callbacks()
  ) {
    self.transportFactory = transportFactory
    self.scheduler = scheduler
    self.random = random
    self.store = store
    self.tokenStore = tokenStore
    self.presenter = presenter
    self.logger = logger
    self.deviceInfo = deviceInfo
    self.deliveredNotifications = deliveredNotifications
    // A client built without a shared registry owns one over its own store, so
    // a bare client (the tests, a host that wires nothing) still dedupes and
    // persists.
    self.seen = seenRegistry ?? SeenMessageRegistry(store: store)
    self.callbacks = callbacks
    self.tracker = ReportTracker(
      store: store, logger: logger, random: random, now: { [weak self] in
        self?.scheduler.nowMs() ?? 0
      })
    self.tracker.onRejection = { [weak self] error in self?.recordAckRejection(error) }
    self.configuration = configuration
  }

  func setCallbacks(_ callbacks: Callbacks) {
    self.callbacks = callbacks
  }

  /// Whether the host app has an in-app handler registered, which the
  /// `whenUnhandled` display rule keys on (RN-031).
  func setHandlerRegistered(_ registered: Bool) {
    presenter.handlerRegistered = registered
  }

  // MARK: - Lifecycle (SB-56)

  /// Connect, or resume after a stop.
  func start() {
    scheduler.perform { [weak self] in
      guard let self else { return }
      self.loadPersistedStateIfNeeded()
      self.stopped = false
      self.suspended = false
      self.attempts = 0
      self.authRefreshAttempted = false
      self.persistConfiguration()
      self.open()
    }
  }

  /// Stop for good: timers cancelled, socket closed, no reconnect until the host
  /// calls ``start()`` again.
  func stop() {
    scheduler.perform { [weak self] in
      guard let self else { return }
      self.stopped = true
      self.sessionEpoch += 1
      self.suspended = false
      self.clearTimers()
      self.closeSocket()
      self.publish(status: .stopped)
    }
  }

  /// `UIApplication.didEnterBackground`: close with 1000, keep the config,
  /// cancel the backoff, flush nothing. The outbox persists (SB-35), which is
  /// why there is no "persist the outbox" step here — it is written on every
  /// mutation, not on disconnect.
  func suspend() {
    scheduler.perform { [weak self] in
      guard let self, !self.stopped else { return }
      guard !self.suspended else { return }
      self.suspended = true
      self.clearTimers()
      self.closeSocket()
      self.tracker.connectionClosed()
      self.publish(status: .idle)
    }
  }

  /// `willEnterForeground` / `didBecomeActive`: reconnect. The immediate `Poll`
  /// and the outbox flush then follow from this reconnect's `HelloAck`
  /// (SB-23, SB-56), which is why they are not done here.
  func resume() {
    scheduler.perform { [weak self] in
      guard let self, !self.stopped else { return }
      guard self.suspended else { return }
      self.suspended = false
      self.attempts = 0
      self.open()
    }
  }

  /// RN-008: a credential change reconnects with a fresh `Hello`.
  ///
  /// Also the way back from `auth_required`: a credential that has just been
  /// refreshed is the only thing that can revive a client stopped by
  /// ``SocketStatus/authRequired`` (SB-48).
  func updateConfiguration(_ configuration: SocketConfiguration) {
    scheduler.perform { [weak self] in
      guard let self else { return }
      self.configuration = configuration
      self.persistConfiguration()
      self.sessionEpoch += 1
      self.stopped = false
      self.suspended = false
      self.attempts = 0
      self.clearTimers()
      self.closeSocket()
      self.open()
    }
  }

  // MARK: - Host entry points

  /// RN-004's `reportPushMessageStatus(messageId, status)`.
  ///
  /// Idempotent per `(message_id, status)` like every other report (SB-30), and
  /// queued rather than sent when the socket is not connected, which is the
  /// iOS-background case in RN-019: a notification can be dismissed while the
  /// socket is closed, and the report still has to reach the relay.
  func report(messageId: String, status: SocketDeliveryStatus) {
    scheduler.perform { [weak self] in
      guard let self else { return }
      self.tracker.queue(
        messageId: messageId,
        sinchMessageId: self.sinchMessageId(for: messageId),
        status: status)
      self.flushIfConnected(.all)
    }
  }

  /// The published state (SB-24).
  var currentState: SocketState { state }

  /// Messages JS has not consumed yet, newest first.
  var currentPendingMessages: [SocketMessageEvent] {
    pendingMessages.sorted { $0.receivedAt > $1.receivedAt }
  }

  func clearPendingMessages() {
    scheduler.perform { [weak self] in
      self?.pendingMessages.removeAll()
      self?.store.savePendingMessages([])
    }
  }

  // MARK: - Connection

  private func open() {
    // Read the persisted slices once, before the first attempt: a client that is
    // constructed and connected to directly (the facade does exactly that) must
    // still start with the seen set, the sent-set and the outbox it left behind,
    // or SB-28 and SB-35 are only true for `start()` callers.
    loadPersistedStateIfNeeded()
    guard !stopped, !suspended, let configuration else { return }
    // SB-20: `connecting` for a first attempt, `reconnecting` afterwards, and
    // SB-24: a stale `lastError` must not survive into a fresh attempt.
    publish(
      status: attempts == 0 ? .connecting : .reconnecting,
      lastError: .clear)
    cancelReconnect()
    guard let url = URL(string: configuration.url) else {
      handleDisconnect(reason: "invalid socket url \(configuration.url)")
      return
    }

    let socket = transportFactory.makeTransport()
    generation += 1
    let currentGeneration = generation
    socket.onOpen = { [weak self] in
      self?.scheduler.perform { self?.handleOpen(generation: currentGeneration) }
    }
    socket.onBinary = { [weak self] data in
      self?.scheduler.perform { self?.handleBinary(generation: currentGeneration, data: data) }
    }
    socket.onClose = { [weak self] close in
      self?.scheduler.perform {
        self?.handleTransportClose(generation: currentGeneration, close: close)
      }
    }
    transport = socket
    socket.connect(to: url)
    log("connecting to \(configuration.url)")
  }

  private func handleOpen(generation: Int) {
    guard generation == self.generation else { return }
    log("socket open, sending Hello")
    sendHello()
  }

  /// SB-18: the first frame on an open socket is `Hello`, carrying the token,
  /// the identity, the OS-derived platform, `background = false` (SB-57), the
  /// newest processed message id (SB-29), the sdk version (SB-19) and the device
  /// info of SB-59 / SB-60 (installation id, os version, bundle id,
  /// `UNSUPPORTED` background service). The device info is read on every Hello,
  /// not cached, so an installation id that was unavailable once is retried.
  private func sendHello() {
    guard let configuration, let transport, transport.isOpen else { return }
    var hello = Sinch_Push_Delivery_V1beta1_Ws_Hello()
    hello.authToken = configuration.authToken
    hello.projectID = configuration.projectID
    hello.appID = configuration.appID
    hello.userID = configuration.userID
    let device = deviceInfo.current(sdkVersionOverride: configuration.sdkVersion)
    hello.platform = device.platform
    // SB-57. Not configurable on this path, and not a field on
    // SocketConfiguration, so it cannot become true by accident.
    hello.background = false
    hello.lastSeenMessageID = lastSeenMessageID
    hello.sdkVersion = device.sdkVersion
    hello.installationID = device.installationId
    hello.osVersion = device.osVersion
    hello.bundleID = device.bundleId
    hello.backgroundService = device.backgroundService

    var frame = Sinch_Push_Delivery_V1beta1_Ws_ClientFrame()
    frame.payload = .hello(hello)
    send(frame)
  }

  // MARK: - Inbound frames

  private func handleBinary(generation: Int, data: Data) {
    // SB-51: a replaced socket is inert.
    guard generation == self.generation else { return }
    let frame: Sinch_Push_Delivery_V1beta1_Ws_ServerFrame
    do {
      frame = try FrameCodec.decodeServerFrame(data)
    } catch let error as FrameCodecError {
      switch error {
      case .unknownTag(_, let tag):
        // SB-16: a frame type this build does not know. Non-fatal, and logged
        // separately from the malformed-envelope branch below so a reader of
        // the log can tell "the peer is ahead" from "the bytes are wrong".
        log("ignoring server frame: unknown frame tag \(tag)")
      default:
        // SB-16: the envelope itself is wrong — bad prefix, over the cap,
        // truncated payload. Recoverable at the frame level, so the socket
        // stays up.
        log("dropping malformed server frame: \(error)")
      }
      return
    } catch {
      log("frame decode failed: \(error)")
      return
    }
    guard let payload = frame.payload else {
      log("ignoring server frame: no payload set")
      return
    }
    handle(payload)
  }

  private func handle(_ payload: Sinch_Push_Delivery_V1beta1_Ws_ServerFrame.OneOf_Payload) {
    switch payload {
    case .helloAck(let ack):
      handleHelloAck(ack)

    case .message(let message):
      // SB-46: a pooled message arrived, so the session did real work.
      noteSessionWork()
      if message.hasMessage {
        emitMessage(message.message, ackToken: message.ackToken)
      } else {
        // SB-40: not silently dropped. There is no message id on this frame, so
        // the FAILED report cannot name what it is about — and SB-31 forbids
        // sending one that cannot. The tracker logs the refusal, which is the
        // behaviour OPEN-5 asks for on top of "never send an empty
        // message_id".
        tracker.queueFailure(
          messageId: "",
          sinchMessageId: "",
          detail: "message frame without a pooled message")
      }

    case .ack(let ack):
      let outcome = tracker.handle(ack)
      // SB-34 / SB-46: only `accepted == true` is healthy session work. A
      // rejection proves the opposite — `rate_limited` is the report budget
      // shedding us — and spending the reset on it would recreate the
      // attempt-1 loop the reset exists to break.
      if outcome == .accepted {
        noteSessionWork()
      }
      // SB-33: a `rate_limited` rejection has just set a deferral, and the
      // deferral is only retried by its own one-shot timer. Re-arm on *every*
      // Ack, not just at `HelloAck`: without this a refusal that arrives
      // mid-session leaves the entry parked until the next handshake, which is
      // the "a report refused today is lost" gap the outbox exists to close.
      // A cancelled timer is replaced with one at the earliest deadline, and a
      // client with nothing deferred is left with no timer at all.
      armDeferralTimer()
      log(
        "ack accepted=\(ack.accepted) error=\(ack.error.isEmpty ? "<none>" : ack.error)")

    case .ping(let ping):
      // SB-38: answer on the same connection, without disturbing the poll
      // timer or the backoff budget.
      var pong = Sinch_Push_Delivery_V1beta1_Ws_Pong()
      pong.correlationID = ping.correlationID
      var frame = Sinch_Push_Delivery_V1beta1_Ws_ClientFrame()
      frame.payload = .pong(pong)
      send(frame)

    case .close(let close):
      handleClose(reason: close.reason, detail: SocketMessageEvent.absentIfEmpty(close.detail))

    case .authChallenge:
      // SB-39: reserved for future token refresh. Log it, keep the connection.
      log("auth challenge received; reserved, connection kept")

    case .pong:
      // Nothing to do: the relay only answers a poll we did not send.
      break
    }
  }

  /// SB-21, in the order the rule lists them.
  private func handleHelloAck(_ ack: Sinch_Push_Delivery_V1beta1_Ws_HelloAck) {
    // 4. Arm the backoff reset.
    noteHelloAck()

    // 2. Resolve the poll interval.
    pollIntervalMs = resolvedPollIntervalMs(serverMs: Int(ack.pollIntervalMs))

    // 1. Publish `connected` with the connection id.
    publish(
      status: .connected,
      connectionId: ack.connectionID,
      lastError: .clear)

    // 3. Every pooled message the handshake carried, with an empty ack token:
    // a HelloAck has no per-message `Message` wrapper to take one from.
    for pooled in ack.messages {
      emitMessage(pooled, ackToken: "")
    }

    // 5. Immediate poll before the first interval tick, then the outbox.
    startPolling()
    sendPoll()
    flushReports(.all)
    armDeferralTimer()
  }

  /// SB-22: config > server > default, then raised to the 1000 ms floor. The
  /// floored value is what is published and what the timer uses; the unfloored
  /// one is never published, which is what the Kotlin client gets wrong.
  func resolvedPollIntervalMs(serverMs: Int) -> Int {
    let requested: Int
    if let configured = configuration?.pollIntervalMs, configured > 0 {
      requested = configured
    } else if serverMs > 0 {
      requested = serverMs
    } else {
      requested = SocketClient.defaultPollIntervalMs
    }
    return max(SocketClient.minPollIntervalMs, requested)
  }

  // MARK: - Messages

  private func emitMessage(
    _ pooled: Sinch_Push_Delivery_V1beta1_Ws_PooledMessage,
    ackToken: String
  ) {
    // SB-25: the dedupe key is `PooledMessage.message_id`, never
    // `Message.ack_token`, even when the two are equal — the relay mints them
    // separately on at least one path, and the Ack correlation appends
    // `:<status>` to the id, so a token-shaped key cannot be safe.
    let messageId = pooled.messageID
    guard !messageId.isEmpty else {
      // SB-27: dropped without a report; the relay refuses such a report as
      // `missing_message_id`.
      log("dropping pooled message with an empty message_id")
      return
    }
    // SB-27: a dedupe hit produces no event and no notification.
    // SB-64: the set is shared with the push path, so a hit is also a message
    // APNs delivered first. RN-049: that suppresses *presentation* only. The
    // relay handed this message to this socket and is waiting for its
    // DELIVERED — staying silent records an ACK_TIMEOUT, and sinch-push answers
    // an ACK_TIMEOUT by pushing the same message again. The cursor still
    // advances: some channel has processed this id, so the relay has no reason
    // to replay it (SB-29, same never-regress rule) — but a hit moves it only
    // on a known, strictly newer timestamp.
    guard seen.markSeen(messageId) else {
      advanceLastSeen(
        messageId: messageId, enqueuedAtMs: pooled.enqueuedAtUnixMillis, onHit: true)
      // SB-30 holds this to one DELIVERED per `(message_id, status)`, so a
      // socket copy of an id already acked over the socket — or a restart
      // replaying an id the tracker already recorded — sends nothing further.
      tracker.queue(
        messageId: messageId,
        sinchMessageId: pooled.sinchMessageID,
        status: .delivered)
      flushIfConnected(.all)
      // No event and no notification below this line: a message another
      // channel already showed must not be shown twice.
      log("duplicate message \(messageId); acked, no event, no notification")
      return
    }
    // SB-62: the relay waits 3 s (iOS) for DELIVERED before it falls back to
    // APNs, so everything between "this is new" and the report is the minimum
    // that makes the report honest — the seen set and last_seen on disk, so a
    // crash after the ack cannot turn the replay into a second DELIVERED.
    // Nothing below this block may run before the report is queued and flushed.
    // (`markSeen` has already persisted the set.)
    advanceLastSeen(messageId: messageId, enqueuedAtMs: pooled.enqueuedAtUnixMillis)
    // SB-30: message received, dedupe miss -> DELIVERED, once.
    tracker.queue(
      messageId: messageId,
      sinchMessageId: pooled.sinchMessageID,
      status: .delivered)
    flushIfConnected(.all)

    let event = SocketMessageEvent(
      pooled: pooled, ackToken: ackToken, receivedAt: scheduler.nowMs())
    pendingMessages.append(event)
    if pendingMessages.count > SocketClient.pendingMessageCapacity {
      let dropped = pendingMessages.removeFirst()
      log("pending message store full; dropped \(dropped.id)")
    }
    store.savePendingMessages(pendingMessages)

    callbacks.onMessage?(event)

    // RN-031 display rule, then DISPLAYED once the post is accepted.
    guard shouldDisplayNotification else { return }
    // SB-65: a copy APNs already put on screen (delivered while the app was in
    // the background, so never seen in-process) is not posted a second time.
    let epoch = sessionEpoch
    deliveredNotifications.isDelivered(identifier: messageId) { [weak self] delivered in
      guard let self else { return }
      // The lookup answers on the system's queue; everything below touches
      // client state, so it goes back through the scheduler.
      self.scheduler.perform {
        // The client was stopped or reconfigured while the lookup was out: a
        // stopped client posts nothing and reports no DISPLAYED.
        guard !self.stopped, epoch == self.sessionEpoch else { return }
        if delivered {
          self.markShown(messageId: messageId)
          self.log("message \(messageId) is already in the notification centre; not posting")
          return
        }
        self.post(event, pooled: pooled)
      }
    }
  }

  private func post(
    _ event: SocketMessageEvent, pooled: Sinch_Push_Delivery_V1beta1_Ws_PooledMessage
  ) {
    let messageId = event.id
    presenter.post(event, alerting: takeAlertSlot()) { [weak self] posted in
      guard let self, posted else { return }
      self.markShown(messageId: messageId)
      // SB-30: system notification posted -> DISPLAYED, once. Queued like
      // every other report, so it survives a socket that is not connected.
      self.tracker.queue(
        messageId: messageId,
        sinchMessageId: pooled.sinchMessageID,
        status: .displayed)
      self.flushIfConnected(.all)
    }
  }

  /// SB-29: `last_seen_message_id` is the newest *received* id, persisted on
  /// every dedupe miss and on a hit (an id any channel has processed).
  ///
  /// Relay ids are opaque (random hex), so "newest" is decided by the message's
  /// own `enqueued_at_unix_millis`, not by comparing ids: the id only advances
  /// when this message was enqueued at or after the one it names, so an older
  /// message that arrives after a newer one (a `Poll` drain or a replay
  /// overtaking a live push) does not walk the cursor back and make the next
  /// replay re-send everything in between. A message with no timestamp, or a
  /// cursor with none, falls back to arrival order. Either way the seen set —
  /// never last_seen — is what dedupes (SB-27).
  ///
  /// A dedupe hit (`onHit`) is stricter: it moves the cursor only when its
  /// timestamp is known and strictly newer than the stored one (or nothing is
  /// stored), never on a tie or an unknown timestamp.
  private func advanceLastSeen(messageId: String, enqueuedAtMs: Int64, onHit: Bool = false) {
    if onHit && !(enqueuedAtMs > 0 && (lastSeenEnqueuedAtMs == 0 || enqueuedAtMs > lastSeenEnqueuedAtMs)) {
      return
    }
    let known = enqueuedAtMs > 0 && lastSeenEnqueuedAtMs > 0
    if known && enqueuedAtMs < lastSeenEnqueuedAtMs {
      return
    }
    lastSeenMessageID = messageId
    lastSeenEnqueuedAtMs = max(enqueuedAtMs, 0)
    store.saveLastSeen(id: lastSeenMessageID, enqueuedAtMs: lastSeenEnqueuedAtMs)
  }

  /// SB-63: whether the notification about to be posted may alert. The first
  /// one in a window does; everything inside `notificationAlertWindowMs` of it
  /// is posted silently. The slot is taken when the post is *attempted*, not
  /// when it is accepted — a burst is processed in one pass, before any
  /// completion runs, so waiting for acceptance would let all of it alert.
  ///
  /// The slot is spent only for a message that is really posted: the
  /// asynchronous delivered-notification lookup answers first, so a message the
  /// notification centre already holds never reaches this.
  private func takeAlertSlot() -> Bool {
    let now = scheduler.nowMs()
    if let last = lastAlertAtMs, now - last < SocketClient.notificationAlertWindowMs {
      return false
    }
    lastAlertAtMs = now
    return true
  }

  private var shouldDisplayNotification: Bool {
    let rule = configuration?.displayNotifications ?? .whenUnhandled
    switch rule {
    case .never: return false
    case .always: return true
    // RN-031: `whenUnhandled` posts unless the host registered an in-app
    // handler, which JS tells us about through the same
    // `setHandlerRegistered`-style call Android uses.
    case .whenUnhandled: return !presenter.handlerRegistered
    }
  }

  private func markShown(messageId: String) {
    if let index = pendingMessages.firstIndex(where: { $0.id == messageId }) {
      pendingMessages[index].shown = true
      store.savePendingMessages(pendingMessages)
    }
  }

  private func sinchMessageId(for messageId: String) -> String {
    pendingMessages.first(where: { $0.id == messageId })?.sinchMessageId
      ?? tracker.sinchMessageId(for: messageId)
      ?? ""
  }

  // MARK: - Sending

  private func startPolling() {
    cancelPoll()
    let interval = pollIntervalMs
    pollTask = scheduler.schedule(after: interval) { [weak self] in
      self?.sendPoll()
      // SB-33: a bounded retry of `upstream_forward_failed` rides the poll
      // tick. A `rate_limited` entry is *not* touched here — its deferral has
      // its own timer, because retrying on the tick the relay is throttling
      // reproduces the rejection.
      self?.flushReports(.forwardFailureRetryOnly)
      self?.startPolling()
    }
  }

  private func sendPoll() {
    guard state.status == .connected else { return }
    var frame = Sinch_Push_Delivery_V1beta1_Ws_ClientFrame()
    frame.payload = .poll(Sinch_Push_Delivery_V1beta1_Ws_Poll())
    send(frame)
  }

  private func flushIfConnected(_ mode: OutboxFlushMode) {
    guard state.status == .connected else { return }
    flushReports(mode)
  }

  private func flushReports(_ mode: OutboxFlushMode) {
    guard state.status == .connected, let transport, transport.isOpen else { return }
    let now = scheduler.nowMs()
    let reports = tracker.reportsToSend(nowMs: now, mode: mode)
    guard !reports.isEmpty else { return }
    tracker.markSent(reports)
    for report in reports {
      var frame = Sinch_Push_Delivery_V1beta1_Ws_ClientFrame()
      frame.payload = .deliveryReport(report.deliveryReport(reportedAtMs: now))
      send(frame)
    }
  }

  /// The one-shot retry for a `rate_limited` deferral (SB-33).
  ///
  /// Its own timer rather than the poll tick, so the retry happens at the end
  /// of the backoff the tracker chose and not at the mercy of when the next
  /// poll happens to fall.
  private func armDeferralTimer() {
    cancelDeferral()
    let now = scheduler.nowMs()
    guard let deadline = tracker.nextDeferral(nowMs: now) else { return }
    let delay = Int(max(0, deadline - now))
    deferralTask = scheduler.schedule(after: delay) { [weak self] in
      self?.flushReports(.deferredOnly)
      self?.armDeferralTimer()
    }
  }

  private func send(_ frame: Sinch_Push_Delivery_V1beta1_Ws_ClientFrame) {
    guard let transport, transport.isOpen else { return }
    do {
      transport.send(try FrameCodec.encodeClientFrame(frame))
    } catch {
      log("send failed: \(error)")
    }
  }

  // MARK: - Close handling

  /// SB-41's matrix.
  private func handleClose(
    reason: Sinch_Push_Delivery_V1beta1_Ws_CloseReason,
    detail: String?
  ) {
    switch reason {
    case .stale:
      // SB-47: the session hit the server-side TTL. The credential is good and
      // only a fresh Hello is missing, so reconnect at once with no timer at
      // all and start the budget from zero.
      handleStale(detail: detail)
      return

    case .unauthorized:
      // SB-48: terminal. Cancel timers, close, publish `auth_required`, and do
      // not reconnect for as long as the client lives. A credential refresh is
      // the only thing that revives it, which is an identity-layer action.
      log("closed by the relay: unauthorized (terminal)")
      let stopReason = detail ?? SocketClient.serverClosedReason(reason)
      stopTerminally(status: .authRequired, lastError: stopReason)
      if !authRefreshAttempted {
        authRefreshAttempted = true
        callbacks.onAuthRequired?()
      }
      return

    case .bgResumed:
      // SB-49: another surface owns the session. Stop, do not fight it.
      log("closed by the relay: BG_RESUMED, another surface owns the session")
      stopTerminally(status: .replaced, lastError: detail)
      return

    default:
      // POOL_FULL, SHUTDOWN, INTERNAL, UNSPECIFIED and anything this build does
      // not recognise are one case: retryable server pressure. POOL_FULL is
      // additionally "shed" — it forfeits an unspent HelloAck reset (SB-45).
      handleDisconnect(
        reason: detail ?? SocketClient.serverClosedReason(reason),
        shed: reason == .poolFull)
    }
  }

  /// SB-24's fallback form for a `Close` frame that carried no `detail`.
  ///
  /// The same wording for every reason, so "the relay shed us" and "the relay
  /// shut down" are both legible in a log and neither leaks a proto enum name
  /// into the JS surface.
  static func serverClosedReason(_ reason: Sinch_Push_Delivery_V1beta1_Ws_CloseReason) -> String {
    "server closed (reason=\(reason.rawValue))"
  }

  private func handleStale(detail: String?) {
    clearTimers()
    closeSocket()
    guard !stopped, !suspended else { return }
    log("session stale, reconnecting immediately\(detail.map { " (\($0))" } ?? "")")
    attempts = 0
    open()
  }

  private func handleTransportClose(
    generation: Int,
    close: SocketTransportClose
  ) {
    guard generation == self.generation else { return }
    // SB-50: a transport failure before the socket was ever established is
    // retryable — attempt 1 from the base delay with full jitter. It must never
    // short-circuit to an error state, because an upgrade refused by the
    // relay's rate limiter is indistinguishable from close code 1006.
    handleDisconnect(reason: "socket closed (code=\(close.code))")
  }

  /// The socket is gone. Unless `shed`, this is attempt N+1 from the base delay.
  private func handleDisconnect(reason: String, shed: Bool = false) {
    clearTimers()
    closeSocket()
    tracker.connectionClosed()
    guard !stopped, !suspended else { return }

    if shed && helloAckResetArmed {
      // SB-45: forfeit the reset. This handshake was completed *and refused*,
      // so the zeroing it bought was never real — restoring the recorded
      // pre-handshake count is what makes repeated denials climb to the 30 s
      // cap instead of restarting at 1. Keyed on the reason, never on the
      // detail string `rate_limited`, which is free to be renamed.
      helloAckResetArmed = false
      attempts = attemptsBeforeHelloAck
    }
    attempts += 1
    publish(status: .reconnecting, lastError: .set(reason))
    let delay = ReconnectBackoff.delayMs(attempts: attempts, using: random)
    // SB-43: scheduled, never immediate. Advancing the clock by zero must not
    // produce a new socket — the shed exists to stop exactly that hot loop.
    cancelReconnect()
    reconnectTask = scheduler.schedule(after: delay) { [weak self] in
      self?.open()
    }
  }

  private func stopTerminally(status: SocketStatus, lastError: String?) {
    stopped = true
    sessionEpoch += 1
    clearTimers()
    closeSocket()
    tracker.connectionClosed()
    publish(status: status, lastError: .set(lastError))
  }

  /// SB-53: stopping, UNAUTHORIZED, BG_RESUMED and STALE all cancel the poll
  /// timer *and* the pending reconnect before the socket is closed, so a stopped
  /// client leaves behind no timer that can open one.
  private func clearTimers() {
    cancelPoll()
    cancelReconnect()
    cancelDeferral()
  }

  private func cancelPoll() {
    pollTask?.cancel()
    pollTask = nil
  }

  private func cancelReconnect() {
    reconnectTask?.cancel()
    reconnectTask = nil
  }

  private func cancelDeferral() {
    deferralTask?.cancel()
    deferralTask = nil
  }

  /// Detach the callbacks *before* closing. That is what makes a replaced socket
  /// inert (SB-51): its trailing `onClose` has nowhere to land, so a
  /// `close()` cannot fire a second callback after a new socket is open.
  private func closeSocket() {
    guard let socket = transport else { return }
    transport = nil
    socket.onOpen = nil
    socket.onBinary = nil
    socket.onClose = nil
    socket.close(code: 1000, reason: nil)
  }

  // MARK: - Backoff reset (SB-44 … SB-47)

  /// Zero the budget and arm the reset, because a completed handshake shows the
  /// server had capacity for us.
  ///
  /// "Armed" means the zeroing is still unspent — a claim about this session
  /// that the session has not yet backed up. It is spent by ``noteSessionWork``
  /// or forfeited by a budget denial in ``handleDisconnect(reason:shed:)``.
  private func noteHelloAck() {
    attemptsBeforeHelloAck = attempts
    attempts = 0
    helloAckResetArmed = true
  }

  /// The session proved it could do work: a pooled message arrived or a report
  /// was accepted. A bare poll is deliberately not a work signal — the relay
  /// answers a poll that drains nothing with silence, so "politing politely" and
  /// "about to be refused" are indistinguishable on the wire.
  private func noteSessionWork() {
    helloAckResetArmed = false
  }

  /// Exposed for the conformance suite: the attempt count and whether the
  /// current session's reset is armed.
  var backoffState: (attempts: Int, resetArmed: Bool) {
    (attempts, helloAckResetArmed)
  }

  // MARK: - State publication (SB-24)

  /// What a `publish` does to `lastError`.
  ///
  /// Three cases rather than an optional parameter, because "leave it alone"
  /// and "clear it" are different instructions and SB-24 requires the second
  /// on every new attempt while most transitions must not touch the first.
  private enum LastErrorUpdate {
    case keep
    case clear
    case set(String?)
  }

  private func publish(
    status: SocketStatus,
    connectionId: String? = nil,
    lastError: LastErrorUpdate = .keep
  ) {
    state.status = status
    if let connectionId { state.connectionId = connectionId }
    state.reconnectAttempts = attempts
    state.pollIntervalMs = pollIntervalMs
    switch lastError {
    case .keep: break
    case .clear: state.lastError = nil
    case .set(let value): state.lastError = value
    }
    callbacks.onState?(state)
  }

  /// SB-33: a rejected report sets `lastError` without changing the status.
  private func recordAckRejection(_ error: String) {
    state.lastError = error
    callbacks.onState?(state)
  }

  // MARK: - Persistence

  private func loadPersistedStateIfNeeded() {
    guard !didLoadPersistedState else { return }
    didLoadPersistedState = true
    lastSeenMessageID = store.loadLastSeenMessageID()
    lastSeenEnqueuedAtMs = store.loadLastSeenEnqueuedAtMs()
    pendingMessages = store.loadPendingMessages()
    if configuration == nil, let persisted = store.loadConfiguration(),
      let token = tokenStore.loadToken()
    {
      configuration = persisted.configuration(authToken: token)
    }
  }

  /// The token goes to the Keychain; everything else goes to the state store.
  /// Keeping them apart is the point — see ``AuthTokenStore``.
  private func persistConfiguration() {
    guard let configuration else { return }
    store.saveConfiguration(configuration.persistable)
    tokenStore.saveToken(configuration.authToken)
  }

  // MARK: - Logging

  private func log(_ line: String) {
    logger.log(line)
    callbacks.onLog?(line)
  }
}