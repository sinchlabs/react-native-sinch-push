//  RelayHarness.swift — launches the prebuilt relay binaries for the live
//  contract suite (SB-58).
//
//  The harness notes in the spec are not optional here, because getting them
//  wrong produces convincing false failures: zerolog writes to *stderr*, so both
//  streams are collected and lines are matched on the decoded JSON `message`
//  field; the relay drains for ~5 s after SIGTERM and holds its ports the whole
//  time, so a respawn waits for process *exit*; and the sink needs its own
//  probes port.

import Foundation

final class RelayHarness {

  /// One `ReportDelivery` call as the upstream sink saw it. The sink logs the
  /// message id in `message_id` (older relays: `channel_message_id`) and the
  /// installation id in `installation_id`, under either `ReportDelivery` or
  /// `RelayCallback ReportDelivery`.
  struct SinkReport: Equatable {
    var sinchMessageID: String
    var channelMessageID: String
    var status: String
    var installationID: String = ""
  }

  let httpPort = RelayHarness.freePort()
  let grpcPort = RelayHarness.freePort()
  private let metricsPort = RelayHarness.freePort()
  private let probesPort = RelayHarness.freePort()
  private let sinkPort = RelayHarness.freePort()
  private let sinkProbesPort = RelayHarness.freePort()

  var wsURL: String { "ws://127.0.0.1:\(httpPort)/ws" }

  private let binDir: URL
  private let lock = NSLock()
  private var sinkLines: [String] = []
  private var relayLines: [String] = []
  private var sink: Process?
  private(set) var relay: Process?

  private init(binDir: URL) { self.binDir = binDir }

  /// Returns a harness, or the reason there is none.
  static func locate() -> (RelayHarness?, String) {
    let env = ProcessInfo.processInfo.environment
    guard env["RELAY_CONTRACT"] == "1" else {
      return (nil, "live relay contract is opt-in: run `npm run contract:ios` (RELAY_CONTRACT=1)")
    }
    // #filePath is .../ios/SinchPushSocketTests/Tests/SinchPushSocketTests/RelayHarness.swift
    // and the relay is a sibling of the repo: <repo>/../sinch-push-relay.
    let repo = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let relayDir = env["RELAY_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? repo.deletingLastPathComponent().appendingPathComponent("sinch-push-relay")
    let bin = env["RELAY_BIN_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
      ?? relayDir.appendingPathComponent("bin")
    let missing = ["deliveryd", "enqueue", "report-sink-stub"].filter {
      !FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent($0).path)
    }
    guard missing.isEmpty else {
      return (
        nil,
        "relay binaries \(missing) not found in \(bin.path); build the relay (make build) or set RELAY_DIR / RELAY_BIN_DIR"
      )
    }
    return (RelayHarness(binDir: bin), "")
  }

  func start() throws {
    sink = try spawn(
      "report-sink-stub",
      env: ["GRPC_LISTEN_ADDR": ":\(sinkPort)", "PROBES_ADDR": ":\(sinkProbesPort)"],
      into: \.sinkLines)
    try startRelay()
  }

  /// (Re)starts deliveryd on the same ports and waits for it to be healthy.
  func startRelay() throws {
    relay = try spawn(
      "deliveryd",
      env: [
        "HTTP_PORT": "\(httpPort)", "GRPC_PORT": "\(grpcPort)",
        "METRICS_PORT": "\(metricsPort)", "PROBES_PORT": "\(probesPort)",
        "SINCH_PUSH_GRPC_ADDR": "127.0.0.1:\(sinkPort)", "LOG_LEVEL": "info",
        // The relay refuses to start without a JWT secret. The harness talks to
        // it with placeholder tokens, so the JWT check is skipped (local only).
        // An inherited JWT_SECRET is cleared: the relay refuses to start when
        // both are set.
        "AUTH_INSECURE_SKIP_JWT": "true", "JWT_SECRET": "",
      ],
      into: \.relayLines)
    let deadline = Date().addingTimeInterval(15)
    var last = "never attempted"
    while Date() < deadline {
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(probesPort)/healthz")!)
      request.timeoutInterval = 0.5
      let done = DispatchSemaphore(value: 0)
      var ok = false
      URLSession.shared.dataTask(with: request) { _, response, error in
        if let http = response as? HTTPURLResponse { ok = http.statusCode == 200; last = "status \(http.statusCode)" }
        else if let error { last = error.localizedDescription }
        done.signal()
      }.resume()
      done.wait()
      if ok { return }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw NSError(
      domain: "RelayHarness", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "deliveryd never became healthy: \(last)\n\(relayTail())"])
  }

  /// SIGTERM, then wait for the graceful drain to end, i.e. for process exit.
  func sigtermRelayAndAwaitExit() throws {
    guard let relay, relay.isRunning else { return }
    relay.terminate()
    let deadline = Date().addingTimeInterval(25)
    while relay.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if relay.isRunning {
      throw NSError(
        domain: "RelayHarness", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "deliveryd did not exit within 25 s of SIGTERM\n\(relayTail())"])
    }
  }

