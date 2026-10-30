//  ReportUploader.swift — hands ReportEvents calls to a background URLSession.
//
//  A background session is run by the system, not by this process: the upload
//  completes after the app is suspended or killed (unless the user force-quit it),
//  and the extension can return the moment the task is created. The result comes
//  back to the *app* — `application:handleEventsForBackgroundURLSession:` — even
//  when an extension created the task, so the same class handles both ends: it is
//  recreated with the same identifier and its delegate settles the markers.
//
//  Identifiers. The app has one session (`com.sinch.push.reports.app`). Apple supports
//  one process per session identifier, so every extension process uploads in a session
//  of its own, `com.sinch.push.reports.nse.<uuid>`. The extension lists the identifier in
//  the App Group (``ReportSessionRegistry``) before it starts uploading; the app recreates
//  the listed sessions when it launches - iOS relaunches a force-quit app for nothing, so
//  this is how a force-quit app still collects the results on its next launch - and drops
//  a session from the list once its events were delivered. Builds before per-process
//  identifiers used `com.sinch.push.reports.nse` itself; the app still reconnects to it.

import Foundation

/// What `ReportUploader` is to its callers; a test substitutes its own.
protocol ReportScheduling: AnyObject {
  /// Starts the upload of `entries` (already claimed). `false` when nothing could be started.
  func upload(entries: [ReportEntry], session: SharedReportSession) -> Bool
}

/// The app-side half of a background session: reconnecting to it and settling its events.
protocol ReportSessionHandling: ReportScheduling {
  /// Connects to the session so the system delivers what finished while this process was away.
  func resume()
  /// Re-attaches after `handleEventsForBackgroundURLSession`; `completion` is called once the events are delivered.
  func attach(completion: @escaping () -> Void)
  /// An extension's session: done (and forgotten) once its events were delivered.
  func retireWhenFinished()
}

final class ReportUploader: NSObject, ReportSessionHandling, URLSessionDataDelegate {
  static let appIdentifier = "com.sinch.push.reports.app"
  /// Extension sessions are `extensionIdentifierPrefix + "." + uuid`; the bare prefix is what earlier builds used.
  static let extensionIdentifierPrefix = "com.sinch.push.reports.nse"

  /// A fresh identifier for one extension process's session.
  static func makeExtensionIdentifier() -> String {
    extensionIdentifierPrefix + "." + UUID().uuidString
  }

  static func isExtensionIdentifier(_ identifier: String) -> Bool {
    identifier == extensionIdentifierPrefix || identifier.hasPrefix(extensionIdentifierPrefix + ".")
  }

  /// The sessions this library owns.
  static func isLibraryIdentifier(_ identifier: String) -> Bool {
    identifier == appIdentifier || isExtensionIdentifier(identifier)
  }

  /// How long a recreated extension session with no tasks is kept, in case its events are still on the way.
  private static let idleGraceMs: Int64 = 60 * 60 * 1000

  private static let lock = NSLock()
  private static var cache: [String: ReportUploader] = [:]

  /// One uploader per identifier per process: two sessions with one identifier fight over its tasks.
  /// A cached uploader that points at another directory or App Group (the group was reconfigured)
  /// keeps its session - a finishing session stays alive after `finishTasksAndInvalidate` - and
  /// has its markers, registry and upload directory pointed at the new container instead.
  static func shared(identifier: String, appGroup: String?, directory: URL) -> ReportUploader {
    lock.lock()
    defer { lock.unlock() }
    if let existing = cache[identifier] {
      existing.retarget(appGroup: appGroup, directory: directory)
      return existing
    }
    let uploader = ReportUploader(identifier: identifier, appGroup: appGroup, directory: directory)
    cache[identifier] = uploader
    return uploader
  }

  private static func forget(_ uploader: ReportUploader) {
    lock.lock()
    defer { lock.unlock() }
    if cache[uploader.identifier] === uploader { cache.removeValue(forKey: uploader.identifier) }
  }

