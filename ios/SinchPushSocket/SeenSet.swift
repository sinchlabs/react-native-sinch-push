//  SeenSet.swift — the bounded dedupe set (RN-003, RN-045, SB-28).
//
//  Insertion-ordered and bounded at 2000. "LRU" here means *least recently
//  inserted*: the reference TypeScript client uses a `Set` and drops the oldest
//  id when one more than the capacity arrives (`client.ts:seen`), and a re-read
//  of an existing id does not refresh its position. Bounded is the point — an
//  unbounded set leaks slowly on a long-lived connection, and the cost of the
//  bound (an evicted id can be delivered twice) is the trade the spec accepts.

import Foundation

/// A bounded, insertion-ordered set of processed `message_id`s.
struct SeenSet: Equatable {
  /// SB-28, and it is a fixed number rather than configuration: the spec
  /// requires the limit to be a constant so it cannot be derived at runtime.
  /// 2000: one set serves the socket, FCM and APNs, so it has to outlast what
  /// all three channels can re-offer.
  static let capacity = 2000

  /// Newest last. The eviction order and the persisted order are the same list,
  /// which is why persistence is just this array.
  private(set) var order: [String] = []
  private var index: Set<String> = []
  /// The bound this instance enforces. ``capacity`` for the seen set; the
  /// report sent-set reuses the type with a larger one.
  private let limit: Int

  init() { limit = SeenSet.capacity }

  /// An empty set with its own bound, restored from `persisted` (oldest first).
  /// Unlike ``init(persisted:)`` an over-long list keeps its *newest* entries.
  init(limit: Int, persisted: [String] = []) {
    self.limit = limit
    for id in persisted {
      insert(id)
    }
  }

  /// Restore from persisted state. Anything beyond ``capacity`` is dropped from
  /// the front rather than rejected, so a store written by a build with a
  /// different bound still loads.
  init(persisted: [String]) {
    limit = SeenSet.capacity
    for id in persisted.prefix(SeenSet.capacity) {
      insert(id)
    }
  }

  var count: Int { order.count }

  /// Whether `id` has already been processed.
  func contains(_ id: String) -> Bool {
    index.contains(id)
  }

  /// Returns `true` for a newly recorded non-empty ID. `false` suppresses
  /// presentation; socket acknowledgement policy is handled by the caller.
  @discardableResult
  mutating func insert(_ id: String) -> Bool {
    guard !id.isEmpty else { return false }
    guard index.insert(id).inserted else { return false }
    order.append(id)
    evictIfNeeded()
    return true
  }

  /// Oldest first — the order ``init(persisted:)`` expects.
  var persisted: [String] { order }

  private mutating func evictIfNeeded() {
    while order.count > limit {
      let oldest = order.removeFirst()
      index.remove(oldest)
    }
  }
}