import XCTest

@testable import SinchPushReportCore

private final class Clock {
  var ms: Int64 = 1_700_000_000_000
  func callAsFunction() -> Int64 { ms }
}

private final class FakeUploader: ReportScheduling {
  var uploads: [[ReportEntry]] = []
  var sessions: [SharedReportSession] = []
  var accepts = true
  func upload(entries: [ReportEntry], session: SharedReportSession) -> Bool {
    uploads.append(entries)
    sessions.append(session)
    return accepts
  }
}

private final class FakeSessionUploader: ReportSessionHandling {
  let identifier: String
  var resumed = 0
  var retires = false
  var attached = 0
  init(identifier: String) { self.identifier = identifier }
  func upload(entries: [ReportEntry], session: SharedReportSession) -> Bool { true }
  func resume() { resumed += 1 }
  func attach(completion: @escaping () -> Void) { attached += 1 }
  func retireWhenFinished() { retires = true }
}

/// Builds an unsigned JWT with the given claims.
private func jwt(_ claims: [String: Any]) -> String {
  let data = try! JSONSerialization.data(withJSONObject: claims)
  let payload = data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
  return "e30.\(payload).sig"
}

private func makeDirectory() -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("sinch-report-\(UUID().uuidString)")
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private let pushInfo: [AnyHashable: Any] = [
  "aps": ["alert": "hi", "mutable-content": 1],
  "sinch.push.message_id": "m1",
  "sinch.push.subscriber_id": "s1",
]

final class ReportWireTests: XCTestCase {
  func testRequestBodyIsAGrpcWebFrameOfReportEventsRequest() {
    let body = ReportWire.requestBody(for: [ReportKey(messageId: "m1", subscriberId: "s1")])
    // event: 0A 02 'm1' 12 02 's1' 20 AC 02  (DELIVERED = 300) = 2+2 + 2+2 + 3 = 11 bytes
    let event: [UInt8] = [0x0A, 0x02, 0x6D, 0x31, 0x12, 0x02, 0x73, 0x31, 0x20, 0xAC, 0x02]
    let message: [UInt8] = [0x0A, UInt8(event.count)] + event
    XCTAssertEqual([UInt8](body), [0x00, 0, 0, 0, UInt8(message.count)] + message)
  }

  func testRequestBodyRepeatsEvents() {
    let body = ReportWire.requestBody(for: [
      ReportKey(messageId: "a", subscriberId: "b"), ReportKey(messageId: "c", subscriberId: "d"),
    ])
    // two events of 3+3+3 = 9 bytes, each preceded by 0A 09
    XCTAssertEqual(body.count, 5 + 2 * (2 + 9))
  }

  func testEndpoint() {
    XCTAssertEqual(
      ReportWire.endpoint(baseURL: "https://grpc.sinch-push.prod.sinch.com/")?.absoluteString,
      "https://grpc.sinch-push.prod.sinch.com/sinch.push.sdk.v1beta1.SdkService/ReportEvents")
    XCTAssertNil(ReportWire.endpoint(baseURL: "not a url"))
    XCTAssertNil(ReportWire.endpoint(baseURL: "ftp://x"))
  }

  func testHeadersCarryTheRawJwt() {
    let headers = ReportWire.headers(accessToken: "abc.def.ghi")
    XCTAssertEqual(headers["authorization"], "abc.def.ghi")
    XCTAssertEqual(headers["content-type"], "application/grpc-web+proto")
    XCTAssertEqual(headers["x-grpc-web"], "1")
  }

  func testOutcomeFromHeaderTrailerAndHttp() {
    func trailer(_ text: String) -> Data {
      var d = Data([0x80, 0, 0, 0, UInt8(text.utf8.count)])
      d.append(contentsOf: Array(text.utf8))
      return d
    }
    let web = "application/grpc-web+proto"
    func outcome(_ http: Int, _ header: String? = nil, type: String? = web, body: Data? = nil) -> ReportOutcome {
      ReportWire.outcome(httpStatus: http, grpcStatusHeader: header, contentType: type, body: body)
    }
    XCTAssertEqual(outcome(200, "0"), .sent)
    XCTAssertEqual(outcome(200, body: trailer("grpc-status: 0\r\n")), .sent)
    XCTAssertEqual(outcome(200), .sent)
    XCTAssertEqual(outcome(200, "16"), .unauthenticated)
    XCTAssertEqual(outcome(200, body: trailer("grpc-status: 16\r\ngrpc-message: x")), .unauthenticated)
    for code in ["3", "5", "7"] {
      XCTAssertEqual(outcome(200, code), .dropped)
    }
    XCTAssertEqual(outcome(200, "14"), .retry)
    XCTAssertEqual(outcome(503), .retry)
    XCTAssertEqual(outcome(401), .unauthenticated)
    XCTAssertEqual(outcome(403), .dropped)
    XCTAssertEqual(outcome(429), .retry)
  }