  /// What a task needs once it finishes, kept in `taskDescription` because that is what the
  /// system persists across a relaunch.
  private struct TaskInfo: Codable {
    var entries: [ReportEntry]
    var bodyFile: String
  }

  /// Where the uploader keeps its files. Replaced as a whole by ``retarget(appGroup:directory:)``.
  private struct Storage {
    let directory: URL
    let markers: ReportMarkerStore
    let registry: ReportSessionRegistry
    let uploads: URL
  }

  private let identifier: String
  private let now: () -> Int64
  private let lock = NSLock()
  private var appGroup: String?  // only read when the session is created
  private var storage: Storage
  private var bodies: [Int: Data] = [:]
  private var backgroundCompletion: (() -> Void)?
  private var retiresWhenFinished = false
  private var urlSession: URLSession?
  private var hasStartedTasks = false

  /// Created on first use (the system starts delivering a session's events when it exists).
  private var session: URLSession {
    lock.lock()
    defer { lock.unlock() }
    if let urlSession { return urlSession }
    let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
    configuration.sharedContainerIdentifier = appGroup
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForResource = 24 * 60 * 60
    let created = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    urlSession = created
    return created
  }

  init(identifier: String, appGroup: String?, directory: URL, now: @escaping () -> Int64 = currentTimeMs) {
    self.identifier = identifier
    self.appGroup = appGroup
    self.storage = Self.storage(directory: directory, now: now)
    self.now = now
    super.init()
  }

  private static func storage(directory: URL, now: @escaping () -> Int64) -> Storage {
    Storage(
      directory: directory, markers: ReportMarkerStore(directory: directory, now: now),
      registry: ReportSessionRegistry(directory: directory, now: now),
      uploads: directory.appendingPathComponent("uploads", isDirectory: true))
  }

  /// The directory this uploader keeps its files in.
  var directory: URL { current.directory }

