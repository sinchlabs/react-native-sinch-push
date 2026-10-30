//  ReportOutbox.swift — persisted queue of provider-push DELIVERED reports, flushed by JS.
//  Separate from ``ReportTracker``: these go to the push API, not the relay.

import Foundation

/// A lock-protected, persisted queue of provider-push reports.
final class ReportOutbox {
  /// A full outbox drops its oldest entry.
  static let capacity = 500

  private let store: SocketStateStore
  /// Wall-clock milliseconds since the Unix epoch, for `enqueuedAtMs`.
  private let now: () -> Int64
  private let lock = NSLock()
  private var entries: [ReportOutboxEntry] = []
  /// Read lazily so a store written after construction is not overwritten by a stale read.
  private var didLoad = false

  init(store: SocketStateStore, now: @escaping () -> Int64) {
    self.store = store
    self.now = now
  }

  /// `false` when `(messageId, subscriberId)` is already queued; the original `enqueuedAtMs` is kept.
  @discardableResult
  func enqueue(messageId: String, subscriberId: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    loadIfNeeded()
    guard !messageId.isEmpty, !subscriberId.isEmpty else { return false }
    let key = (messageId, subscriberId)
    guard !entries.contains(where: { ($0.messageId, $0.subscriberId) == key }) else { return false }
    if entries.count >= Self.capacity { entries.removeFirst() }
    entries.append(
      ReportOutboxEntry(messageId: messageId, subscriberId: subscriberId, enqueuedAtMs: now()))
    store.saveReportOutbox(entries)
    return true
  }

  /// The queued reports, oldest first.
  func snapshot() -> [ReportOutboxEntry] {
    lock.lock()
    defer { lock.unlock() }
    loadIfNeeded()
    return entries
  }

  /// Drops the reports with the given keys.
  func remove(keys: [(messageId: String, subscriberId: String)]) {
    lock.lock()
    defer { lock.unlock() }
    loadIfNeeded()
    guard !keys.isEmpty else { return }
    entries.removeAll { entry in
      keys.contains { $0.messageId == entry.messageId && $0.subscriberId == entry.subscriberId }
    }
    store.saveReportOutbox(entries)
  }

  /// Drops every queued report.
  func clear() {
    lock.lock()
    defer { lock.unlock() }
    loadIfNeeded()
    entries.removeAll()
    store.saveReportOutbox(entries)
  }

  private func loadIfNeeded() {
    guard !didLoad else { return }
    didLoad = true
    entries = store.loadReportOutbox()
    if entries.count > Self.capacity {
      entries = Array(entries.suffix(Self.capacity))
    }
  }
}