  func testEveryGrpcContentTypeIsAcceptedAndAnUnparsableStatusIsRetried() {
    for type in ["application/grpc", "application/grpc+proto", "Application/GRPC-Web+proto", " application/grpc; charset=utf-8"] {
      XCTAssertEqual(
        ReportWire.outcome(httpStatus: 200, grpcStatusHeader: "0", contentType: type, body: nil), .sent, type)
    }
    XCTAssertEqual(
      ReportWire.outcome(httpStatus: 200, grpcStatusHeader: "abc", contentType: "application/grpc", body: nil), .retry)
    let frame = Data([0x80, 0, 0, 0, 18]) + Data("grpc-status: abc\r\n".utf8)
    XCTAssertEqual(
      ReportWire.outcome(httpStatus: 200, grpcStatusHeader: nil, contentType: "application/grpc-web+proto", body: frame), .retry)
  }

  /// No `grpc-status`: the HTTP status maps like the JS flusher's connect `codeFromHttpStatus`.
  func testOutcomeWithoutGrpcStatusFollowsConnectHttpMapping() {
    // 400 is Internal and 404 Unimplemented there - retried, not dropped.
    for status in [400, 404, 405, 408, 413, 500, 502, 504] {
      XCTAssertEqual(
        ReportWire.outcome(httpStatus: status, grpcStatusHeader: nil, contentType: "application/grpc-web+proto", body: nil),
        .retry, "HTTP \(status)")
    }
    // A 2xx that is not a gRPC (`application/grpc*`) response (a proxy or captive portal) was never acknowledged.
    for type in [nil, "", "text/html", "application/json", "application/grp", "application/grpcfoo", "application/grpc-other"] as [String?] {
      for status in [200, 204] {
        XCTAssertEqual(
          ReportWire.outcome(httpStatus: status, grpcStatusHeader: nil, contentType: type, body: nil),
          .retry, "HTTP \(status) \(type ?? "nil")")
      }
    }
    // gRPC-web, and the plain gRPC a native server answers with (its status is in HTTP/2 trailers,
    // which URLSession cannot read): no status counts as sent.
    for type in [
      "application/grpc-web", "Application/GRPC-Web+Proto; charset=x", " application/grpc-web-text",
      "application/grpc", "application/grpc+proto",
    ] {
      XCTAssertEqual(
        ReportWire.outcome(httpStatus: 200, grpcStatusHeader: nil, contentType: type, body: nil), .sent, type)
    }
    // Only a gRPC 2xx reads grpc-status; elsewhere the HTTP status alone decides (JS, Android).
    XCTAssertEqual(
      ReportWire.outcome(httpStatus: 200, grpcStatusHeader: "0", contentType: "text/html", body: nil), .retry)
    XCTAssertEqual(
      ReportWire.outcome(httpStatus: 200, grpcStatusHeader: "16", contentType: "application/grpc", body: nil),
      .unauthenticated)
    XCTAssertEqual(
      ReportWire.outcome(httpStatus: 200, grpcStatusHeader: "16", contentType: "application/grpc+proto", body: nil),
      .unauthenticated)
    // The trailer frame wins over the header.
    let frame = Data([0x80, 0, 0, 0, 17]) + Data("grpc-status: 16\r\n".utf8)
    XCTAssertEqual(ReportWire.grpcStatus(header: "0", body: frame), 16)
    XCTAssertEqual(
      ReportWire.outcome(httpStatus: 400, grpcStatusHeader: "3", contentType: "application/grpc-web", body: nil), .retry)
    XCTAssertEqual(
      ReportWire.outcome(httpStatus: 503, grpcStatusHeader: "0", contentType: "application/grpc-web", body: nil), .retry)
    XCTAssertEqual(
      ReportWire.outcome(httpStatus: 403, grpcStatusHeader: "0", contentType: "application/grpc-web", body: nil), .dropped)
  }
}

final class SharedReportSessionTests: XCTestCase {
  func testFromDictionaryNeedsTokenAndBaseURL() {
    XCTAssertNil(SharedReportSession(dictionary: ["accessToken": "t"]))
    XCTAssertNil(SharedReportSession(dictionary: ["reportBaseURL": "https://x"]))
    let s = SharedReportSession(dictionary: [
      "accessToken": "t", "reportBaseURL": "https://x", "userId": "u", "appId": "a",
    ])
    XCTAssertEqual(s, SharedReportSession(accessToken: "t", reportBaseURL: "https://x", userId: "u", appId: "a"))
  }

