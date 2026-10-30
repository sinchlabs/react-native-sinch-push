//  RelayGoldenTests.swift — conformance against the relay's golden wire vectors.
//
//  `ws_frames.v1beta1.golden.json` is generated from the same Go codec the relay
//  runs (relay: `make golden-vectors`), so it cannot drift from the relay's
//  implementation without a relay test failing. This suite is the Swift side of
//  that contract, and the Swift counterpart of `__tests__/relayGolden.test.ts`
//  at tag ts-socket-client-snapshot.
//
//  The fixture is pinned like the protos: `npm run proto:fetch` copies it out
//  of the relay commit recorded in proto-sources.json into this repository's
//  gitignored `proto-testdata/`, so the vectors tested here are the ones the
//  generated code was built from. RELAY_GOLDEN (file) and RELAY_DIR (relay
//  checkout) override it, exclusively: a path that does not exist skips rather
//  than falling through to the pinned copy. Without either, the sibling
//  `../sinch-push-relay` is the last resort, and when nothing resolves the
//  suite *skips* rather than fails — so `npm run test:ios` still works on a
//  machine with no relay checkout, and a green run with a skip is not evidence
//  of conformance.
//
//  The native parity gate applies: this suite is evidence about the
//  *specification*, not about the Swift client. It only becomes parity evidence
//  once it actually ran.

import Foundation
import XCTest

@testable import SinchPushSocket

// MARK: - Fixture

/// The relay fixture, and where it may be found.
enum GoldenFixture {
  /// The fixture path inside a relay checkout, and inside `proto-testdata/`.
  ///
  /// `proto-testdata/` holds the copy `npm run proto:fetch` took out of the
  /// pinned relay commit, so it is the default: a checkout that happens to be
  /// on a different branch would otherwise test the vectors against code
  /// generated from the pin.
  static let relativePath = "wire/ws_frames.v1beta1.golden.json"

  static var relayRelativePath: String { "testdata/\(relativePath)" }

  /// This repository's root, resolved from this source file rather than from the
  /// working directory, so the suite passes wherever `swift test` was invoked.
  static var repositoryRoot: URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    // proto-sources.json is this repository's own pin manifest, so it marks the
    // root without hard-coding the depth of the test package inside it.
    while !FileManager.default.fileExists(
      atPath: directory.appendingPathComponent("proto-sources.json").path)
    {
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { break }
      directory = parent
    }
    return directory
  }

  /// Last resort: a relay checkout next to the repository.
  static var siblingURL: URL {
    repositoryRoot
      .deletingLastPathComponent()
      .appendingPathComponent("sinch-push-relay")
  }

  /// The pinned copy, if `npm run proto:fetch` has been run.
  static var pinnedURL: URL {
    repositoryRoot
      .appendingPathComponent("proto-testdata")
      .appendingPathComponent(relativePath)
  }

  /// The candidates the environment names, highest precedence first.
  ///
  /// An override is an override: when RELAY_GOLDEN or RELAY_DIR is set it is the
  /// only candidate, and a path that does not exist skips the suite rather than
  /// falling through to the pinned copy or the sibling. Silently testing some
  /// other fixture would make the run say nothing about what was asked for.
  static var overridden: [URL]? {
    let environment = ProcessInfo.processInfo.environment
    if let golden = environment["RELAY_GOLDEN"], !golden.isEmpty {
      return [URL(fileURLWithPath: golden)]
    }
    if let relayDir = environment["RELAY_DIR"], !relayDir.isEmpty {
      return [
        URL(fileURLWithPath: relayDir).appendingPathComponent(relayRelativePath)
      ]
    }
    return nil
  }

  /// Every place the fixture may be, in the order they are tried.
  static var candidates: [URL] {
    if let overridden { return overridden }
    // The pinned copy first: a sibling checkout on another branch would otherwise
    // decide what this suite tests.
    return [pinnedURL, siblingURL.appendingPathComponent(relayRelativePath)]
  }

  /// The fixture this run tests.
  ///
  /// The first candidate that exists, or the first candidate when none does —
  /// so `load()` sees the path it was told to use and skips, rather than
  /// resolving to a pinned copy that happens to be there.
  static var url: URL {
    candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
  }

  static func load() throws -> Golden {
    guard FileManager.default.fileExists(atPath: url.path) else { return try skip() }
    return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
  }

  private static func skip() throws -> Golden {
    let how = overridden == nil
      ? """
      Run `npm run proto:fetch` to copy the pinned fixture into proto-testdata/, or set \
      RELAY_DIR (relay checkout) or RELAY_GOLDEN (file) to point at \(relayRelativePath).
      """
      : """
      RELAY_GOLDEN/RELAY_DIR names a fixture that does not exist, and an override is used as \
      given: this suite does not fall back to the pinned copy or a sibling checkout.
      """
    throw XCTSkip(
      """
      relay golden vectors not found.
      \(how)
      Looked in:
      \(candidates.map(\.path).joined(separator: "\n"))
      """)
  }
}

