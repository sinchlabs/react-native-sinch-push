//  SystemDependencies.swift — live implementations of the client seams.
//
//  Foundation only, so all of this compiles inside the SwiftPM harness as well
//  as in a host app. The one dependency on a real device — Keychain for the
//  auth token — is in `iOS/KeychainAuthTokenStore.swift`, because it needs the
//  Security framework and is the only implementation that is worth keeping off
//  a test host.
//
//  Everything here is a default: `SocketClient` takes its dependencies as
//  parameters and every test supplies fakes instead.

import Foundation

// MARK: - Scheduler

/// Serialises client work onto one queue and provides the timers.
///
/// One queue for both callbacks and timers is the whole point. The transport
/// delivers frames on its own thread and the poll/reconnect timers fire on the
/// dispatch queue, so without a single serial context a reconnect scheduled from
/// inside a frame handler could race the very handler that scheduled it.
final class DispatchScheduler: Scheduler {
  private let queue: DispatchQueue

  init(queue: DispatchQueue = DispatchQueue(label: "com.sinch.push.socket")) {
    self.queue = queue
  }

  func nowMs() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
  }

  func perform(_ work: @escaping () -> Void) {
    queue.async(execute: work)
  }

  func schedule(after delayMs: Int, _ work: @escaping () -> Void) -> ScheduledTask {
    let task = DispatchWorkItem(block: work)
    queue.asyncAfter(deadline: .now() + .milliseconds(max(0, delayMs)), execute: task)
    return DispatchScheduledTask(task)
  }
}

private final class DispatchScheduledTask: ScheduledTask {
  private let item: DispatchWorkItem
  init(_ item: DispatchWorkItem) { self.item = item }
  func cancel() { item.cancel() }
}

// MARK: - Random

/// `SystemRandomNumberGenerator`, wrapped so the backoff can be pinned in a test.
final class SystemRandomSource: RandomSource {
  func nextUnitDouble() -> Double {
    Double.random(in: 0..<1)
  }
}

// MARK: - Logging

/// `os_log`-free by design: a pod that logs to stderr shows up in a host app's
/// device log with no way to filter it, so the facade installs a logger that
/// can be silenced or redirected by the host.
final class PrintSocketLogger: SocketLogger {
  private let prefix: String
  private let sink: (String) -> Void

  init(prefix: String = "[SinchPushSocket]", sink: ((String) -> Void)? = nil) {
    self.prefix = prefix
    self.sink = sink ?? { print("\($0)") }
  }

  func log(_ line: String) {
    sink("\(prefix) \(line)")
  }
}

/// Discards everything. The default in the core, so an embedder that has its own
/// logging does not get ours for free.
final class SilentSocketLogger: SocketLogger {
  func log(_ line: String) {}
}

// MARK: - Store

/// `UserDefaults`-backed state, one key per slice.
///
/// Keys are namespaced so a host app's defaults cannot collide with them, and
/// every slice is written as JSON because `PendingReport` and
/// `SocketMessageEvent` are `Codable` and a plist would otherwise need a
/// hand-written mapper per release of the protocol.
final class UserDefaultsSocketStateStore: SocketStateStore {
  private enum Key {
    static let prefix = "com.sinch.push.socket."
    static let seen = prefix + "seenMessageIds"
    static let reported = prefix + "reportedKeys"
    static let lastSeen = prefix + "lastSeenMessageId"
    static let lastSeenEnqueuedAt = prefix + "lastSeenEnqueuedAtMs"
    static let outbox = prefix + "outbox"
    static let reportOutbox = prefix + "reportOutbox"
    static let messages = prefix + "pendingMessages"
    static let configuration = prefix + "configuration"
  }

  private let defaults: UserDefaults
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadSeenMessageIDs() -> [String] {
    load([String].self, Key.seen) ?? []
  }

  func saveSeenMessageIDs(_ ids: [String]) {
    save(ids, Key.seen)
  }

  func loadReportedKeys() -> [String] {
    load([String].self, Key.reported) ?? []
  }

  func saveReportedKeys(_ keys: [String]) {
    save(keys, Key.reported)
  }

  func loadLastSeenMessageID() -> String {
    defaults.string(forKey: Key.lastSeen) ?? ""
  }

  func saveLastSeenMessageID(_ id: String) {
    defaults.set(id, forKey: Key.lastSeen)
  }

  func loadLastSeenEnqueuedAtMs() -> Int64 {
    Int64(defaults.integer(forKey: Key.lastSeenEnqueuedAt))
  }

  func saveLastSeenEnqueuedAtMs(_ ms: Int64) {
    defaults.set(Int(ms), forKey: Key.lastSeenEnqueuedAt)
  }

  func loadOutbox() -> [PendingReport] {
    load([PendingReport].self, Key.outbox) ?? []
  }

  func saveOutbox(_ reports: [PendingReport]) {
    save(reports, Key.outbox)
  }