  func testExpiredTokenIsNotUsable() {
    let now: Int64 = 1_700_000_000_000
    let base = "https://grpc.sinch-push.prod.sinch.com"
    XCTAssertTrue(SharedReportSession(accessToken: jwt(["exp": 1_700_000_600]), reportBaseURL: base).isUsable(nowMs: now))
    XCTAssertFalse(SharedReportSession(accessToken: jwt(["exp": 1_699_999_000]), reportBaseURL: base).isUsable(nowMs: now))
    XCTAssertFalse(SharedReportSession(accessToken: jwt(["exp": 1_700_000_010]), reportBaseURL: base).isUsable(nowMs: now))  // inside the leeway
    XCTAssertTrue(SharedReportSession(accessToken: jwt(["uuid": "u"]), reportBaseURL: base).isUsable(nowMs: now))
    XCTAssertFalse(SharedReportSession(accessToken: "t", reportBaseURL: "nope").isUsable(nowMs: now))
  }

  func testStoreRoundTripAndClear() {
    let dir = makeDirectory()
    let store = SharedReportSessionStore(directory: dir)
    XCTAssertNil(store.load())
    let s = SharedReportSession(accessToken: "t", reportBaseURL: "https://x", userId: "u", appId: "a")
    XCTAssertTrue(store.save(s))
    XCTAssertEqual(SharedReportSessionStore(directory: dir).load(), s)
    store.clear()
    XCTAssertNil(store.load())
  }
}

final class ReportMarkerStoreTests: XCTestCase {
  private let clock = Clock()
  private func entry(_ n: Int) -> ReportEntry { ReportEntry(messageId: "m\(n)", subscriberId: "s\(n)", enqueuedAtMs: clock.ms) }

  func testClaimedEntryIsInFlightAndNotClaimedTwice() {
    let store = ReportMarkerStore(directory: makeDirectory(), now: clock.callAsFunction)
    XCTAssertEqual(store.claim([entry(1)]), [entry(1)])
    XCTAssertEqual(store.claim([entry(1), entry(2)]), [entry(2)])
    XCTAssertEqual(store.excludedKeys(), [entry(1).key, entry(2).key])
  }

  func testSentStaysExcluded() {
    let store = ReportMarkerStore(directory: makeDirectory(), now: clock.callAsFunction)
    _ = store.claim([entry(1)])
    store.markSent([entry(1).key])
    clock.ms += ReportMarkerStore.inFlightTTL * 10
    XCTAssertEqual(store.excludedKeys(), [entry(1).key])
    XCTAssertTrue(store.claim([entry(1)]).isEmpty)
    XCTAssertEqual(store.sentKeys(), [entry(1).key])
  }

  func testStaleInFlightBecomesARetry() {
    let store = ReportMarkerStore(directory: makeDirectory(), now: clock.callAsFunction)
    _ = store.claim([entry(1)])
    clock.ms += ReportMarkerStore.inFlightTTL + 1
    XCTAssertTrue(store.excludedKeys().isEmpty)
    XCTAssertEqual(store.retryEntries(), [entry(1)])
    XCTAssertEqual(store.claim([entry(1)]), [entry(1)])
  }

  func testRetryDoesNotExcludeAndNeverDowngradesSent() {
    let store = ReportMarkerStore(directory: makeDirectory(), now: clock.callAsFunction)
    store.markRetry([entry(1).key], entries: [entry(1)])
    XCTAssertTrue(store.excludedKeys().isEmpty)
    XCTAssertEqual(store.retryEntries(), [entry(1)])
    store.markSent([entry(1).key])
    store.markRetry([entry(1).key])
    XCTAssertTrue(store.retryEntries().isEmpty)
    XCTAssertEqual(store.sentKeys(), [entry(1).key])
  }

  func testClearRetriesKeepsSent() {
    let store = ReportMarkerStore(directory: makeDirectory(), now: clock.callAsFunction)
    store.markRetry([entry(1).key], entries: [entry(1)])
    store.markSent([entry(2).key], entries: [entry(2)])
    store.clearRetries()
    XCTAssertTrue(store.retryEntries().isEmpty)
    XCTAssertEqual(store.sentKeys(), [entry(2).key])
  }