struct Golden: Decodable {
  struct SizeContract: Decodable {
    let maxFramePayloadBytes: Int
    let maxFrameEnvelopeBytes: Int
    let maxWireFrameBytes: Int
    let canonicalEnvelopeMaxBytes: Int

    enum CodingKeys: String, CodingKey {
      case maxFramePayloadBytes = "max_frame_payload_bytes"
      case maxFrameEnvelopeBytes = "max_frame_envelope_bytes"
      case maxWireFrameBytes = "max_wire_frame_bytes"
      case canonicalEnvelopeMaxBytes = "canonical_envelope_max_bytes"
    }
  }

  struct FrameType: Decodable {
    let direction: Direction
    let tag: Int
    let frameType: String

    enum CodingKeys: String, CodingKey {
      case direction, tag
      case frameType = "frame_type"
    }
  }

  struct Frame: Decodable {
    let name: String
    let direction: Direction
    let tag: Int
    let frameType: String
    let payloadLen: Int
    let frameHex: String

    enum CodingKeys: String, CodingKey {
      case name, direction, tag, payloadLen = "payload_len", frameHex = "frame_hex"
      case frameType = "frame_type"
    }
  }

  struct NegativeCase: Decodable {
    let name: String
    let direction: Direction
    let expect: String
    let frameHex: String

    enum CodingKeys: String, CodingKey {
      case name, direction, expect
      case frameHex = "frame_hex"
    }
  }

  enum Direction: String, Decodable {
    case clientToServer = "client_to_server"
    case serverToClient = "server_to_client"
  }

  let version: Int
  let sizeContract: SizeContract
  let frameTypes: [FrameType]
  let frames: [Frame]
  let negativeCases: [NegativeCase]

  enum CodingKeys: String, CodingKey {
    case version, frames
    case sizeContract = "size_contract"
    case frameTypes = "frame_types"
    case negativeCases = "negative_cases"
  }
}

// MARK: - Helpers

/// Decode in the direction the fixture names.
func decode(_ direction: Golden.Direction, _ frame: Data) throws {
  switch direction {
  case .clientToServer: _ = try FrameCodec.decodeClientFrame(frame)
  case .serverToClient: _ = try FrameCodec.decodeServerFrame(frame)
  }
}

/// Encode in the direction the fixture names.
func encode(_ direction: Golden.Direction, _ frame: Data) throws -> Data {
  switch direction {
  case .clientToServer: return try FrameCodec.encodeClientFrame(FrameCodec.decodeClientFrame(frame))
  case .serverToClient: return try FrameCodec.encodeServerFrame(FrameCodec.decodeServerFrame(frame))
  }
}

