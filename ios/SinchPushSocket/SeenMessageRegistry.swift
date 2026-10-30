//  SeenMessageRegistry.swift — the one dedupe set per process (RN-045, SB-28,
//  SB-64).
//
//  One shared, bounded, persisted set: the client marks
//  `PooledMessage.message_id`, the push path marks the `sinch.push.message_id`
//  a Sinch push carries (the same id: sinch-push's trackingId), and whichever
//  channel is first wins.
//
//  Pure Swift and React-free on purpose — `SinchPush.mm` reaches it only through
//  the facade, and the tests drive it with a fake store.

import Foundation

/// A lock-protected, persisted ``SeenSet``.
///
/// Thread-safe because the callers do not share a queue: the socket client runs
/// on its scheduler's queue, `willPresent` and `didReceiveRemoteNotification`
/// on whatever queue UIKit picks.
///
/// The persisted key is the one the client has always used
/// (`com.sinch.push.socket.seenMessageIds`, through ``SocketStateStore``), so an
/// existing set loads into the current capacity with no migration step.
final class SeenMessageRegistry {
  private let store: SocketStateStore
  private let lock = NSLock()
  private var seen = SeenSet()
  /// Read lazily, on first use: a client constructed over a store that already
  /// holds ids (the restart case) must see them, and a store that is written to
  /// between construction and first use must not be overwritten by a stale read.
  private var didLoad = false

  init(store: SocketStateStore) {
    self.store = store
  }

  /// Returns `true` for a newly recorded non-empty ID. `false` suppresses
  /// presentation; socket acknowledgement policy is handled by the caller.
  ///
  /// The set is persisted before this returns, because SB-62 requires the id to
  /// be durable before the `DELIVERED` report goes out.
  @discardableResult
  func markSeen(_ id: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    loadIfNeeded()
    guard seen.insert(id) else { return false }
    store.saveSeenMessageIDs(seen.persisted)
    return true
  }

  /// Whether `id` has been marked, without marking it.
  func contains(_ id: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    loadIfNeeded()
    return seen.contains(id)
  }

  /// Oldest first; for diagnostics and tests.
  var snapshot: [String] {
    lock.lock()
    defer { lock.unlock() }
    loadIfNeeded()
    return seen.persisted
  }

  private func loadIfNeeded() {
    guard !didLoad else { return }
    didLoad = true
    seen = SeenSet(persisted: store.loadSeenMessageIDs())
  }
}