  func testMarkersExpireAfterRetentionAndAreSharedBetweenInstances() {
    let dir = makeDirectory()
    let a = ReportMarkerStore(directory: dir, now: clock.callAsFunction)
    let b = ReportMarkerStore(directory: dir, now: clock.callAsFunction)
    a.markSent([entry(1).key], entries: [entry(1)])
    XCTAssertEqual(b.sentKeys(), [entry(1).key])
    clock.ms += ReportMarkerStore.retention + 1
    XCTAssertTrue(b.sentKeys().isEmpty)
  }
}

final class ExtensionReportHandlerTests: XCTestCase {
  private let clock = Clock()
  private let base = "https://grpc.sinch-push.prod.sinch.com"

  private func signedIn(_ dir: URL, exp: Int64? = nil) {
    var claims: [String: Any] = ["uuid": "u"]
    if let exp { claims["exp"] = exp }
    SharedReportSessionStore(directory: dir).save(
      SharedReportSession(accessToken: jwt(claims), reportBaseURL: base, userId: "u", appId: "a"))
  }

  func testNonSinchPushIsIgnored() {
    let dir = makeDirectory()
    signedIn(dir)
    let uploader = FakeUploader()
    XCTAssertFalse(ExtensionReportHandler.handle(userInfo: ["aps": ["alert": "x"]], directory: dir, uploader: uploader, now: clock.callAsFunction))
    XCTAssertFalse(ExtensionReportHandler.handle(userInfo: ["sinch.push.message_id": "m1"], directory: dir, uploader: uploader, now: clock.callAsFunction))
    XCTAssertTrue(uploader.uploads.isEmpty)
  }

  func testQueuesAndUploadsAndMarksInFlight() {
    let dir = makeDirectory()
    signedIn(dir)
    let uploader = FakeUploader()
    XCTAssertTrue(ExtensionReportHandler.handle(userInfo: pushInfo, directory: dir, uploader: uploader, now: clock.callAsFunction))
    XCTAssertEqual(uploader.uploads.map { $0.map(\.key) }, [[ReportKey(messageId: "m1", subscriberId: "s1")]])
    XCTAssertEqual(uploader.sessions.first?.reportBaseURL, base)
    XCTAssertEqual(ReportMarkerStore(directory: dir, now: clock.callAsFunction).excludedKeys(), [ReportKey(messageId: "m1", subscriberId: "s1")])
  }

  func testTheSamePushIsNotUploadedTwice() {
    let dir = makeDirectory()
    signedIn(dir)
    let uploader = FakeUploader()
    _ = ExtensionReportHandler.handle(userInfo: pushInfo, directory: dir, uploader: uploader, now: clock.callAsFunction)
    XCTAssertTrue(ExtensionReportHandler.handle(userInfo: pushInfo, directory: dir, uploader: uploader, now: clock.callAsFunction))
    XCTAssertEqual(uploader.uploads.count, 1)
  }

  func testNoCredentialLeavesARetryForTheApp() {
    let dir = makeDirectory()
    let uploader = FakeUploader()
    XCTAssertFalse(ExtensionReportHandler.handle(userInfo: pushInfo, directory: dir, uploader: uploader, now: clock.callAsFunction))
    XCTAssertTrue(uploader.uploads.isEmpty)
    XCTAssertEqual(ReportMarkerStore(directory: dir, now: clock.callAsFunction).retryEntries().map(\.key), [ReportKey(messageId: "m1", subscriberId: "s1")])
  }

  func testExpiredCredentialLeavesARetry() {
    let dir = makeDirectory()
    signedIn(dir, exp: clock.ms / 1000 - 10)
    let uploader = FakeUploader()
    XCTAssertFalse(ExtensionReportHandler.handle(userInfo: pushInfo, directory: dir, uploader: uploader, now: clock.callAsFunction))
    XCTAssertTrue(uploader.uploads.isEmpty)
    XCTAssertEqual(ReportMarkerStore(directory: dir, now: clock.callAsFunction).retryEntries().count, 1)
  }

  func testUploaderFailureLeavesARetry() {
    let dir = makeDirectory()
    signedIn(dir)
    let uploader = FakeUploader()
    uploader.accepts = false
    XCTAssertFalse(ExtensionReportHandler.handle(userInfo: pushInfo, directory: dir, uploader: uploader, now: clock.callAsFunction))
    let markers = ReportMarkerStore(directory: dir, now: clock.callAsFunction)
    XCTAssertTrue(markers.excludedKeys().isEmpty)
    XCTAssertEqual(markers.retryEntries().count, 1)
  }

  func testNoSharedContainerIsFalse() {
    XCTAssertFalse(ExtensionReportHandler.handle(userInfo: pushInfo, directory: nil, uploader: FakeUploader(), now: clock.callAsFunction))
  }
}

