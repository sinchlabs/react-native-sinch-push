//  ReportCenter.swift — the app side of the report path: what the library's
//  native module asks of the shared stores and the background uploader.
//
//  `SinchPushReports` (the @objc face used by SinchPush.mm) forwards here. All
//  state is in files, so the answers are the same in the app and after a
//  relaunch for a background session. The in-process state (the App Group, the
//  sessions this process created) is only touched on one serial queue: the module
//  queue, the launch-time resume and the application delegate all arrive from
//  different threads.

import Foundation

/// What a background wake gets back from ``ReportCenter/uploadInBackground(outbox:)``.
enum BackgroundUploadResult: Int {
  /// Native cannot upload (no mirrored token / no session): JS has to flush.
  case unavailable = 0
  /// A background URLSession has the reports; the wake may finish now.
  case handedOff = 1
  /// Nothing needs sending (the extension or an earlier upload has it all).
  case nothingToSend = 2
}

final class ReportCenter {
  static let appGroupDefaultsKey = "com.sinch.push.reports.appGroup"

  private let defaults: UserDefaults
  private let now: () -> Int64
  private let makeUploader: (String, String?, URL) -> ReportScheduling
  private let sharedDirectory: (String) -> URL?
  private let privateDirectory: () -> URL?

  init(
    defaults: UserDefaults = .standard,
    now: @escaping () -> Int64 = currentTimeMs,
    sharedDirectory: @escaping (String) -> URL? = { ReportDirectory.shared(appGroup: $0) },
    privateDirectory: @escaping () -> URL? = { ReportDirectory.appPrivate() },
    makeUploader: @escaping (String, String?, URL) -> ReportScheduling = {
      ReportUploader.shared(identifier: $0, appGroup: $1, directory: $2)
    }
  ) {
    self.defaults = defaults
    self.now = now
    self.sharedDirectory = sharedDirectory
    self.privateDirectory = privateDirectory
    self.makeUploader = makeUploader
  }

  static let live = ReportCenter()

  /// An extension session used this recently may still have a live extension process behind it
  /// (iOS keeps one running between pushes), and a session identifier belongs to one process:
  /// the app leaves it alone and picks its results up on a later launch.
  static let extensionActiveWindowMs: Int64 = 15 * 60 * 1000

  private let queue = DispatchQueue(label: "com.sinch.push.reports.center")
  /// Set once ``configure(appGroup:)`` ran; guarded by `queue`.
  private var configured = false

  private func serial<T>(_ body: () -> T) -> T { queue.sync(execute: body) }

  // MARK: Configuration

  private var appGroup: String? {
    let value = defaults.string(forKey: Self.appGroupDefaultsKey)
    return value?.isEmpty == false ? value : nil
  }

  /// The directory reports live in: the App Group's when configured and reachable, else the app's own.
  private var directory: URL? {
    if let group = appGroup {
      if let shared = sharedDirectory(group) { return shared }
      NSLog("[SinchPush] App Group '%@' is not reachable; check the entitlement. Falling back to app-private report storage.", group)
    }
    return privateDirectory()
  }

  /// Sets (or, with `nil`, drops) the App Group. The credential mirrored into a group that is
  /// no longer configured is removed from it, and so is the app-private copy once a group is set
  /// (it would keep the token past `setSession(nil)`, which clears only where it writes).
  /// Also reconnects to the background sessions that may have results waiting.
  func configure(appGroup newGroup: String?) {
    serial {
      configured = true
      applyConfiguration(appGroup: newGroup)
      resumeSessionsNow()
    }
  }

  private func applyConfiguration(appGroup newGroup: String?) {
    let group = (newGroup?.isEmpty == false) ? newGroup : nil
    let old = appGroup
    if group != nil, let dir = privateDirectory() { SharedReportSessionStore(directory: dir).clear() }
    if old != group {
      if let old, let dir = sharedDirectory(old) { SharedReportSessionStore(directory: dir).clear() }
      if let group { defaults.set(group, forKey: Self.appGroupDefaultsKey) } else { defaults.removeObject(forKey: Self.appGroupDefaultsKey) }
    }
  }

  /// Stores the credential where the extension reads it; `nil` removes it from every place it may be.
  func setSession(_ session: SharedReportSession?) {
    serial { setSessionNow(session) }
  }

  private func setSessionNow(_ session: SharedReportSession?) {
    if let session {
      guard let directory else { return }
      SharedReportSessionStore(directory: directory).save(session)
      return
    }
    if let dir = privateDirectory() { SharedReportSessionStore(directory: dir).clear() }
    if let group = appGroup, let dir = sharedDirectory(group) { SharedReportSessionStore(directory: dir).clear() }
  }

  // MARK: Background sessions

  /// Creates the app's background sessions now, so the system delivers the results of uploads that
  /// finished while the app was not running: the app's own, and the extensions' still listed in the
  /// App Group. Without this the results arrive only if iOS relaunches the app for them, which it
  /// does not for a force-quit app. Safe to call repeatedly.
  func resumeSessions() {
    serial { resumeSessionsNow() }
  }

