//  ReportStorage.swift — the files the app and the extension share.
//
//  Two files in one directory (the App Group container when there is one, an
//  app-private directory otherwise):
//    * session.json — the mirrored credential (``SharedReportSession``)
//    * reports.json — the sent / in-flight / retry markers (``ReportMarkerStore``)
//
//  Why files in the App Group container and not a shared Keychain access group:
//  the container needs only the App Group both targets already have, while a
//  Keychain group also needs the `keychain-access-groups` entitlement and the
//  team-prefixed group string resolved at runtime. The JWT is the device-scoped
//  credential the app already keeps in the Keychain, never the HMAC secret.
//  Files are written with `completeUntilFirstUserAuthentication` — the same
//  availability as the app's own `AfterFirstUnlock` Keychain item, which is what
//  an extension needs to run while the device is locked — and are excluded from
//  backups. The marker file is read-modify-written under an `flock`, because the
//  app and the extension are different processes. A third file, sessions.json,
//  lists the extension's background sessions that still have uploads running
//  (``ReportSessionRegistry``), so the app can reconnect to them on launch.
//
//  The lock lives in the App Group container, and a process that is suspended while
//  holding a lock on a file there is killed by the system (0xdead10cc). So the lock is
//  only ever tried (never waited for indefinitely), and the app process holds a
//  background task for as long as it has the lock.

import Foundation
#if canImport(UIKit) && !SINCH_PUSH_EXTENSION
import UIKit
#endif

enum ReportDirectory {
  /// The App Group container's `sinch-push` directory, or `nil` when the group is not usable.
  static func shared(appGroup: String, fileManager: FileManager = .default) -> URL? {
    guard !appGroup.isEmpty,
      let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    else { return nil }
    return prepared(container.appendingPathComponent("sinch-push", isDirectory: true), fileManager)
  }

  /// The app's own directory, for an app without an App Group.
  static func appPrivate(fileManager: FileManager = .default) -> URL? {
    guard
      let support = try? fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return nil }
    return prepared(support.appendingPathComponent("com.sinch.push", isDirectory: true), fileManager)
  }

  private static func prepared(_ directory: URL, _ fileManager: FileManager) -> URL? {
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    var url = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
    return directory
  }
}

private func writeProtected(_ data: Data, to url: URL) throws {
  #if os(iOS) || os(tvOS) || os(watchOS)
  try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  #else
  try data.write(to: url, options: .atomic)
  #endif
}

/// The mirrored credential.
final class SharedReportSessionStore {
  private let url: URL

  init(directory: URL) {
    url = directory.appendingPathComponent("session.json")
  }

  func load() -> SharedReportSession? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(SharedReportSession.self, from: data)
  }

  @discardableResult
  func save(_ session: SharedReportSession) -> Bool {
    guard let data = try? JSONEncoder().encode(session) else { return false }
    do {
      try writeProtected(data, to: url)
      return true
    } catch {
      return false
    }
  }

  func clear() {
    try? FileManager.default.removeItem(at: url)
  }
}

/// The `flock` the app and the extension serialise their read-modify-writes with, plus a lock
/// for the threads of one process.
final class CrossProcessLock {
  /// How long a busy lock is waited for: 50 tries 10 ms apart.
  static let attempts = 50
  static let retryDelayMicroseconds: UInt32 = 10_000

  private let url: URL
  private let processLock = NSLock()

  init(directory: URL) {
    url = directory.appendingPathComponent("reports.lock")
  }

  /// Runs `body` with the file lock held; `nil` only when the lock file cannot be opened.
  /// When another process keeps the lock past the retry window `body` runs without it
  /// (best effort: a rare lost update is cheaper than blocking, and a blocked process that gets
  /// suspended with the lock is killed).
  func withLock<T>(_ body: () -> T) -> T? {
    processLock.lock()
    defer { processLock.unlock() }
    let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return nil }
    let background = ProcessAssertion.begin()
    let locked = acquire(fd)
    defer {
      if locked { flock(fd, LOCK_UN) }
      close(fd)
      ProcessAssertion.end(background)
    }
    if !locked { NSLog("[SinchPush] report store lock is busy; continuing without it") }
    return body()
  }

  private func acquire(_ fd: Int32) -> Bool {
    for attempt in 0..<Self.attempts {
      if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
      if errno != EWOULDBLOCK && errno != EINTR { return false }
      if attempt < Self.attempts - 1 { usleep(Self.retryDelayMicroseconds) }
    }
    return false
  }
}

