//  ReportWire.swift — the `SdkService/ReportEvents` call, as bytes.
//
//  Hand-encoded rather than generated: the message is two strings and an enum,
//  and the extension pod must not depend on SwiftProtobuf. Mirrors
//  src/api/pushRepository.ts `reportEvents` and src/api/transport.ts (gRPC-web
//  framing, raw JWT in `authorization`).
//
//    ReportEventsRequest { repeated ReportedEvent events = 1; }
//    ReportedEvent { string message_id = 1; string subscriber_id = 2; PushEventType event_type = 4; }
//    PushEventType.DELIVERED = 300

import Foundation

/// What a finished ReportEvents call means for the queued reports.
enum ReportOutcome: Equatable {
  /// Acknowledged: never report again.
  case sent
  /// The server will never accept it (InvalidArgument / NotFound / PermissionDenied status, or HTTP 403): drop it.
  case dropped
  /// Rejected for the credential: keep the report for a newer token.
  case unauthenticated
  /// Transport or server trouble: keep the report for the next attempt.
  case retry

  /// `true` when the reports are done with, one way or the other.
  var isFinal: Bool { self == .sent || self == .dropped }
}

enum ReportWire {
  static let deliveredEventType: UInt64 = 300
  static let servicePath = "sinch.push.sdk.v1beta1.SdkService/ReportEvents"
  static let contentType = "application/grpc-web+proto"
  /// Per request; the JS flusher batches the same way.
  static let batchSize = 100

  static func endpoint(baseURL: String) -> URL? {
    var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    guard let url = URL(string: base + "/" + servicePath),
      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      url.host?.isEmpty == false
    else { return nil }
    return url
  }

  /// The headers of one call. `authorization` is the raw JWT, with no `Bearer ` prefix.
  static func headers(accessToken: String) -> [String: String] {
    [
      "content-type": contentType,
      "accept": contentType,
      "x-grpc-web": "1",
      "authorization": accessToken,
    ]
  }

  /// A gRPC-web data frame: `0x00`, big-endian length, protobuf.
  static func requestBody(for keys: [ReportKey]) -> Data {
    var message = Data()
    for key in keys {
      var event = Data()
      appendString(1, key.messageId, to: &event)
      appendString(2, key.subscriberId, to: &event)
      event.append(0x20)  // field 4, varint
      appendVarint(deliveredEventType, to: &event)
      message.append(0x0A)  // ReportEventsRequest.events
      appendVarint(UInt64(event.count), to: &message)
      message.append(event)
    }
    var frame = Data([0x00])
    var length = UInt32(message.count).bigEndian
    withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
    frame.append(message)
    return frame
  }

  /// The gRPC status of a response: the trailer frame (flag `0x80`) in the body (gRPC-web), else
  /// the `grpc-status` header. `nil` when neither says (an empty void response).
  static func grpcStatus(header: String?, body: Data?) -> Int? {
    if let status = trailerFrameStatus(body) { return status }
    guard let header else { return nil }
    // There but not a number: an unknown status (retried), not a missing one.
    return Int(header.trimmingCharacters(in: .whitespaces)) ?? -1
  }

  /// `application/grpc`, `application/grpc+proto`, `application/grpc-web…`, `application/grpc;…`.
  static func isGrpc(_ contentType: String?) -> Bool {
    let type = contentType?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    guard type.hasPrefix("application/grpc") else { return false }
    let rest = type.dropFirst("application/grpc".count)
    return rest.isEmpty || rest.hasPrefix("+") || rest.hasPrefix(";") || rest.hasPrefix("-web")
  }

  private static func trailerFrameStatus(_ body: Data?) -> Int? {
    guard let body else { return nil }
    var offset = 0
    var status: Int?
    while body.count - offset >= 5 {
      let flag = body[body.startIndex + offset]
      var length = 0
      for i in 1...4 { length = (length << 8) | Int(body[body.startIndex + offset + i]) }
      offset += 5
      guard length >= 0, offset + length <= body.count else { break }
      if flag & 0x80 != 0 {
        let text = String(decoding: body[(body.startIndex + offset)..<(body.startIndex + offset + length)], as: UTF8.self)
        // `isNewline`, not "\r" / "\n": "\r\n" is a single Character.
        for line in text.split(whereSeparator: \.isNewline) {
          let parts = line.split(separator: ":", maxSplits: 1)
          if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "grpc-status" {
            status = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? -1
          }
        }
      }
      offset += length
    }
    return status
  }

  /// What a finished call means, by the same rules as the JS flusher over
  /// `@connectrpc/connect` and the Android uploader. Outside 2xx only the HTTP status counts, mapped
  /// as gRPC-web's `codeFromHttpStatus` (401 Unauthenticated, 403 PermissionDenied, anything else,
  /// incl. 400 Internal and 404 Unimplemented, retried). A 2xx whose content type is not gRPC
  /// (`application/grpc*`: gRPC-web, or the plain gRPC a native server answers with; a captive
  /// portal or proxy answers 200 HTML) is retried; otherwise the trailer frame or `grpc-status`
  /// decides, and none at all is the empty success whose status native could not see (a plain gRPC
  /// server sends it in HTTP/2 trailers, which `URLSession` does not expose). That is only safe while
  /// the server reports a `ReportEvents` error trailers-only (`grpc-status` in the headers, as
  /// grpc-go and grpc-java do for an error before any message): an error sent after the headers, in
  /// HTTP/2 trailers, is invisible here and counted as sent. Android reads those trailers.
  static func outcome(
    httpStatus: Int, grpcStatusHeader: String?, contentType: String?, body: Data?
  ) -> ReportOutcome {
    switch httpStatus {
    case 200..<300:
      guard isGrpc(contentType) else { return .retry }
      switch grpcStatus(header: grpcStatusHeader, body: body) {
      case nil, 0?: return .sent
      case 16?: return .unauthenticated  // Unauthenticated
      case 3?, 5?, 7?: return .dropped  // InvalidArgument, NotFound, PermissionDenied
      default: return .retry
      }
    case 401: return .unauthenticated
    case 403: return .dropped  // PermissionDenied
    default: return .retry  // incl. 400 (Internal), 404 (Unimplemented), 408, 429, 5xx
    }
  }

  private static func appendString(_ field: UInt8, _ value: String, to data: inout Data) {
    let bytes = Array(value.utf8)
    data.append(field << 3 | 2)
    appendVarint(UInt64(bytes.count), to: &data)
    data.append(contentsOf: bytes)
  }

  private static func appendVarint(_ value: UInt64, to data: inout Data) {
    var v = value
    while v >= 0x80 {
      data.append(UInt8(v & 0x7F) | 0x80)
      v >>= 7
    }
    data.append(UInt8(v))
  }
}
