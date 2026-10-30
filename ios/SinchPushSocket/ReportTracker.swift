//  ReportTracker.swift — the delivery-report state machine, the sent-set and the
//  outbox (RN-004, SB-30 … SB-35, SB-37, SB-40).
//
//  The rules this file implements, and the order they are stated in:
//
//    SB-30  a (message_id, status) pair is reported at most once per installation, persisted
//    SB-31  a report carries message_id, sinch_message_id, status, reason and
//          reported_at_unix_millis — and never an empty message_id
//    SB-32  the Ack token is "<message_id>:<numeric status>", compared whole
//    SB-33  Ack.error is a closed vocabulary with one action per member
//    SB-34  only accepted == true is healthy session work
//    SB-35  a report that cannot be sent is queued persistently, bounded at 200
//    SB-40  a decode failure is FAILED with reason "decode: <err>"
//
//  Three details are load-bearing and easy to get wrong, so they are spelled
//  out where they happen:
//
//    * The token is *constructed*, never parsed. A `:` inside a message_id is
//      therefore harmless and needs no escaping rule.
//    * A `rate_limited` rejection defers with backoff and is retried on a timer,
//      **not** on the next poll tick — the poll tick is the thing being
//      throttled, so retrying there reproduces the rejection.
//    * An entry that has been sent but not yet answered is not re-sent while the
//      connection lives, or the relay would see the same report repeatedly. It
//      goes back to queued when the connection dies, because an Ack for a frame
//      sent on a dead socket can never arrive and SB-35 is about not losing it.

import Foundation

/// What ``ReportTracker/reportsToSend(nowMs:mode:)`` is being asked for.
///
/// The three modes are the three moments the spec gives reports different
/// treatment: a handshake flushes everything, a `rate_limited` deferral retries
/// only what it deferred, and a poll tick retries only the forward failures —
/// never the deferred ones, which is the whole of SB-33's first row.
enum OutboxFlushMode: Sendable, Equatable {
  /// After `HelloAck` (SB-23, SB-35).
  case all
  /// A `rate_limited` deferral has expired.
  case deferredOnly
  /// A poll tick; bounded retry of `upstream_forward_failed` (SB-33).
  case forwardFailureRetryOnly
}

/// The result of an `Ack`, for the client to act on (SB-34 spends the backoff
/// reset only on `.accepted`).
enum AckOutcome: Sendable, Equatable {
  /// Correlated and accepted: the entry is now marked reported.
  case accepted
  /// Correlated and refused; the error string is SB-33's `Ack.error` member.
  case rejected(error: String)
  /// Nothing was correlated — an empty token, or a token for an entry we no
  /// longer hold. Logged, and nothing else changes.
  case uncorrelated
}

/// Owns the sent-set, the outbox and their persistence.
final class ReportTracker {

  /// SB-35. Fixed, like every other limit in the spec: a bound that can be
  /// configured is a bound that gets raised in production.
  static let outboxCapacity = 200

  /// 4 × the seen set, matching Kotlin's `SENT_SET_CAPACITY`. A report key
  /// outlives its message id in the seen set (one message can carry several
  /// statuses), so the sent-set is allowed to remember proportionally more.
  static let sentSetCapacity = SeenSet.capacity * 4

  /// SB-33, `upstream_forward_failed`: bounded, so a permanently unreachable
  /// sink cannot make the outbox retry forever. The relay distinguishes it from
  /// a quota problem precisely because waiting does not help.
  static let maxForwardFailureRetries = 3

  private let store: SocketStateStore
  private let logger: SocketLogger
  private let random: RandomSource
  private let now: () -> Int64

  /// Oldest first: the eviction order when the outbox is full.
  private var pending: [PendingReport] = []
  /// Already reported, as "id:statusNumber" (SB-30). Persisted with the seen
  /// set so a restart cannot re-report a message the relay already counted.
  /// Bounded at ``sentSetCapacity`` with oldest-first eviction (Kotlin parity).
  private var sentKeys = SeenSet(limit: ReportTracker.sentSetCapacity)
  /// Keys handed to the transport and not yet answered. In memory on purpose:
  /// after a restart every entry is unsent again, which is the safe reading.
  private var inFlight: Set<String> = []

  /// Set whenever an Ack was refused, so the client can put it in `lastError`
  /// (SB-33: "every rejection MUST set lastError in state").
  var onRejection: ((String) -> Void)?