final class ReportCenterTests: XCTestCase {
  private let clock = Clock()
  private let base = "https://grpc.sinch-push.prod.sinch.com"

  private func center(directory: URL, uploader: FakeUploader = FakeUploader(), group: String? = nil) -> ReportCenter {
    let defaults = UserDefaults(suiteName: "sinch-report-tests-\(UUID().uuidString)")!
    if let group { defaults.set(group, forKey: ReportCenter.appGroupDefaultsKey) }
    return ReportCenter(
      defaults: defaults, now: clock.callAsFunction, sharedDirectory: { _ in directory },
      privateDirectory: { directory }, makeUploader: { _, _, _ in uploader })
  }

  private func entry(_ n: Int) -> ReportEntry { ReportEntry(messageId: "m\(n)", subscriberId: "s\(n)", enqueuedAtMs: clock.ms) }

  private func mirror(_ center: ReportCenter) {
    center.setSession(SharedReportSession(accessToken: jwt(["uuid": "u"]), reportBaseURL: base))
  }

  func testOutboxExcludesWhatTheExtensionSentOrIsSending() {
    let dir = makeDirectory()
    let c = center(directory: dir)
    let markers = ReportMarkerStore(directory: dir, now: clock.callAsFunction)
    _ = markers.claim([entry(1)])  // in flight (extension upload running)
    markers.markSent([entry(2).key], entries: [entry(2)])
    XCTAssertEqual(c.pendingReports(outbox: [entry(1), entry(2), entry(3)]), [entry(3)])
    XCTAssertEqual(c.sentReports(outbox: [entry(1), entry(2), entry(3)]), [entry(2)])
  }

  func testOutboxIncludesTheExtensionsRetriesOnce() {
    let dir = makeDirectory()
    let c = center(directory: dir)
    // Oldest first: the extension's retry m1 was queued before the outbox's m2 and m3.
    func entry(_ n: Int) -> ReportEntry { ReportEntry(messageId: "m\(n)", subscriberId: "s\(n)", enqueuedAtMs: clock.ms + Int64(n)) }
    ReportMarkerStore(directory: dir, now: clock.callAsFunction).markRetry([entry(1).key, entry(2).key], entries: [entry(1), entry(2)])
    XCTAssertEqual(c.pendingReports(outbox: [entry(2), entry(3)]).map(\.messageId), ["m1", "m2", "m3"])
  }

  func testJsReportingMarksTheEntriesSentSoNothingReportsThemAgain() {
    let dir = makeDirectory()
    let c = center(directory: dir)
    ReportMarkerStore(directory: dir, now: clock.callAsFunction).markRetry([entry(1).key], entries: [entry(1)])
    c.markReported([entry(1).key])
    XCTAssertTrue(c.pendingReports(outbox: []).isEmpty)
    XCTAssertEqual(c.pendingReports(outbox: [entry(1)]), [])
  }

  func testWakeUploadHandsOffPendingReportsAndMarksThemInFlight() {
    let dir = makeDirectory()
    let uploader = FakeUploader()
    let c = center(directory: dir, uploader: uploader)
    mirror(c)
    XCTAssertEqual(c.uploadInBackground(outbox: [entry(1), entry(2)]), .handedOff)
    XCTAssertEqual(uploader.uploads.first?.map(\.messageId), ["m1", "m2"])
    // The same wake again has nothing left to send.
    XCTAssertEqual(c.uploadInBackground(outbox: [entry(1), entry(2)]), .nothingToSend)
    XCTAssertEqual(uploader.uploads.count, 1)
    XCTAssertTrue(c.pendingReports(outbox: [entry(1), entry(2)]).isEmpty)
  }

  func testWakeUploadNeedsAMirroredToken() {
    let dir = makeDirectory()
    let uploader = FakeUploader()
    let c = center(directory: dir, uploader: uploader)
    XCTAssertEqual(c.uploadInBackground(outbox: [entry(1)]), .unavailable)
    XCTAssertTrue(uploader.uploads.isEmpty)
    XCTAssertEqual(c.pendingReports(outbox: [entry(1)]), [entry(1)])
  }

  func testWakeUploadFailureLeavesTheReportForJs() {
    let dir = makeDirectory()
    let uploader = FakeUploader()
    uploader.accepts = false
    let c = center(directory: dir, uploader: uploader)
    mirror(c)
    XCTAssertEqual(c.uploadInBackground(outbox: [entry(1)]), .unavailable)
    XCTAssertEqual(c.pendingReports(outbox: [entry(1)]), [entry(1)])
  }