  /// The launch-time resume: does nothing once ``configure(appGroup:)`` ran (it resumes with the
  /// group it was given, which the persisted one this would read may predate).
  func resumeSessionsAtLaunch() {
    serial {
      guard !configured else { return }
      resumeSessionsNow()
    }
  }

  private func resumeSessionsNow() {
    guard let directory else { return }
    let group = appGroup
    (makeUploader(ReportUploader.appIdentifier, group, directory) as? ReportSessionHandling)?.resume()
    guard group != nil else { return }  // no App Group: no extension
    let lastUsed = ReportSessionRegistry(directory: directory, now: now).lastUsed()
    var identifiers = Set(lastUsed.keys)
    identifiers.insert(ReportUploader.extensionIdentifierPrefix)  // sessions of earlier builds
    for identifier in identifiers.sorted() {
      if let used = lastUsed[identifier], now() - used < Self.extensionActiveWindowMs { continue }
      guard let uploader = makeUploader(identifier, group, directory) as? ReportSessionHandling else { continue }
      uploader.retireWhenFinished()
      uploader.resume()
    }
  }

  // MARK: Outbox view

  /// The app outbox without what is sent or being sent, plus the reports the extension left to retry.
  func pendingReports(outbox: [ReportEntry]) -> [ReportEntry] {
    serial { pendingReportsNow(outbox: outbox) }
  }

  private func pendingReportsNow(outbox: [ReportEntry]) -> [ReportEntry] {
    guard let directory else { return outbox }
    let markers = ReportMarkerStore(directory: directory, now: now)
    let excluded = markers.excludedKeys()
    var pending = outbox.filter { !excluded.contains($0.key) }
    for entry in markers.retryEntries() where !pending.contains(entry) && !outbox.contains(entry) {
      pending.append(entry)
    }
    // Oldest first; entries queued in the same millisecond keep their order.
    return pending.enumerated().sorted { ($0.element.enqueuedAtMs, $0.offset) < ($1.element.enqueuedAtMs, $1.offset) }.map(\.element)
  }

  /// Outbox entries that already went out, for the caller to drop from the outbox.
  func sentReports(outbox: [ReportEntry]) -> [ReportEntry] {
    serial {
      guard let directory else { return [] }
      let sent = ReportMarkerStore(directory: directory, now: now).sentKeys()
      return outbox.filter { sent.contains($0.key) }
    }
  }

  /// JS reported these (and removed them from the outbox): nobody reports them again.
  func markReported(_ keys: [ReportKey]) {
    serial {
      guard let directory else { return }
      ReportMarkerStore(directory: directory, now: now).markSent(keys)
    }
  }

  func clearRetries() {
    serial {
      guard let directory else { return }
      ReportMarkerStore(directory: directory, now: now).clearRetries()
    }
  }

  // MARK: Background upload

  /// Uploads the pending reports with the app's background session, if there is a usable mirrored credential.
  func uploadInBackground(outbox: [ReportEntry]) -> BackgroundUploadResult {
    serial { uploadInBackgroundNow(outbox: outbox) }
  }

  private func uploadInBackgroundNow(outbox: [ReportEntry]) -> BackgroundUploadResult {
    guard let directory else { return .unavailable }
    let nowMs = now()
    let cutoff = nowMs - ReportMarkerStore.retention
    // Expired entries are left for the JS flush to drop.
    let pending = pendingReportsNow(outbox: outbox).filter { $0.enqueuedAtMs >= cutoff }
    if pending.isEmpty { return .nothingToSend }
    guard let session = SharedReportSessionStore(directory: directory).load(), session.isUsable(nowMs: nowMs) else {
      return .unavailable
    }
    let markers = ReportMarkerStore(directory: directory, now: now)
    let claimed = markers.claim(pending)
    if claimed.isEmpty { return .nothingToSend }
    let uploader = makeUploader(ReportUploader.appIdentifier, appGroup, directory)
    if uploader.upload(entries: claimed, session: session) { return .handedOff }
    markers.markRetry(claimed.map(\.key), entries: claimed)
    return .unavailable
  }

  // MARK: Background session events

  /// `application:handleEventsForBackgroundURLSession:`. `true` for the identifiers this library owns:
  /// the app's session and every extension session (`…nse` and `…nse.<uuid>`).
  func handleEvents(identifier: String, completion: @escaping () -> Void) -> Bool {
    serial {
      guard ReportUploader.isLibraryIdentifier(identifier), let directory else { return false }
      guard let uploader = makeUploader(identifier, appGroup, directory) as? ReportSessionHandling else { return false }
      if ReportUploader.isExtensionIdentifier(identifier) { uploader.retireWhenFinished() }
      uploader.attach(completion: completion)
      return true
    }
  }
}