  init(store: SocketStateStore, logger: SocketLogger, random: RandomSource, now: @escaping () -> Int64) {
    self.store = store
    self.logger = logger
    self.random = random
    self.now = now
    self.pending = store.loadOutbox()
    self.sentKeys = SeenSet(limit: ReportTracker.sentSetCapacity, persisted: store.loadReportedKeys())
  }

  // MARK: - Queueing

  /// Queue a report, enforcing SB-30 (once per `(message_id, status)`) and
  /// SB-31 (never an empty id). A cross-channel dedupe hit reaches here too —
  /// it is acked, just not presented — and this dedupe is what keeps that
  /// single.
  ///
  /// - Returns: `true` when the report was queued. `false` means "already
  ///   reported", "already queued", or "not sendable" — in each case the caller
  ///   has nothing to do.
  @discardableResult
  func queue(
    messageId: String,
    sinchMessageId: String,
    status: SocketDeliveryStatus,
    reason: String = ""
  ) -> Bool {
    guard !messageId.isEmpty else {
      // SB-31. The relay refuses this as `missing_message_id`, so a report
      // that cannot name its message is logged, not sent.
      logger.log("dropping \(status.rawValue) report with an empty message_id: \(reason)")
      return false
    }
    let entry = PendingReport(
      messageId: messageId,
      sinchMessageId: sinchMessageId,
      status: status,
      reason: reason,
      attempts: 0,
      deferUntilMs: nil)
    let key = entry.sentKey
    guard !sentKeys.contains(key) else {
      logger.log("suppressing duplicate \(status.rawValue) report for \(messageId)")
      return false
    }
    guard !pending.contains(where: { $0.sentKey == key }) else {
      // Already queued: re-queueing would send it twice.
      return false
    }
    pending.append(entry)
    evictIfNeeded()
    persistOutbox()
    return true
  }

  /// SB-40: a pooled message that could not be turned into a message becomes a
  /// `FAILED` report whose reason is `"decode: <err>"`.
  @discardableResult
  func queueFailure(messageId: String, sinchMessageId: String, detail: String) -> Bool {
    queue(
      messageId: messageId,
      sinchMessageId: sinchMessageId,
      status: .failed,
      reason: "decode: \(detail)")
  }

  private func evictIfNeeded() {
    while pending.count > ReportTracker.outboxCapacity {
      let dropped = pending.removeFirst()
      logger.log(
        "outbox full (\(ReportTracker.outboxCapacity)); dropped oldest report "
          + "\(dropped.status.rawValue) for \(dropped.messageId)")
    }
  }

  // MARK: - Sending

  /// The reports to hand to the transport, in queue order.
  func reportsToSend(nowMs: Int64, mode: OutboxFlushMode) -> [PendingReport] {
    var out: [PendingReport] = []
    for entry in pending {
      if inFlight.contains(entry.sentKey) { continue }
      switch mode {
      case .all:
        if let deferUntilMs = entry.deferUntilMs, deferUntilMs > nowMs { continue }
        out.append(entry)
      case .deferredOnly:
        guard let deferUntilMs = entry.deferUntilMs, deferUntilMs <= nowMs else { continue }
        out.append(entry)
      case .forwardFailureRetryOnly:
        // SB-33: the bounded retry rides the poll tick. A deferred entry is
        // excluded on purpose — see the mode's comment.
        guard entry.deferUntilMs == nil, entry.attempts > 0 else { continue }
        out.append(entry)
      }
    }
    return out
  }

  /// Mark entries as handed to the transport, so a flush inside the same
  /// connection does not send them twice.
  func markSent(_ entries: [PendingReport]) {
    for entry in entries where !inFlight.contains(entry.sentKey) {
      inFlight.insert(entry.sentKey)
    }
  }

  /// The connection is gone: anything that was in flight has an unknown outcome
  /// and its Ack can never arrive, so it goes back to queued (SB-35).
  func connectionClosed() {
    inFlight.removeAll()
  }

  /// Number of reports waiting, for tests and diagnostics.
  var pendingCount: Int { pending.count }

  /// Keys already reported, oldest first, for persistence.
  var reportedKeys: [String] { sentKeys.persisted }

  // MARK: - Ack correlation