  func testWakeUploadSkipsExpiredEntries() {
    let dir = makeDirectory()
    let uploader = FakeUploader()
    let c = center(directory: dir, uploader: uploader)
    mirror(c)
    let old = ReportEntry(messageId: "old", subscriberId: "s", enqueuedAtMs: clock.ms - ReportMarkerStore.retention - 1)
    XCTAssertEqual(c.uploadInBackground(outbox: [old]), .nothingToSend)
    XCTAssertEqual(c.uploadInBackground(outbox: [old, entry(1)]), .handedOff)
    XCTAssertEqual(uploader.uploads.first?.map(\.messageId), ["m1"])
  }

  func testSessionIsClearedWithNil() {
    let dir = makeDirectory()
    let c = center(directory: dir)
    mirror(c)
    c.setSession(nil)
    XCTAssertNil(SharedReportSessionStore(directory: dir).load())
  }

  func testHandleEventsOnlyClaimsTheLibrarysIdentifiers() {
    let c = center(directory: makeDirectory())
    XCTAssertFalse(c.handleEvents(identifier: "com.other.session", completion: {}))
    XCTAssertFalse(c.handleEvents(identifier: "com.sinch.push.reports.nsefoo", completion: {}))
  }

  func testHandleEventsClaimsTheAppSessionAndEveryExtensionSession() {
    var created: [String: FakeSessionUploader] = [:]
    let defaults = UserDefaults(suiteName: "sinch-report-tests-\(UUID().uuidString)")!
    let dir = makeDirectory()
    let c = ReportCenter(
      defaults: defaults, now: clock.callAsFunction, sharedDirectory: { _ in dir }, privateDirectory: { dir },
      makeUploader: { id, _, _ in
        if let existing = created[id] { return existing }
        let uploader = FakeSessionUploader(identifier: id)
        created[id] = uploader
        return uploader
      })
    let ids = [
      ReportUploader.appIdentifier, ReportUploader.extensionIdentifierPrefix,
      ReportUploader.makeExtensionIdentifier(),
    ]
    for id in ids { XCTAssertTrue(c.handleEvents(identifier: id, completion: {}), id) }
    XCTAssertEqual(created.values.map(\.attached), [1, 1, 1])
    XCTAssertEqual(created[ids[0]]?.retires, false)
    XCTAssertEqual(created[ids[1]]?.retires, true)
    XCTAssertEqual(created[ids[2]]?.retires, true)
  }

  func testExtensionIdentifiersAreUniquePerProcess() {
    let a = ReportUploader.makeExtensionIdentifier()
    XCTAssertTrue(a.hasPrefix("com.sinch.push.reports.nse."))
    XCTAssertNotEqual(a, ReportUploader.makeExtensionIdentifier())
    XCTAssertTrue(ReportUploader.isExtensionIdentifier(a))
    XCTAssertTrue(ReportUploader.isExtensionIdentifier("com.sinch.push.reports.nse"))
    XCTAssertFalse(ReportUploader.isExtensionIdentifier("com.sinch.push.reports.app"))
  }

  func testResumeSessionsReconnectsToTheAppAndTheListedExtensionSessions() {
    var created: [String: FakeSessionUploader] = [:]
    let defaults = UserDefaults(suiteName: "sinch-report-tests-\(UUID().uuidString)")!
    defaults.set("group.test", forKey: ReportCenter.appGroupDefaultsKey)
    let dir = makeDirectory()
    let registry = ReportSessionRegistry(directory: dir, now: clock.callAsFunction)
    registry.register("com.sinch.push.reports.nse.AAA")
    registry.register("com.sinch.push.reports.nse.BBB")
    clock.ms += ReportCenter.extensionActiveWindowMs + 1  // both idle by now
    let c = ReportCenter(
      defaults: defaults, now: clock.callAsFunction, sharedDirectory: { _ in dir }, privateDirectory: { dir },
      makeUploader: { id, _, _ in
        if let existing = created[id] { return existing }
        let uploader = FakeSessionUploader(identifier: id)
        created[id] = uploader
        return uploader
      })
    c.resumeSessions()
    XCTAssertEqual(
      Set(created.keys),
      [
        ReportUploader.appIdentifier, ReportUploader.extensionIdentifierPrefix,
        "com.sinch.push.reports.nse.AAA", "com.sinch.push.reports.nse.BBB",
      ])
    XCTAssertTrue(created.values.allSatisfy { $0.resumed == 1 })
    XCTAssertEqual(created[ReportUploader.appIdentifier]?.retires, false)
    XCTAssertEqual(created["com.sinch.push.reports.nse.AAA"]?.retires, true)
  }