  func loadReportOutbox() -> [ReportOutboxEntry] {
    load([ReportOutboxEntry].self, Key.reportOutbox) ?? []
  }

  func saveReportOutbox(_ entries: [ReportOutboxEntry]) {
    save(entries, Key.reportOutbox)
  }

  func loadPendingMessages() -> [SocketMessageEvent] {
    load([SocketMessageEvent].self, Key.messages) ?? []
  }

  func savePendingMessages(_ messages: [SocketMessageEvent]) {
    save(messages, Key.messages)
  }

  func loadConfiguration() -> PersistedSocketConfiguration? {
    load(PersistedSocketConfiguration.self, Key.configuration)
  }

  func saveConfiguration(_ configuration: PersistedSocketConfiguration) {
    save(configuration, Key.configuration)
  }

  func clearConfiguration() {
    defaults.removeObject(forKey: Key.configuration)
  }

  private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
    guard let data = defaults.data(forKey: key) else { return nil }
    // A decode failure means a format this build cannot read. Dropping the
    // slice is the safe reading: the worst case is a re-delivered message,
    // which the relay tolerates, whereas keeping a half-read one is not a state
    // anything else could act on.
    return try? decoder.decode(type, from: data)
  }

  private func save<T: Encodable>(_ value: T, _ key: String) {
    guard let data = try? encoder.encode(value) else { return }
    defaults.set(data, forKey: key)
  }
}

/// The store used by tests, and the store to use where `UserDefaults` is not
/// available (a unit test host, a command-line tool).
///
/// It is also what makes the "outbox survives a client restart" test honest:
/// the same instance is handed to a *new* client, exactly as a real restart
/// hands the same `UserDefaults` to a new process.
final class InMemorySocketStateStore: SocketStateStore {
  private var seen: [String] = []
  private var reported: [String] = []
  private var lastSeen = ""
  private var lastSeenEnqueuedAt: Int64 = 0
  private var outbox: [PendingReport] = []
  private var reportOutbox: [ReportOutboxEntry] = []
  private var messages: [SocketMessageEvent] = []
  private var configuration: PersistedSocketConfiguration?

  /// Counts saves, so a test can assert that a mutation was made durable.
  private(set) var saveCount = 0

  init() {}

  func loadSeenMessageIDs() -> [String] { seen }
  func saveSeenMessageIDs(_ ids: [String]) {
    seen = ids
    saveCount += 1
  }

  func loadReportedKeys() -> [String] { reported }
  func saveReportedKeys(_ keys: [String]) {
    reported = keys
    saveCount += 1
  }

  func loadLastSeenMessageID() -> String { lastSeen }
  func saveLastSeenMessageID(_ id: String) {
    lastSeen = id
    saveCount += 1
  }

  func loadLastSeenEnqueuedAtMs() -> Int64 { lastSeenEnqueuedAt }
  func saveLastSeenEnqueuedAtMs(_ ms: Int64) {
    lastSeenEnqueuedAt = ms
    saveCount += 1
  }

  func loadOutbox() -> [PendingReport] { outbox }
  func saveOutbox(_ reports: [PendingReport]) {
    outbox = reports
    saveCount += 1
  }

  func loadReportOutbox() -> [ReportOutboxEntry] { reportOutbox }
  func saveReportOutbox(_ entries: [ReportOutboxEntry]) {
    reportOutbox = entries
    saveCount += 1
  }

  func loadPendingMessages() -> [SocketMessageEvent] { messages }
  func savePendingMessages(_ value: [SocketMessageEvent]) {
    messages = value
    saveCount += 1
  }

  func loadConfiguration() -> PersistedSocketConfiguration? { configuration }
  func saveConfiguration(_ value: PersistedSocketConfiguration) {
    configuration = value
    saveCount += 1
  }

  func clearConfiguration() {
    configuration = nil
    saveCount += 1
  }
}

/// A token store that only lives in memory. The right default for tests and
/// wrong for a device — a real app must use the Keychain.
final class InMemoryAuthTokenStore: AuthTokenStore {
  private var token: String?

  init(token: String? = nil) {
    self.token = token
  }

  func loadToken() -> String? { token }
  func saveToken(_ token: String) { self.token = token }
  func clearToken() { token = nil }
}

// MARK: - Notifications

/// Posts nothing. The core's default: a host that wants local notifications
/// installs `iOS/SocketNotificationPresenter.swift`.
final class NoopNotificationPresenter: NotificationPresenting {
  var handlerRegistered: Bool = false

  func post(_ message: SocketMessageEvent, alerting: Bool, completion: @escaping (Bool) -> Void) {
    completion(false)
  }
}

/// Finds nothing delivered. The core's default, and what a platform without a
/// notification centre gets: the socket then always posts (SB-65).
final class NoDeliveredNotifications: DeliveredNotificationLookup {
  func isDelivered(identifier: String, completion: @escaping (Bool) -> Void) {
    completion(false)
  }
}