  func stop() {
    for process in [relay, sink].compactMap({ $0 }) where process.isRunning {
      process.terminate()
      let deadline = Date().addingTimeInterval(10)
      while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
    }
  }

  /// Runs `enqueue` and returns its output. With `installation` the relay's
  /// `RelayService.EnqueueMessage` targets that one installation and the output is one
  /// `outcome=PUSHED|STORED_OFFLINE ...` line; without it the legacy
  /// `DeliveryService.EnqueueMessage` fans out to every session of the user.
  /// `ackDeadlineMs` > 0 arms ACK_TIMEOUT/NOT_CONNECTED reporting (relay path only).
  @discardableResult
  func enqueue(
    appID: String, userID: String, sinchMessageID: String, title: String, body: String? = nil,
    installation: String? = nil, ackDeadlineMs: Int? = nil
  ) throws -> String {
    var args = [
      "-addr", "127.0.0.1:\(grpcPort)", "-app", appID, "-user", userID,
      "-title", title, "-sinch-message-id", sinchMessageID, "-ttl", "120",
    ]
    if let body { args += ["-body", body, "-metadata", "kind=chat"] }
    if let installation { args += ["-installation", installation] }
    if let ackDeadlineMs { args += ["-ack-deadline-ms", "\(ackDeadlineMs)"] }
    let process = Process()
    process.executableURL = binDir.appendingPathComponent("enqueue")
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw NSError(
        domain: "RelayHarness", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "enqueue failed: \(String(decoding: out, as: UTF8.self))"])
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// Reports the sink actually received, from its own log.
  func sinkReports() -> [SinkReport] {
    lock.lock()
    let text = sinkLines.joined()
    lock.unlock()
    return text.split(separator: "\n").compactMap { line -> SinkReport? in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("{"),
        let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
        let message = object["message"] as? String,
        message == "ReportDelivery" || message == "RelayCallback ReportDelivery"
      else { return nil }
      return SinkReport(
        sinchMessageID: object["sinch_message_id"] as? String ?? "",
        channelMessageID: (object["message_id"] ?? object["channel_message_id"]) as? String ?? "",
        status: object["status"] as? String ?? "",
        installationID: object["installation_id"] as? String ?? "")
    }
  }

  /// deliveryd's own log lines whose decoded JSON `message` equals `message` (the harness notes in SB-58).
  func relayEvents(_ message: String) -> [[String: Any]] {
    lock.lock()
    let text = relayLines.joined()
    lock.unlock()
    return text.split(separator: "\n").compactMap { line -> [String: Any]? in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("{"),
        let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any],
        object["message"] as? String == message
      else { return nil }
      return object
    }
  }

  func relayTail(_ lines: Int = 25) -> String { tail(\.relayLines, "deliveryd", lines) }
  func sinkTail(_ lines: Int = 25) -> String { tail(\.sinkLines, "sink", lines) }

  private func tail(_ keyPath: KeyPath<RelayHarness, [String]>, _ name: String, _ n: Int) -> String {
    lock.lock()
    defer { lock.unlock() }
    return "--- \(name) (last \(n)) ---\n"
      + self[keyPath: keyPath].joined().split(separator: "\n").suffix(n).joined(separator: "\n")
  }

  private func spawn(
    _ binary: String, env: [String: String], into target: ReferenceWritableKeyPath<RelayHarness, [String]>
  ) throws -> Process {
    let process = Process()
    process.executableURL = binDir.appendingPathComponent(binary)
    process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let self else { return }
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
      self.lock.lock()
      self[keyPath: target].append(String(decoding: data, as: UTF8.self))
      self.lock.unlock()
    }
    try process.run()
    return process
  }

  private static func freePort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    _ = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return Int(UInt16(bigEndian: bound.sin_port))
  }
}