  /// Apply an `Ack` (SB-32, SB-33, SB-34).
  @discardableResult
  func handle(_ ack: Sinch_Push_Delivery_V1beta1_Ws_Ack) -> AckOutcome {
    let token = ack.ackToken
    guard !token.isEmpty else {
      // SB-32: uncorrelatable. Not "the report for the empty message id" —
      // an empty message_id yields an empty token, which is another reason the
      // token must never be parsed.
      logger.log("ack with an empty token is uncorrelatable; nothing changed")
      return .uncorrelated
    }
    guard let index = pending.firstIndex(where: { $0.ackToken == token }) else {
      logger.log("ack token \(token) matches no queued report; nothing changed")
      return .uncorrelated
    }
    if ack.accepted {
      let entry = pending.remove(at: index)
      // The only place `sentKeys` changes (insert + oldest-first eviction), so
      // the only place it is written.
      if sentKeys.insert(entry.sentKey) { persistSentKeys() }
      inFlight.remove(entry.sentKey)
      persistOutbox()
      return .accepted
    }
    return applyRejection(
      to: index,
      error: ack.error,
      // The correlation is whole-string, so `:` inside a message_id is fine and
      // the split below is only for the log line.
      messageId: String(token.prefix(while: { $0 != ":" })))
  }

  private func applyRejection(
    to index: Int,
    error: String,
    messageId: String
  ) -> AckOutcome {
    // SB-33: every rejection sets lastError, whatever the policy below.
    onRejection?(error.isEmpty ? "ack rejected (\(messageId))" : error)

    switch error {
    case "rate_limited":
      // Defer with backoff. Not the poll tick: the poll tick is what the relay
      // is shedding. The deferral uses the same full-jitter family as the
      // reconnect backoff so a throttled relay is not pressed from two
      // directions with unrelated cadences (SB-33's last paragraph).
      var entry = pending[index]
      entry.attempts += 1
      let delay = ReconnectBackoff.delayMs(attempts: entry.attempts, using: random)
      entry.deferUntilMs = now() + Int64(delay)
      pending[index] = entry
      inFlight.remove(entry.sentKey)
      persistOutbox()
      logger.log(
        "report \(entry.status.rawValue) for \(entry.messageId) deferred "
          + "\(delay)ms (rate_limited)")
      return .rejected(error: error)

    case "upstream_forward_failed":
      var entry = pending[index]
      entry.attempts += 1
      if entry.attempts > ReportTracker.maxForwardFailureRetries {
        pending.remove(at: index)
        inFlight.remove(entry.sentKey)
        persistOutbox()
        logger.log(
          "dropping \(entry.status.rawValue) report for \(entry.messageId) after "
            + "\(entry.attempts) forward failures")
        return .rejected(error: error)
      }
      // No deferral: the next poll tick retries this one (SB-33).
      entry.deferUntilMs = nil
      pending[index] = entry
      inFlight.remove(entry.sentKey)
      persistOutbox()
      logger.log(
        "report \(entry.status.rawValue) for \(entry.messageId) will retry on the "
          + "next poll (attempt \(entry.attempts))")
      return .rejected(error: error)

    case "unsupported_status":
      // Permanent for this (message_id, status) against this relay version.
      // Neither quota recovery nor waiting can make a status supported.
      let entry = pending.remove(at: index)
      inFlight.remove(entry.sentKey)
      persistOutbox()
      logger.log(
        "dropping \(entry.status.rawValue) report for \(entry.messageId): the relay "
          + "does not support this status")
      return .rejected(error: error)

    default:
      // Empty, absent, or a member this build does not know. Log only — never
      // clear, fail or retry a specific entry (SB-33's last row).
      logger.log("ack refused with error '\(error)'; no policy change")
      return .rejected(error: error)
    }
  }

  /// The `sinch_message_id` retained for a message we have queued a report for
  /// (RN-004: the report carries the original message's id, not the pooled one).
  /// `nil` when the message is not in the outbox.
  func sinchMessageId(for messageId: String) -> String? {
    pending.first(where: { $0.messageId == messageId })?.sinchMessageId
  }

  /// The earliest millisecond at which a deferred entry may be sent again, or
  /// `nil` when nothing is deferred. The client arms a one-shot timer for it,
  /// which is the only thing that retries a `rate_limited` report.
  func nextDeferral(nowMs: Int64) -> Int64? {
    pending.compactMap(\.deferUntilMs).filter { $0 > nowMs }.min()
  }

  // MARK: - Persistence

  // Split by what changed: the sent-set holds thousands of keys, so rewriting
  // it on every queue and rejection costs battery and I/O for nothing; it
  // changes only when an Ack is accepted.

  private func persistOutbox() {
    store.saveOutbox(pending)
  }

  private func persistSentKeys() {
    store.saveReportedKeys(sentKeys.persisted)
  }
}