//  SocketDependencies.swift — the seams the client is tested through (RN-032).
//
//  A handful of protocols, no concrete behaviour: time, randomness, the
//  WebSocket, the app lifecycle, notifications and where state lives.
//  Everything the state machine does that is not protocol logic goes through
//  one of them, which is what lets the conformance suite in
//  ios/SinchPushSocketTests drive a whole connection lifecycle — including a
//  1000-sample backoff distribution and a restart with a persisted outbox —
//  with no clock, no network and no UserDefaults.
//
//  Foundation only, and that is a constraint rather than a preference: this file
//  is compiled by CocoaPods in a host app *and* by `swift test` on macOS. See
//  `SystemDependencies.swift` for the live implementations and `iOS/` for the
//  ones that need UIKit, Security or UserNotifications.

import Foundation

// MARK: - Time

/// A cancellable one-shot timer.
protocol ScheduledTask: AnyObject {
  func cancel()
}

/// Serialises work onto one execution context and provides time.
///
/// ``perform(_:)`` is not decoration. Every entry point into
/// ``SocketClient`` — a transport callback, a poll tick, a reconnect, a
/// lifecycle notification — is routed through it, so the client's mutable state
/// is only ever touched from one place and a reconnect scheduled from inside a
/// frame handler can never interleave with a frame handler. The live
/// implementation is a serial `DispatchQueue`; the test implementation runs the
/// work inline, which makes every assertion in the suite deterministic.
protocol Scheduler: AnyObject {
  /// Wall-clock milliseconds since the Unix epoch. Used for
  /// `reported_at_unix_millis` (SB-15, so this must stay an integer) and for
  /// `rate_limited` deferral deadlines.
  func nowMs() -> Int64

  /// Run `work` on the scheduler's context, immediately if already there.
  func perform(_ work: @escaping () -> Void)

  /// Run `work` once after `delayMs`. `delayMs == 0` still goes through the
  /// scheduler rather than running inline, so "scheduled" and "running" stay
  /// distinguishable — which is exactly what SB-43 (no redial in the same tick
  /// after a shed) is about.
  func schedule(after delayMs: Int, _ work: @escaping () -> Void) -> ScheduledTask
}

// MARK: - Randomness

/// The only source of randomness the backoff uses.
///
/// SB-42 needs a *controllable* source: the distribution test needs 1000 real
/// samples, and the cap test needs the jitter pinned at its ceiling so a
/// scheduled delay can be observed to have *not* fired yet.
protocol RandomSource: AnyObject {
  /// A value in `[0, 1)`, matching `Math.random()` on which the reference
  /// formula was written.
  func nextUnitDouble() -> Double
}

// MARK: - Transport

/// Why a socket went away, as the transport sees it.
///
/// A `Close` protocol frame arrives *before* this on a relay-initiated close;
/// it is only the fallback for a socket that simply stopped.
struct SocketTransportClose {
  /// WebSocket close code. 1000 is a normal closure — the iOS background path
  /// uses it deliberately (SB-56).
  var code: Int
  var reason: String?
}

/// One WebSocket connection.
///
/// The protocol is a binary-message protocol (SB-01), so this exposes only
/// binary messages: a text frame is not part of it and the live transport drops
/// it rather than handing it over.
protocol SocketTransport: AnyObject {
  /// Open. Called once per attempt.
  func connect(to url: URL)

  /// Send one binary frame. Ignored when the socket is not open.
  func send(_ data: Data)

  /// Close with a code (SB-56 uses 1000 for "the app backgrounded").
  func close(code: Int, reason: String?)

  var isOpen: Bool { get }

  /// Cleared by the client before every ``close(code:reason:)`` so a replaced
  /// socket cannot deliver a second close (SB-51).
  var onOpen: (() -> Void)? { get set }
  var onBinary: ((Data) -> Void)? { get set }
  var onClose: ((SocketTransportClose) -> Void)? { get set }
}

/// Creates a socket per attempt.
///
/// A factory rather than a single injected socket because SB-47 (reconnect on
/// `STALE` with no timer at all) and SB-45 (escalate across denials) both need
/// a *new* socket at arbitrary points, and because a test asserting "no second
/// socket was created" has to be able to count them.
protocol SocketTransportFactory: AnyObject {
  func makeTransport() -> SocketTransport
}

// MARK: - Lifecycle

/// Foreground/background transitions.
///
/// SB-56: iOS is foreground-only. `didEnterBackground` closes with 1000, keeps
/// the config, cancels the backoff and flushes nothing; `willEnterForeground`
/// (and `didBecomeActive`) reconnects, and the reconnect's `HelloAck` then
/// produces the immediate `Poll` and outbox flush of SB-23.
///
/// The protocol is in the core so the client can be driven by a fake in tests;
/// the live implementation observes `UIApplication` and lives in `iOS/`.
protocol AppLifecycleObserving: AnyObject {
  var onBackground: (() -> Void)? { get set }
  var onForeground: (() -> Void)? { get set }
  func startObserving()
  func stopObserving()
}

// MARK: - Notifications