/// Whether a server payload carries a populated protobuf map.
///
/// A map is the one place where a decoded message cannot be re-encoded to the
/// same bytes: the wire carries entries in whatever order the writer chose, and
/// `Dictionary` does not remember it. The relay writes maps in sorted order
/// (Go's deterministic marshalling); SwiftProtobuf writes them in hash order,
/// which is not even stable across runs. So map-bearing vectors are checked for
/// a semantic round trip plus an identical envelope instead of identical bytes,
/// and this is why.
func carriesMapEntries(_ payload: Sinch_Push_Delivery_V1beta1_Ws_ServerFrame.OneOf_Payload)
  -> Bool {
  var notification: Sinch_Push_V1beta1_Resources_PushNotification?
  switch payload {
  case .helloAck(let ack): notification = ack.messages.first?.pushNotification
  case .message(let message): notification = message.message.pushNotification
  default: break
  }
  return !(notification?.metadata.isEmpty ?? true)
}

// MARK: - Tests

final class RelayGoldenTests: XCTestCase {

  func testLoadedTheFixtureTheRelayGenerated() throws {
    let golden = try GoldenFixture.load()
    XCTAssertEqual(golden.version, 1)
    // 48 = 19 client_to_server + 29 server_to_client: four of the client frames
    // are the device-info Hellos. A count, not just a non-empty check: a
    // truncated fixture has to fail here rather than make every loop below pass
    // over fewer vectors.
    XCTAssertEqual(golden.frames.count, 48)
    XCTAssertEqual(golden.negativeCases.count, 14)
  }

  func testAgreesWithTheRelayOnTheSizeContract() throws {
    // The payload bound is the protocol limit and is mirrored exactly.
    let golden = try GoldenFixture.load()
    XCTAssertEqual(FrameCodec.maxFramePayloadBytes, golden.sizeContract.maxFramePayloadBytes)
    XCTAssertEqual(FrameCodec.maxFrameTotalBytes, golden.sizeContract.maxWireFrameBytes)
    // canonical_envelope_max_bytes already counts the tag byte and the widest
    // canonical varint, so no extra envelope bytes are added here.
    XCTAssertEqual(
      FrameCodec.maxFrameEmittedBytes,
      golden.sizeContract.maxFramePayloadBytes + golden.sizeContract.canonicalEnvelopeMaxBytes)
    // 1 tag byte + a 10-byte length varint is the widest envelope on the wire.
    XCTAssertEqual(1 + 10, golden.sizeContract.maxFrameEnvelopeBytes)
  }

  func testDecodesEveryPositiveVectorToTheMessageTypeTheRelayNames() throws {
    let golden = try GoldenFixture.load()
    for vector in golden.frames {
      let frame = Data(bytes(hex: vector.frameHex))
      switch vector.direction {
      case .clientToServer:
        let decoded = try FrameCodec.decodeClientFrame(frame)
        XCTAssertEqual(
          clientCaseName(decoded.payload), camelCase(frameTypeComponent(vector.frameType)),
          "\(vector.name) decoded as the wrong payload")
      case .serverToClient:
        let decoded = try FrameCodec.decodeServerFrame(frame)
        XCTAssertEqual(
          serverCaseName(decoded.payload), camelCase(frameTypeComponent(vector.frameType)),
          "\(vector.name) decoded as the wrong payload")
      }
    }
  }