/// A background task around work that holds the cross-process lock, so the app is not suspended
/// holding it. Only the app process has `UIApplication`: the extension (built with
/// `SINCH_PUSH_EXTENSION`, see the extension podspec) runs for a few seconds and is not suspended
/// mid-call.
enum ProcessAssertion {
  #if canImport(UIKit) && !SINCH_PUSH_EXTENSION
  /// The background task, ended once: by the expiration handler (main queue) or by the caller,
  /// whichever comes first.
  final class Token {
    private let lock = NSLock()
    private var identifier = UIBackgroundTaskIdentifier.invalid

    fileprivate func set(_ value: UIBackgroundTaskIdentifier) {
      lock.lock()
      identifier = value
      lock.unlock()
    }

    fileprivate func end() {
      lock.lock()
      let value = identifier
      identifier = .invalid
      lock.unlock()
      if value != .invalid { UIApplication.shared.endBackgroundTask(value) }
    }
  }

  static func begin() -> Token {
    let token = Token()
    token.set(UIApplication.shared.beginBackgroundTask(withName: "com.sinch.push.reports") { token.end() })
    return token
  }

  static func end(_ token: Token) {
    token.end()
  }
  #else
  static func begin() -> Int { 0 }
  static func end(_ token: Int) {}
  #endif
}

enum ReportMarkerState: String, Codable {
  /// An upload of the report is running (or was, and never finished).
  case inFlight
  /// Acknowledged by the server, or dropped for good.
  case sent
  /// An upload failed, or none was possible: still to be reported by the app.
  case retry
}

struct ReportMarker: Codable, Equatable {
  var messageId: String
  var subscriberId: String
  var state: ReportMarkerState
  /// When `state` was set.
  var atMs: Int64
  var enqueuedAtMs: Int64

  var key: ReportKey { ReportKey(messageId: messageId, subscriberId: subscriberId) }
  var entry: ReportEntry {
    ReportEntry(messageId: messageId, subscriberId: subscriberId, enqueuedAtMs: enqueuedAtMs)
  }
}

/// Which reports were already sent, are being sent, or still need sending — shared by the
/// extension, the app's background uploads and the JS outbox flush so none re-reports another's.
final class ReportMarkerStore {
  /// A report is as old as a queued one may get (matches the JS outbox TTL).
  static let retention: Int64 = 72 * 60 * 60 * 1000
  /// An upload that never reported back (killed, cancelled) stops excluding its report after this.
  static let inFlightTTL: Int64 = 30 * 60 * 1000
  static let capacity = 2000

  private let url: URL
  private let lock: CrossProcessLock
  private let now: () -> Int64

  init(directory: URL, now: @escaping () -> Int64 = currentTimeMs) {
    url = directory.appendingPathComponent("reports.json")
    lock = CrossProcessLock(directory: directory)
    self.now = now
  }

  /// Reports that must not be reported again right now: sent, or being sent.
  func excludedKeys() -> Set<ReportKey> {
    transaction { markers in Set(markers.filter(isExcluding).map(\.key)) } ?? []
  }

  /// Reports acknowledged (or dropped for good).
  func sentKeys() -> Set<ReportKey> {
    transaction { markers in Set(markers.filter { $0.state == .sent }.map(\.key)) } ?? []
  }

  /// Reports an earlier attempt left for the app to send.
  func retryEntries() -> [ReportEntry] {
    transaction { markers in markers.filter { $0.state == .retry }.map(\.entry) } ?? []
  }

  /// Marks the entries in flight and returns the ones this caller now owns; an entry that
  /// is already sent or in flight belongs to someone else and is left out.
  func claim(_ entries: [ReportEntry]) -> [ReportEntry] {
    transaction(write: true) { markers in
      var claimed: [ReportEntry] = []
      for entry in entries {
        if let existing = markers.firstIndex(where: { $0.key == entry.key }) {
          if isExcluding(markers[existing]) { continue }
          markers.remove(at: existing)
        }
        markers.append(marker(entry, .inFlight))
        claimed.append(entry)
      }
      return claimed
    } ?? []
  }

  func markSent(_ keys: [ReportKey], entries: [ReportEntry] = []) {
    set(.sent, keys: keys, entries: entries)
  }

  /// Keeps the reports for the app to send. Never downgrades a sent report.
  func markRetry(_ keys: [ReportKey], entries: [ReportEntry] = []) {
    set(.retry, keys: keys, entries: entries)
  }

  /// Forgets the reports waiting for a retry (an identity change drops its queue).
  func clearRetries() {
    _ = transaction(write: true) { markers in markers.removeAll { $0.state == .retry } }
  }

  private func set(_ state: ReportMarkerState, keys: [ReportKey], entries: [ReportEntry]) {
    guard !keys.isEmpty else { return }
    _ = transaction(write: true) { markers in
      for key in keys {
        let known = entries.first { $0.key == key }
        if let index = markers.firstIndex(where: { $0.key == key }) {
          if markers[index].state == .sent && state != .sent { continue }
          markers[index].state = state
          markers[index].atMs = now()
        } else {
          let entry = known ?? ReportEntry(messageId: key.messageId, subscriberId: key.subscriberId, enqueuedAtMs: now())
          markers.append(marker(entry, state))
        }
      }
    }
  }