/// Posts the local notification for a socket message (RN-031, RN-019).
///
/// Injected because posting is the trigger for DISPLAYED (SB-30) and posting is
/// the one part of the display rule that cannot be exercised off-device: the
/// live implementation needs `UNUserNotificationCenter`.
protocol NotificationPresenting: AnyObject {
  /// Post a notification for `message`. The completion reports whether it was
  /// accepted; DISPLAYED is queued only on success, because a rejected post
  /// means nothing was shown.
  ///
  /// `alerting == false` is the silent post of the replay-burst rule (SB-63):
  /// the notification is still posted, with no sound and the quietest
  /// interruption level the platform has. The thread is the message's
  /// `trigger` when it has one, else ``kSinchPushNotificationThread``,
  /// whatever `alerting` says (see ``SocketNotificationStyle``).
  func post(
    _ message: SocketMessageEvent,
    alerting: Bool,
    completion: @escaping (Bool) -> Void)

  /// Whether the host app has registered an in-app handler, which is what
  /// `whenUnhandled` keys on (RN-031). Set from JS.
  var handlerRegistered: Bool { get set }
}

/// Whether the system already has a notification with a given identifier in the
/// notification centre (RN-045, SB-65).
///
/// A message APNs delivered while the app was in the background is on screen
/// but was never seen in-process, so the seen set does not know it. When the
/// socket later receives the same message it asks here before posting its own
/// copy; the identifier is the message id on both channels (the APNs
/// `apns-collapse-id` and the local request identifier), so a hit means the
/// user already has it.
///
/// A seam rather than a `UNUserNotificationCenter` call so the rule is
/// testable. The live implementation answers from
/// `getDeliveredNotifications`, on an arbitrary queue.
protocol DeliveredNotificationLookup: AnyObject {
  func isDelivered(identifier: String, completion: @escaping (Bool) -> Void)
}

/// The `UNNotificationContent.threadIdentifier` a socket notification falls
/// back to when its message has no `trigger` (SB-63).
let kSinchPushNotificationThread = "sinchpush"

/// How a socket notification is styled (SB-63): the pure half of the
/// `UNNotificationContent` mapping, so it is testable without UserNotifications.
struct SocketNotificationStyle: Equatable {
  /// The message's `trigger` when present (non-empty), else
  /// ``kSinchPushNotificationThread``.
  let threadIdentifier: String
  /// `false` for the silent post of a replay burst.
  let playsSound: Bool
  /// `true` for the silent post: `.passive` interruption level where available.
  let passive: Bool

  init(alerting: Bool, trigger: String?) {
    if let trigger, !trigger.isEmpty {
      threadIdentifier = trigger
    } else {
      threadIdentifier = kSinchPushNotificationThread
    }
    playsSound = alerting
    passive = !alerting
  }
}

// MARK: - Persistence

/// Everything the client keeps across a restart.
///
/// Deliberately not one blob: SB-28 wants the seen set persisted so dedupe
/// survives a restart, SB-35 wants the outbox persisted because a report
/// refused with `rate_limited` is otherwise lost, and the auth token must not
/// land in a plist at all — it has its own store, ``AuthTokenStore``.
protocol SocketStateStore: AnyObject {
  // Seen set, oldest first — the order the LRU evicts in (SB-28).
  func loadSeenMessageIDs() -> [String]
  func saveSeenMessageIDs(_ ids: [String])

  // "id:statusNumber" keys already reported (SB-30).
  func loadReportedKeys() -> [String]
  func saveReportedKeys(_ keys: [String])

  // Newest *received* `message_id`, echoed in `Hello` (SB-29), and that
  // message's `enqueued_at_unix_millis` (0 = unknown), which is what keeps an
  // older replayed message from moving it back.
  func loadLastSeenMessageID() -> String
  func saveLastSeenMessageID(_ id: String)
  func loadLastSeenEnqueuedAtMs() -> Int64
  func saveLastSeenEnqueuedAtMs(_ ms: Int64)
  /// Both halves of the cursor in one call (SB-29).
  func saveLastSeen(id: String, enqueuedAtMs: Int64)

  // The outbox (SB-35).
  func loadOutbox() -> [PendingReport]
  func saveOutbox(_ reports: [PendingReport])

  // Provider-push reports waiting for JS to flush them.
  func loadReportOutbox() -> [ReportOutboxEntry]
  func saveReportOutbox(_ entries: [ReportOutboxEntry])

  // Messages surfaced to JS and recoverable after a background (RN-020).
  func loadPendingMessages() -> [SocketMessageEvent]
  func savePendingMessages(_ messages: [SocketMessageEvent])

  // Config for a relaunch, without the credential.
  func loadConfiguration() -> PersistedSocketConfiguration?
  func saveConfiguration(_ configuration: PersistedSocketConfiguration)
  func clearConfiguration()
}

extension SocketStateStore {
  /// Two `UserDefaults` writes are cheap and each is atomic; a store with a
  /// real transaction can override this.
  func saveLastSeen(id: String, enqueuedAtMs: Int64) {
    saveLastSeenMessageID(id)
    saveLastSeenEnqueuedAtMs(enqueuedAtMs)
  }
}

/// The credential. Split from ``SocketStateStore`` so the Keychain
/// implementation is the only thing that ever holds a JWT (SB-18).
protocol AuthTokenStore: AnyObject {
  func loadToken() -> String?
  func saveToken(_ token: String)
  func clearToken()
}

// MARK: - Logging

/// Where the client's diagnostics go.
///
/// SB-16 requires an unknown tag and a malformed envelope to be logged
/// *separately*, and SB-39 requires `AuthChallenge` to be logged at all, so
/// the log sink is part of the contract rather than a debug convenience.
protocol SocketLogger: AnyObject {
  func log(_ line: String)
}