  func testEveryPositiveVectorIsDecodedAndReEncoded() throws {
    let golden = try GoldenFixture.load()
    for direction in [Golden.Direction.clientToServer, .serverToClient] {
      let vectors = golden.frames.filter { $0.direction == direction }
      XCTAssertFalse(vectors.isEmpty, "no \(direction) vectors in the fixture")
      for vector in vectors {
        let frame = Data(bytes(hex: vector.frameHex))
        let reencoded = try encode(direction, frame)
        var payload: Sinch_Push_Delivery_V1beta1_Ws_ServerFrame.OneOf_Payload?
        if direction == .serverToClient { payload = try FrameCodec.decodeServerFrame(frame).payload }
        if let payload, carriesMapEntries(payload) {
          // See carriesMapEntries: the envelope and the payload's length are
          // still pinned, and the message must survive the trip.
          XCTAssertEqual(reencoded.bytes[0], frame.bytes[0], "\(vector.name) tag")
          XCTAssertEqual(reencoded.count, frame.count, "\(vector.name) frame length")
          try decode(direction, reencoded)
        } else {
          XCTAssertEqual(
            hex(reencoded), vector.frameHex.lowercased(),
            "\(vector.name) did not re-encode byte for byte")
        }
      }
    }
  }

  // MARK: - Hello device info (fields 9-12)

  /// Just the four device-info fields, so the expectations below read as a
  /// sentence and a field added later does not silently widen the comparison.
  private struct DeviceInfo: Equatable {
    let installationID: String
    let osVersion: String
    let bundleID: String
    let backgroundService: Sinch_Push_V1beta1_Resources_BackgroundServiceState

    init(
      installationID: String,
      osVersion: String,
      bundleID: String,
      backgroundService: Sinch_Push_V1beta1_Resources_BackgroundServiceState
    ) {
      self.installationID = installationID
      self.osVersion = osVersion
      self.bundleID = bundleID
      self.backgroundService = backgroundService
    }

    init(_ hello: Sinch_Push_Delivery_V1beta1_Ws_Hello) {
      self.init(
        installationID: hello.installationID,
        osVersion: hello.osVersion,
        bundleID: hello.bundleID,
        backgroundService: hello.backgroundService)
    }
  }

  /// The device-info vectors the relay adds alongside Hello fields 9-12.
  private static let deviceInfoVectors: [(name: String, expected: DeviceInfo)] = [
    // iOS foreground: a background socket is not a thing, so UNSUPPORTED.
    (
      "client_hello_device_info",
      DeviceInfo(
        installationID: "6f1c2a9e-3b7d-4e8a-9c21-5d4b7a0e1f23",
        osVersion: "18.1",
        bundleID: "com.sinch.example",
        backgroundService: .unsupported)
    ),
    // background = true with ENABLED_RUNNING: the only pairing the relay treats
    // as reachable in the background.
    (
      "client_hello_android_bg_running",
      DeviceInfo(
        installationID: "0b8f3d52-7c1e-4a96-b5d0-2e9f6a4c8d17",
        osVersion: "14",
        bundleID: "com.sinch.example",
        backgroundService: .enabledRunning)
    ),
    // background_service = 99, a state this proto version does not define: it
    // has to survive as UNRECOGNIZED rather than be dropped or defaulted, so
    // an SDK meeting a newer relay still reports what the device said.
    (
      "client_hello_unknown_background_service",
      DeviceInfo(
        installationID: "0b8f3d52-7c1e-4a96-b5d0-2e9f6a4c8d17",
        osVersion: "14",
        bundleID: "com.sinch.example",
        backgroundService: .UNRECOGNIZED(99))
    ),
    // background_service = RELAY_DISABLED: the relay switch is off in the app,
    // so the SDK holds no socket and no background service. It has to land on
    // the named case — a generated enum without it would read this as
    // UNRECOGNIZED(5) and the SDK would report the wrong thing to the relay.
    (
      "client_hello_relay_disabled",
      DeviceInfo(
        installationID: "3c9e1f7a-52b4-4d08-9a6e-1b7c2d5e8f40",
        osVersion: "14",
        bundleID: "com.sinch.example",
        backgroundService: .relayDisabled)
    ),
  ]

  /// A named vector the fixture is supposed to carry, and what to do when it
  /// does not.
  ///
  /// These are errors, not skips. The vectors below are named because the relay
  /// pins them; a fixture that stopped carrying one — or that carries it as a
  /// different payload — is a regression in the pin, and `XCTSkip` would report
  /// that regression as a green run. Throwing stops the test on the spot with a
  /// message that says which vector broke and how.
  private enum VectorError: Error, CustomStringConvertible {
    case missing(String)
    case notAHello(String)
    case rewriteIsNotAHello(String)