  func testResumeSessionsLeavesRecentlyUsedExtensionSessionsToTheirProcess() {
    var created: [String: FakeSessionUploader] = [:]
    let defaults = UserDefaults(suiteName: "sinch-report-tests-\(UUID().uuidString)")!
    defaults.set("group.test", forKey: ReportCenter.appGroupDefaultsKey)
    let dir = makeDirectory()
    let registry = ReportSessionRegistry(directory: dir, now: clock.callAsFunction)
    registry.register("com.sinch.push.reports.nse.OLD")
    clock.ms += ReportCenter.extensionActiveWindowMs + 1
    registry.register("com.sinch.push.reports.nse.LIVE")  // an extension process uploaded just now
    let c = ReportCenter(
      defaults: defaults, now: clock.callAsFunction, sharedDirectory: { _ in dir }, privateDirectory: { dir },
      makeUploader: { id, _, _ in
        if let existing = created[id] { return existing }
        let uploader = FakeSessionUploader(identifier: id)
        created[id] = uploader
        return uploader
      })
    c.resumeSessions()
    XCTAssertNotNil(created["com.sinch.push.reports.nse.OLD"])
    XCTAssertNil(created["com.sinch.push.reports.nse.LIVE"])
    XCTAssertNotNil(created[ReportUploader.appIdentifier])
    // Later launch: it has been idle long enough.
    clock.ms += ReportCenter.extensionActiveWindowMs + 1
    c.resumeSessions()
    XCTAssertNotNil(created["com.sinch.push.reports.nse.LIVE"])
  }

  func testLaunchTimeResumeAfterConfigureIsANoOp() {
    var created: [(id: String, group: String?)] = []
    let defaults = UserDefaults(suiteName: "sinch-report-tests-\(UUID().uuidString)")!
    defaults.set("group.old", forKey: ReportCenter.appGroupDefaultsKey)  // what the previous run persisted
    let dir = makeDirectory()
    let c = ReportCenter(
      defaults: defaults, now: clock.callAsFunction, sharedDirectory: { _ in dir }, privateDirectory: { dir },
      makeUploader: { id, group, _ in
        created.append((id, group))
        return FakeSessionUploader(identifier: id)
      })
    c.configure(appGroup: "group.new")
    let afterConfigure = created.count
    XCTAssertGreaterThan(afterConfigure, 0)
    XCTAssertTrue(created.allSatisfy { $0.group == "group.new" })
    c.resumeSessionsAtLaunch()  // the init-time resume, late
    XCTAssertEqual(created.count, afterConfigure)
  }

  func testLaunchTimeResumeBeforeConfigureStillResumes() {
    var created: [String] = []
    let dir = makeDirectory()
    let c = ReportCenter(
      defaults: UserDefaults(suiteName: "sinch-report-tests-\(UUID().uuidString)")!, now: clock.callAsFunction,
      sharedDirectory: { _ in dir }, privateDirectory: { dir },
      makeUploader: { id, _, _ in
        created.append(id)
        return FakeSessionUploader(identifier: id)
      })
    c.resumeSessionsAtLaunch()
    XCTAssertEqual(created, [ReportUploader.appIdentifier])
  }

  func testResumeSessionsWithoutAnAppGroupOnlyResumesTheAppSession() {
    var created: [String] = []
    let dir = makeDirectory()
    let c = ReportCenter(
      defaults: UserDefaults(suiteName: "sinch-report-tests-\(UUID().uuidString)")!, now: clock.callAsFunction,
      sharedDirectory: { _ in dir }, privateDirectory: { dir },
      makeUploader: { id, _, _ in
        created.append(id)
        return FakeSessionUploader(identifier: id)
      })
    c.resumeSessions()
    XCTAssertEqual(created, [ReportUploader.appIdentifier])
  }

  func testSettingAGroupClearsTheAppPrivateCopyOfTheCredential() {
    let privateDir = makeDirectory()
    let groupDir = makeDirectory()
    let c = ReportCenter(
      defaults: UserDefaults(suiteName: "sinch-report-tests-\(UUID().uuidString)")!, now: clock.callAsFunction,
      sharedDirectory: { _ in groupDir }, privateDirectory: { privateDir }, makeUploader: { _, _, _ in FakeUploader() })
    mirror(c)  // no group yet: lands in the private directory
    XCTAssertNotNil(SharedReportSessionStore(directory: privateDir).load())
    c.configure(appGroup: "group.test")
    XCTAssertNil(SharedReportSessionStore(directory: privateDir).load())
    mirror(c)
    XCTAssertNotNil(SharedReportSessionStore(directory: groupDir).load())
    // Configuring the same group again keeps the group copy.
    c.configure(appGroup: "group.test")
    XCTAssertNotNil(SharedReportSessionStore(directory: groupDir).load())
  }