  private func marker(_ entry: ReportEntry, _ state: ReportMarkerState) -> ReportMarker {
    ReportMarker(
      messageId: entry.messageId, subscriberId: entry.subscriberId, state: state, atMs: now(),
      enqueuedAtMs: entry.enqueuedAtMs)
  }

  private func isExcluding(_ marker: ReportMarker) -> Bool {
    switch marker.state {
    case .sent: return true
    case .inFlight: return now() - marker.atMs < Self.inFlightTTL
    case .retry: return false
    }
  }

  /// Runs `body` over the markers under the cross-process lock and persists them when `write` is set.
  private func transaction<T>(write: Bool = false, _ body: (inout [ReportMarker]) -> T) -> T? {
    lock.withLock {
      let before = load()
      var markers = prune(before)
      let result = body(&markers)
      let pruned = prune(markers)
      if write || pruned != before { save(pruned) }
      return result
    }
  }

  private func load() -> [ReportMarker] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([ReportMarker].self, from: data)) ?? []
  }

  private func save(_ markers: [ReportMarker]) {
    guard let data = try? JSONEncoder().encode(markers) else { return }
    try? writeProtected(data, to: url)
  }

  /// Drops what is too old to matter and keeps the newest `capacity`. An in-flight upload that
  /// never reported back becomes a retry, so a report only the extension knew about is not lost.
  private func prune(_ markers: [ReportMarker]) -> [ReportMarker] {
    let cutoff = now() - Self.retention
    var kept = markers.filter { $0.atMs >= cutoff }.map { marker -> ReportMarker in
      var marker = marker
      if marker.state == .inFlight && now() - marker.atMs >= Self.inFlightTTL { marker.state = .retry }
      return marker
    }
    if kept.count > Self.capacity { kept = Array(kept.suffix(Self.capacity)) }
    return kept
  }
}


/// The Notification Service Extension's background sessions that still have uploads running.
///
/// Each extension process uploads in its own session (`com.sinch.push.reports.nse.<uuid>`), and
/// the results are delivered to the app only when it reconnects to the session by identifier.
/// iOS does not relaunch a force-quit app for that, so the extension records the identifier here
/// before it starts uploading and the app recreates every listed session when it launches.
/// The app removes an entry once the session has delivered its events.
final class ReportSessionRegistry {
  /// An entry not used for this long is dropped even if nobody removed it.
  static let maxAge: Int64 = 7 * 24 * 60 * 60 * 1000

  private struct Entry: Codable, Equatable {
    var identifier: String
    var atMs: Int64
  }

  private let url: URL
  private let lock: CrossProcessLock
  private let now: () -> Int64

  init(directory: URL, now: @escaping () -> Int64 = currentTimeMs) {
    url = directory.appendingPathComponent("sessions.json")
    lock = CrossProcessLock(directory: directory)
    self.now = now
  }

  /// Lists `identifier`, or stamps it as used now when it is listed already. The extension calls
  /// this on every upload: a session that is still in use is not the app's to recreate or reap.
  func register(_ identifier: String) {
    _ = update { entries in
      if let index = entries.firstIndex(where: { $0.identifier == identifier }) {
        entries[index].atMs = now()
      } else {
        entries.append(Entry(identifier: identifier, atMs: now()))
      }
    }
  }

  func unregister(_ identifier: String) {
    _ = update { entries in entries.removeAll { $0.identifier == identifier } }
  }

  func identifiers() -> [String] {
    update { entries in entries.map(\.identifier) } ?? []
  }

  /// The listed identifiers with when the extension last used each.
  func lastUsed() -> [String: Int64] {
    update { entries in Dictionary(entries.map { ($0.identifier, $0.atMs) }, uniquingKeysWith: max) } ?? [:]
  }

  /// When `identifier` was last registered (used by an upload), `nil` if it is not listed.
  func lastUsedAtMs(_ identifier: String) -> Int64? {
    update { entries in entries.first { $0.identifier == identifier }?.atMs } ?? nil
  }

  private func update<T>(_ body: (inout [Entry]) -> T) -> T? {
    lock.withLock {
      let before = load()
      let cutoff = now() - Self.maxAge
      var entries = before.filter { $0.atMs >= cutoff }
      let result = body(&entries)
      if entries != before { save(entries) }
      return result
    }
  }

  private func load() -> [Entry] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }

  private func save(_ entries: [Entry]) {
    guard let data = try? JSONEncoder().encode(entries) else { return }
    try? writeProtected(data, to: url)
  }
}