    var description: String {
      switch self {
      case .missing(let name):
        return "the fixture no longer carries \(name)"
      case .notAHello(let name):
        return "\(name) is not a ClientFrame.hello any more"
      case .rewriteIsNotAHello(let name):
        return "\(name): the rewritten frame no longer decodes as a Hello"
      }
    }
  }

  private func helloVector(_ golden: Golden, _ name: String) throws -> (
    vector: Golden.Frame, hello: Sinch_Push_Delivery_V1beta1_Ws_Hello
  ) {
    guard let vector = golden.frames.first(where: { $0.name == name }) else {
      throw VectorError.missing(name)
    }
    let frame = try FrameCodec.decodeClientFrame(Data(bytes(hex: vector.frameHex)))
    guard case .some(.hello(let hello)) = frame.payload else {
      throw VectorError.notAHello(name)
    }
    return (vector, hello)
  }

  func testTheDeviceInfoHelloVectorsDecodeIntoTheNamedFields() throws {
    // Byte-for-byte round tripping does not prove the SDK *knows* fields 9-12:
    // SwiftProtobuf keeps a field it has no message member for as unknown data,
    // so a stale Generated/ would still re-emit the fixture's bytes. What the
    // relay reads is the named field, so that is what is asserted here.
    let golden = try GoldenFixture.load()
    for (name, expected) in Self.deviceInfoVectors {
      let (_, hello) = try helloVector(golden, name)
      XCTAssertEqual(DeviceInfo(hello), expected, "\(name): fields 9-12 decoded wrongly")
      if name == "client_hello_relay_disabled" {
        // CONTRACT 2.5: a relay-off Hello is an Android Hello with no background
        // service, or it contradicts itself. Kotlin asserts the same pair.
        XCTAssertEqual(hello.platform, .android, "\(name): platform")
        XCTAssertFalse(hello.background, "\(name): background")
      }
    }
  }

  func testADeviceInfoHelloCanBeChangedAndPutsTheNewValueOnTheWire() throws {
    // The write direction, which is the one a client performs. Unknown fields
    // are bytes inside the message, not members of it: there is nothing to
    // assign to, so a Generated/ without fields 9-12 cannot pass this by
    // reading alone.
    let golden = try GoldenFixture.load()
    for (name, expected) in Self.deviceInfoVectors {
      let (_, decoded) = try helloVector(golden, name)
      var hello = decoded
      hello.osVersion = "17.4"
      var frame = Sinch_Push_Delivery_V1beta1_Ws_ClientFrame()
      frame.payload = .hello(hello)
      let reencoded = try FrameCodec.encodeClientFrame(frame)
      let decodedAgain = try FrameCodec.decodeClientFrame(reencoded)
      guard case .some(.hello(let round)) = decodedAgain.payload else {
        throw VectorError.rewriteIsNotAHello(name)
      }
      XCTAssertEqual(
        DeviceInfo(round),
        DeviceInfo(
          installationID: expected.installationID,
          osVersion: "17.4",
          bundleID: expected.bundleID,
          backgroundService: expected.backgroundService),
        "\(name): rewriting os_version lost or changed another device-info field")
      XCTAssertEqual(reencoded.bytes.first, 1, "\(name): the rewritten frame is not a client Hello")
    }
  }

  func testAnOlderHelloCarriesNoDeviceInfo() throws {
    // The vector that predates the fields. It still has to decode, and the new
    // members must read as absent rather than as a value the relay would read.
    let golden = try GoldenFixture.load()
    let (_, hello) = try helloVector(golden, "client_hello_full")
    XCTAssertEqual(hello.sdkVersion, "1.2.3")
    XCTAssertEqual(hello.installationID, "")
    XCTAssertEqual(hello.osVersion, "")
    XCTAssertEqual(hello.bundleID, "")
    XCTAssertEqual(hello.backgroundService, .unspecified)
  }