  func testClearingTheSessionClearsBothLocations() {
    let privateDir = makeDirectory()
    let groupDir = makeDirectory()
    let session = SharedReportSession(accessToken: jwt(["uuid": "u"]), reportBaseURL: base)
    SharedReportSessionStore(directory: privateDir).save(session)
    SharedReportSessionStore(directory: groupDir).save(session)
    let defaults = UserDefaults(suiteName: "sinch-report-tests-\(UUID().uuidString)")!
    defaults.set("group.test", forKey: ReportCenter.appGroupDefaultsKey)
    let c = ReportCenter(
      defaults: defaults, now: clock.callAsFunction, sharedDirectory: { _ in groupDir },
      privateDirectory: { privateDir }, makeUploader: { _, _, _ in FakeUploader() })
    c.setSession(nil)
    XCTAssertNil(SharedReportSessionStore(directory: privateDir).load())
    XCTAssertNil(SharedReportSessionStore(directory: groupDir).load())
  }
}

final class ReportUploaderSharingTests: XCTestCase {
  // Nothing here creates a URLSession: a session is made on first use only.

  func testOneUploaderPerIdentifierEvenWhenTheContainerChanges() {
    let id = "com.sinch.push.reports.test.\(UUID().uuidString)"
    let first = makeDirectory()
    let second = makeDirectory()
    let a = ReportUploader.shared(identifier: id, appGroup: "group.a", directory: first)
    XCTAssertTrue(ReportUploader.shared(identifier: id, appGroup: "group.a", directory: first) === a)
    XCTAssertEqual(a.directory, first)

    let b = ReportUploader.shared(identifier: id, appGroup: "group.b", directory: second)
    XCTAssertTrue(b === a, "a second uploader would open a second session with the same identifier")
    XCTAssertEqual(b.directory, second)
  }
}

final class ReportSessionRegistryTests: XCTestCase {
  private let clock = Clock()

  func testRegisterListsAndUnregisterRemoves() {
    let dir = makeDirectory()
    let registry = ReportSessionRegistry(directory: dir, now: clock.callAsFunction)
    registry.register("a")
    registry.register("a")
    registry.register("b")
    XCTAssertEqual(ReportSessionRegistry(directory: dir, now: clock.callAsFunction).identifiers(), ["a", "b"])
    registry.unregister("a")
    XCTAssertEqual(registry.identifiers(), ["b"])
    XCTAssertEqual(registry.lastUsedAtMs("b"), clock.ms)
    XCTAssertNil(registry.lastUsedAtMs("a"))
  }

  func testRegisteringAgainStampsTheLastUseAndKeepsTheEntryAlive() {
    let registry = ReportSessionRegistry(directory: makeDirectory(), now: clock.callAsFunction)
    registry.register("a")
    let first = clock.ms
    clock.ms += ReportSessionRegistry.maxAge - 1_000
    registry.register("a")  // an upload on a long-lived extension process
    XCTAssertEqual(registry.lastUsedAtMs("a"), clock.ms)
    XCTAssertNotEqual(registry.lastUsedAtMs("a"), first)
    clock.ms += 2_000  // past the first registration's age, well within the last use's
    XCTAssertEqual(registry.identifiers(), ["a"])
    XCTAssertEqual(registry.lastUsed(), ["a": clock.ms - 2_000])
  }

  func testOldEntriesExpire() {
    let registry = ReportSessionRegistry(directory: makeDirectory(), now: clock.callAsFunction)
    registry.register("a")
    clock.ms += ReportSessionRegistry.maxAge + 1
    XCTAssertTrue(registry.identifiers().isEmpty)
  }

  func testLockIsBoundedWhenAnotherProcessHoldsIt() {
    let dir = makeDirectory()
    let fd = open(dir.appendingPathComponent("reports.lock").path, O_CREAT | O_RDWR, 0o600)
    XCTAssertEqual(flock(fd, LOCK_EX), 0)
    defer { close(fd) }
    let started = Date()
    // Another descriptor cannot take the lock: the call gives up waiting and runs best-effort.
    let store = ReportMarkerStore(directory: dir, now: clock.callAsFunction)
    store.markRetry([ReportKey(messageId: "m", subscriberId: "s")])
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    XCTAssertEqual(store.retryEntries().count, 1)
  }
}