  private var current: Storage {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  /// Points the uploader at another container (the App Group was reconfigured). The session is
  /// kept: it cannot be re-created under its identifier while it is alive. Its shared container
  /// identifier only matters when it is created.
  func retarget(appGroup newGroup: String?, directory newDirectory: URL) {
    lock.lock()
    defer { lock.unlock() }
    if urlSession == nil { appGroup = newGroup }
    if storage.directory != newDirectory { storage = Self.storage(directory: newDirectory, now: now) }
  }

  func resume() {
    _ = session
    reapIfIdle()
  }

  /// Re-attaches the session after the system relaunched the app for it; `completion` is the
  /// handler iOS gave `handleEventsForBackgroundURLSession`, called once the events are delivered.
  func attach(completion: @escaping () -> Void) {
    lock.lock()
    backgroundCompletion = completion
    lock.unlock()
    _ = session
  }

  func retireWhenFinished() {
    lock.lock()
    retiresWhenFinished = true
    lock.unlock()
  }

  func upload(entries: [ReportEntry], session credential: SharedReportSession) -> Bool {
    guard let url = ReportWire.endpoint(baseURL: credential.reportBaseURL), !entries.isEmpty else { return false }
    let files = current
    let (markers, registry, uploads) = (files.markers, files.registry, files.uploads)
    try? FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
    sweepStaleBodies(in: uploads)
    // Listed before the first task exists, so the app can find the session even if it is killed
    // before the result is delivered. Every upload stamps the entry again: the app leaves a session
    // that was used recently to this process (the system keeps an extension process alive between
    // pushes), and never reaps it between this call and the creation of its task.
    if Self.isExtensionIdentifier(identifier) { registry.register(identifier) }

    var started = false
    var index = 0
    while index < entries.count {
      let batch = Array(entries[index..<min(index + ReportWire.batchSize, entries.count)])
      index += ReportWire.batchSize

      let file = UUID().uuidString + ".bin"
      let fileURL = uploads.appendingPathComponent(file)
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      for (name, value) in ReportWire.headers(accessToken: credential.accessToken) {
        request.setValue(value, forHTTPHeaderField: name)
      }
      guard (try? ReportWire.requestBody(for: batch.map(\.key)).write(to: fileURL, options: .atomic)) != nil,
        let info = try? JSONEncoder().encode(TaskInfo(entries: batch, bodyFile: file))
      else {
        markers.markRetry(batch.map(\.key), entries: batch)
        continue
      }
      let task = session.uploadTask(with: request, fromFile: fileURL)
      task.taskDescription = String(decoding: info, as: UTF8.self)
      task.resume()
      started = true
    }
    if !started && Self.isExtensionIdentifier(identifier) && !hasStartedTasks { registry.unregister(identifier) }
    hasStartedTasks = hasStartedTasks || started
    return started
  }

  // MARK: URLSessionDataDelegate

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    defer { lock.unlock() }
    // A ReportEvents response is an empty message and a trailer; anything larger is not ours.
    if (bodies[dataTask.taskIdentifier]?.count ?? 0) < 64 * 1024 {
      bodies[dataTask.taskIdentifier, default: Data()].append(data)
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let body = bodies.removeValue(forKey: task.taskIdentifier)
    lock.unlock()

    guard let description = task.taskDescription, let data = description.data(using: .utf8),
      let info = try? JSONDecoder().decode(TaskInfo.self, from: data)
    else { return }
    let files = current
    let (markers, uploads) = (files.markers, files.uploads)
    try? FileManager.default.removeItem(at: uploads.appendingPathComponent(info.bodyFile))

    let outcome: ReportOutcome
    if error != nil {
      outcome = .retry
    } else if let http = task.response as? HTTPURLResponse {
      outcome = ReportWire.outcome(
        httpStatus: http.statusCode, grpcStatusHeader: http.value(forHTTPHeaderField: "grpc-status"),
        contentType: http.value(forHTTPHeaderField: "content-type"), body: body)
    } else {
      outcome = .retry
    }
    let keys = info.entries.map(\.key)
    if outcome.isFinal {
      markers.markSent(keys, entries: info.entries)
      NSLog("[SinchPush] reported %d DELIVERED natively (%@)", keys.count, "\(outcome)")
    } else {
      markers.markRetry(keys, entries: info.entries)
      let http = task.response as? HTTPURLResponse
      NSLog(
        "[SinchPush] report upload not acknowledged (%@, http %d, %@, grpc-status %@); left for the app",
        "\(outcome)", http?.statusCode ?? 0, http?.value(forHTTPHeaderField: "content-type") ?? "-",
        http?.value(forHTTPHeaderField: "grpc-status") ?? "-")
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    lock.lock()
    let completion = backgroundCompletion
    backgroundCompletion = nil
    let retires = retiresWhenFinished
    lock.unlock()
    if let completion { DispatchQueue.main.async(execute: completion) }
    if retires { finish() }
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    Self.forget(self)
  }

  /// The session delivered everything: it is no longer listed, and the system may drop it.
  private func finish() {
    current.registry.unregister(identifier)
    invalidate()
  }

  /// A session recreated for an extension upload that has no tasks left and was last used long
  /// ago has nothing to deliver any more (its events came, or it never started).
  private func reapIfIdle() {
    lock.lock()
    let retires = retiresWhenFinished
    lock.unlock()
    guard retires else { return }
    session.getAllTasks { [self] tasks in
      guard tasks.isEmpty else { return }
      if let used = current.registry.lastUsedAtMs(identifier), now() - used > Self.idleGraceMs { finish() }
    }
  }

  /// Lets running tasks finish and refuses new ones.
  private func closeSession() {
    lock.lock()
    let created = urlSession
    lock.unlock()
    created?.finishTasksAndInvalidate()
  }

  /// Closes the session and drops this uploader from the cache.
  private func invalidate() {
    closeSession()
    Self.forget(self)
  }

  /// Bodies of uploads whose tasks are long gone (killed before they finished).
  private func sweepStaleBodies(in uploads: URL) {
    let cutoff = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
    let files = (try? FileManager.default.contentsOfDirectory(
      at: uploads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for file in files {
      let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
    }
  }
}