  func testEveryNegativeVectorIsHandledTheWayTheRelayExpects() throws {
    let golden = try GoldenFixture.load()
    for negative in golden.negativeCases {
      let frame = Data(bytes(hex: negative.frameHex))
      if negative.expect == "accepted" {
        // Documented leniency: the relay accepts this, so we must too.
        XCTAssertNoThrow(
          try decode(negative.direction, frame),
          "\(negative.name): \(negative.expect) but the codec threw")
        continue
      }
      XCTAssertThrowsError(
        try decode(negative.direction, frame),
        "\(negative.name): expected a failure but the frame decoded")
    }
  }

  func testNegativeVectorsFailWithATypedErrorInTheExpectedClass() throws {
    // Stronger than "it threw": the relay names *why* in `expect`, and so does
    // the Swift codec, so the two classifications are checked against each
    // other. These groupings mirror the TypeScript client's
    // MalformedFrameError reasons and are the Swift rendering of the relay's
    // strings.
    let golden = try GoldenFixture.load()
    for negative in golden.negativeCases where negative.expect != "accepted" {
      let frame = Data(bytes(hex: negative.frameHex))
      do {
        try decode(negative.direction, frame)
        XCTFail("\(negative.name): expected \(negative.expect) but it decoded")
      } catch let error as FrameCodecError {
        XCTAssertTrue(
          acceptable(error, for: negative.expect),
          "\(negative.name): expected \(negative.expect), got \(error)")
      }
    }
  }

  func testZeroPaddedLengthVarintsAreToleratedTheWayTheRelayToleratesThem() throws {
    // `length_zero_padded_accepted` is the relay's documented leniency: the
    // length varint may be zero-padded out to 10 bytes. Protobuf accepts this
    // and so must we, or we reject frames the relay considers valid.
    let golden = try GoldenFixture.load()
    guard let padded = golden.negativeCases.first(where: { $0.name == "length_zero_padded_accepted" })
    else {
      throw XCTSkip("the fixture no longer carries length_zero_padded_accepted")
    }
    XCTAssertNoThrow(try decode(padded.direction, Data(bytes(hex: padded.frameHex))))
  }

  func testTheRelayTagTableMatchesTheTagsTheEncoderEmits() throws {
    // The independent check on the codec's derivation. FrameCodec writes no
    // field numbers down: it reads them off the generated `traverse`. So the
    // encoder's output is compared against the relay's own tag table here,
    // which is the only place in the Swift side where those numbers appear as
    // literals — and it is the fixture, not us.
    let golden = try GoldenFixture.load()
    XCTAssertFalse(golden.frameTypes.isEmpty)
    for entry in golden.frameTypes {
      switch entry.direction {
      case .clientToServer:
        let frame = clientFrameFor(frameType: entry.frameType)
        XCTAssertEqual(
          try FrameCodec.encodeClientFrame(frame).bytes.first, UInt8(entry.tag),
          "\(entry.frameType) should go out on tag \(entry.tag)")
      case .serverToClient:
        let frame = serverFrameFor(frameType: entry.frameType)
        XCTAssertEqual(
          try FrameCodec.encodeServerFrame(frame).bytes.first, UInt8(entry.tag),
          "\(entry.frameType) should go out on tag \(entry.tag)")
      }
    }
  }

  func testTheRelayTagTableCoversExactlyThePayloadsTheProtosDeclare() throws {
    let golden = try GoldenFixture.load()
    XCTAssertEqual(
      Set(golden.frameTypes.filter { $0.direction == .clientToServer }.map(\.tag)),
      [1, 2, 3, 4])
    XCTAssertEqual(
      Set(golden.frameTypes.filter { $0.direction == .serverToClient }.map(\.tag)),
      [1, 2, 3, 4, 5, 6, 7])
  }

  // MARK: - Classification

  /// Which ``FrameCodecError`` cases a relay `expect` string may produce.
  ///
  /// The relay's vocabulary and ours do not line up one to one — it says
  /// "unexpected EOF" where we say `truncatedPayload` *or* `lengthVarint` —
  /// so the mapping is a set per expectation rather than a single case.
  private func acceptable(_ error: FrameCodecError, for expect: String) -> Bool {
    switch expect {
    case "unexpected EOF":
      // Either the body ends early, or the length prefix itself never
      // terminates. Both are "the stream ran out" to the relay.
      if case .truncatedPayload = error { return true }
      if case .lengthVarint = error { return true }
      return false
    case "frame_too_large":
      if case .payloadTooLarge = error { return true }
      if case .frameTooLarge = error { return true }
      return false
    case "varint overflows uint64":
      if case .lengthVarint = error { return true }
      return false
    case "unknown_type_tag", "wrong_direction_tag":
      // A server-only tag read on the client side is an unknown tag here: the
      // frame type has no payload with that field number. The relay closes with
      // detail=wrong_direction_tag; the codec only knows "not mine".
      if case .unknownTag = error { return true }
      return false
    default:
      XCTFail("the fixture names an expectation this suite does not classify: \(expect)")
      return false
    }
  }

  // MARK: - Names

  private func frameTypeComponent(_ frameType: String) -> String {
    frameType.split(separator: ".").last.map(String.init) ?? frameType
  }

  /// `delivery_report` -> `deliveryReport`. The fixture names proto fields
  /// (snake_case); SwiftProtobuf names the oneof case in camelCase.
  private func camelCase(_ snake: String) -> String {
    var out = ""
    var upperNext = false
    for character in snake {
      if character == "_" {
        upperNext = true
      } else if upperNext {
        out.append(Character(character.uppercased()))
        upperNext = false
      } else {
        out.append(character)
      }
    }
    return out
  }

  private func clientCaseName(_ payload: Sinch_Push_Delivery_V1beta1_Ws_ClientFrame.OneOf_Payload?)
    -> String {
    switch payload {
    case .hello?: return "hello"
    case .poll?: return "poll"
    case .deliveryReport?: return "deliveryReport"
    case .pong?: return "pong"
    case .none: return "none"
    }
  }

  private func serverCaseName(_ payload: Sinch_Push_Delivery_V1beta1_Ws_ServerFrame.OneOf_Payload?)
    -> String {
    switch payload {
    case .authChallenge?: return "authChallenge"
    case .helloAck?: return "helloAck"
    case .message?: return "message"
    case .ack?: return "ack"
    case .ping?: return "ping"
    case .pong?: return "pong"
    case .close?: return "close"
    case .none: return "none"
    }
  }

  private func clientFrameFor(frameType: String) -> Sinch_Push_Delivery_V1beta1_Ws_ClientFrame {
    switch frameTypeComponent(frameType) {
    case "hello": return helloClientFrame()
    case "poll": return pollClientFrame()
    case "delivery_report": return deliveryReportClientFrame()
    case "pong": return pongClientFrameOfSize(0)
    default: preconditionFailure("the relay names a client payload this SDK does not: \(frameType)")
    }
  }

  private func serverFrameFor(frameType: String) -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame {
    switch frameTypeComponent(frameType) {
    case "auth_challenge": return authChallengeServerFrame()
    case "hello_ack": return helloAckServerFrame()
    case "message": return messageServerFrame()
    case "ack": return ackServerFrame()
    case "ping": return pingServerFrame()
    case "pong": return pongServerFrame()
    case "close": return closeServerFrame()
    default: preconditionFailure("the relay names a server payload this SDK does not: \(frameType)")
    }
  }
}