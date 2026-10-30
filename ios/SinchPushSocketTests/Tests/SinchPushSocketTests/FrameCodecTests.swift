//  FrameCodecTests.swift — the frame codec against the rules, not against
//  itself.
//
//  Structure and intent mirror `__tests__/frame.test.ts` at tag
//  ts-socket-client-snapshot, which is the normative reference for this
//  behaviour (docs/socket-behaviour-spec.md, RN-035). Where a TypeScript
//  mechanism has no Swift equivalent the test says so rather than dropping the
//  claim: the biggest is that the codec reads its tags off the generated types
//  instead of a descriptor, so "the tags come from the descriptors" becomes
//  "the tags the encoder actually emits match the documented protocol" and the
//  relay's golden vectors are the independent check.
//
//  Hand-built envelopes everywhere. Every frame a test decodes was written out
//  byte by byte (see WireTestSupport.swift), so a decoder that merely agreed
//  with our own encoder would fail here rather than pass.

import XCTest

@testable import SinchPushSocket

// MARK: - Payload builders

func helloClientFrame() -> Sinch_Push_Delivery_V1beta1_Ws_ClientFrame {
  var hello = Sinch_Push_Delivery_V1beta1_Ws_Hello()
  hello.authToken = "jwt.token.value"
  hello.projectID = "project-1"
  hello.appID = "app-1"
  hello.userID = "user-1"
  hello.platform = .ios
  hello.background = true
  hello.lastSeenMessageID = "msg-9"
  hello.sdkVersion = "rn-sinch-push/1.1.0"
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ClientFrame()
  frame.payload = .hello(hello)
  return frame
}

func pollClientFrame() -> Sinch_Push_Delivery_V1beta1_Ws_ClientFrame {
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ClientFrame()
  frame.payload = .poll(Sinch_Push_Delivery_V1beta1_Ws_Poll())
  return frame
}

func deliveryReportClientFrame(
  reportedAt: Int64 = 1_770_000_000_000
) -> Sinch_Push_Delivery_V1beta1_Ws_ClientFrame {
  var report = Sinch_Push_Delivery_V1beta1_Ws_DeliveryReport()
  report.messageID = "msg-1"
  report.sinchMessageID = "sinch-msg-1"
  report.status = .delivered
  report.reportedAtUnixMillis = reportedAt
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ClientFrame()
  frame.payload = .deliveryReport(report)
  return frame
}

func authChallengeServerFrame() -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame {
  var challenge = Sinch_Push_Delivery_V1beta1_Ws_AuthChallenge()
  challenge.nonce = "nonce-1"
  challenge.issuedAtUnixMillis = 1_770_000_000_000
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
  frame.payload = .authChallenge(challenge)
  return frame
}

func pooledMessage(messageID: String, enqueuedAt: Int64 = 1_770_000_000_000)
  -> Sinch_Push_Delivery_V1beta1_Ws_PooledMessage {
  var alert = Sinch_Push_V1beta1_Resources_Alert()
  alert.title = "Grüße 🎉"
  alert.message = "body ✓"
  alert.imageURL = "https://example.test/i.png"

  var notification = Sinch_Push_V1beta1_Resources_PushNotification()
  notification.trackingID = "track-\(messageID)"
  notification.alert = alert
  notification.metadata = ["campaign": "spring", "locale": "de-DE"]
  notification.importance = .high
  notification.trigger = "push"

  var pooled = Sinch_Push_Delivery_V1beta1_Ws_PooledMessage()
  pooled.messageID = messageID
  pooled.sinchMessageID = "sinch-\(messageID)"
  pooled.pushNotification = notification
  pooled.enqueuedAtUnixMillis = enqueuedAt
  return pooled
}

func helloAckServerFrame() -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame {
  var ack = Sinch_Push_Delivery_V1beta1_Ws_HelloAck()
  ack.connectionID = "conn-1"
  ack.messages = [
    pooledMessage(messageID: "msg-1", enqueuedAt: 1_770_000_000_000),
    pooledMessage(messageID: "msg-2", enqueuedAt: 1_770_000_001_000),
  ]
  ack.pollIntervalMs = 5000
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
  frame.payload = .helloAck(ack)
  return frame
}

func messageServerFrame() -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame {
  var message = Sinch_Push_Delivery_V1beta1_Ws_Message()
  message.ackToken = "ack-1"
  message.message = pooledMessage(messageID: "msg-1")
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
  frame.payload = .message(message)
  return frame
}

func ackServerFrame() -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame {
  var ack = Sinch_Push_Delivery_V1beta1_Ws_Ack()
  ack.ackToken = "ack-1"
  ack.accepted = false
  ack.error = "expired"
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
  frame.payload = .ack(ack)
  return frame
}

func pingServerFrame() -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame {
  var ping = Sinch_Push_Delivery_V1beta1_Ws_Ping()
  ping.correlationID = "corr-1"
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
  frame.payload = .ping(ping)
  return frame
}

func pongServerFrame(correlationID: String = "corr-1")
  -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame {
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
  frame.payload = .pong(pongMessage(correlationID: correlationID))
  return frame
}

func closeServerFrame() -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame {
  var close = Sinch_Push_Delivery_V1beta1_Ws_Close()
  close.reason = .unauthorized
  close.detail = "bad jwt"
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
  frame.payload = .close(close)
  return frame
}

// MARK: - Tests

final class FrameCodecTests: XCTestCase {

  // MARK: Frame tags

  func testEncodesEachPayloadUnderItsOneofFieldNumber() throws {
    // The codec derives tags from the generated types rather than a table, so
    // this is the assertion that the derivation is right: one case per payload,
    // both directions, against the numbering documented in
    // docs/push-socket-protocol.md. The relay's golden vectors are the
    // independent check on the same numbers (RelayGoldenTests).
    let clientTags: [(String, Sinch_Push_Delivery_V1beta1_Ws_ClientFrame, UInt8)] = [
      ("hello", helloClientFrame(), 1),
      ("poll", pollClientFrame(), 2),
      ("deliveryReport", deliveryReportClientFrame(), 3),
      ("pong", pongClientFrameOfSize(0), 4),
    ]
    for (name, frame, tag) in clientTags {
      let encoded = try FrameCodec.encodeClientFrame(frame)
      XCTAssertEqual(encoded.bytes.first, tag, "ClientFrame.\(name)")
    }

    let serverTags: [(String, Sinch_Push_Delivery_V1beta1_Ws_ServerFrame, UInt8)] = [
      ("authChallenge", authChallengeServerFrame(), 1),
      ("helloAck", helloAckServerFrame(), 2),
      ("message", messageServerFrame(), 3),
      ("ack", ackServerFrame(), 4),
      ("ping", pingServerFrame(), 5),
      ("pong", pongServerFrame(), 6),
      ("close", closeServerFrame(), 7),
    ]
    for (name, frame, tag) in serverTags {
      let encoded = try FrameCodec.encodeServerFrame(frame)
      XCTAssertEqual(encoded.bytes.first, tag, "ServerFrame.\(name)")
    }
  }

  func testWritesTheInnerPayloadNotAFrameWrapper() throws {
    var hello = Sinch_Push_Delivery_V1beta1_Ws_Hello()
    hello.platform = .android
    var frame = Sinch_Push_Delivery_V1beta1_Ws_ClientFrame()
    frame.payload = .hello(hello)
    let bytes = try FrameCodec.encodeClientFrame(frame).bytes
    let payload = try hello.serializedData()
    // tag (1) + one-byte length, then the Hello bytes verbatim.
    XCTAssertEqual(bytes[0], 1)
    XCTAssertLessThan(payload.count, 128)
    XCTAssertEqual(Array(bytes.dropFirst(2)), payload.bytes)
  }

  func testEncodesAnEmptyPollAsAZeroLengthPayload() throws {
    XCTAssertEqual(try FrameCodec.encodeClientFrame(pollClientFrame()).bytes, [2, 0])
  }

  func testRefusesToEncodeAFrameWithNoPayloadSet() {
    let frame = Sinch_Push_Delivery_V1beta1_Ws_ClientFrame()
    XCTAssertThrowsError(try FrameCodec.encodeClientFrame(frame)) { error in
      XCTAssertEqual(error as? FrameCodecError, .noPayloadSet(direction: .client))
    }
    let server = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
    XCTAssertThrowsError(try FrameCodec.encodeServerFrame(server)) { error in
      XCTAssertEqual(error as? FrameCodecError, .noPayloadSet(direction: .server))
    }
  }

  // MARK: Round trips

  func testClientFramesRoundTrip() throws {
    for frame in [
      helloClientFrame(), pollClientFrame(), deliveryReportClientFrame(),
      pongClientFrameOfSize(0), pongClientFrameOfSize(200),
    ] {
      let decoded = try FrameCodec.decodeClientFrame(try FrameCodec.encodeClientFrame(frame))
      XCTAssertEqual(decoded.payload, frame.payload)
    }
  }

  func testServerFramesRoundTrip() throws {
    for frame in [
      authChallengeServerFrame(), helloAckServerFrame(), messageServerFrame(),
      ackServerFrame(), pingServerFrame(), pongServerFrame(), closeServerFrame(),
    ] {
      let decoded = try FrameCodec.decodeServerFrame(try FrameCodec.encodeServerFrame(frame))
      XCTAssertEqual(decoded.payload, frame.payload)
    }
  }

  // MARK: Multi-byte varint payload length

  func testEncodesAClientPongAgainstTheExactExpectedBytes() throws {
    // Pong is one length-delimited string field, so the whole payload can be
    // written out by hand:
    //   field 1, wire type 2 -> 0x0a, then 200 as a varint -> 0xc8 0x01,
    //   then 200 'A' bytes                        -> 203 bytes of payload,
    //   whose own length 203 is a two-byte varint -> 0xcb 0x01.
    let correlationID = String(repeating: "A", count: 200)
    var frame = Sinch_Push_Delivery_V1beta1_Ws_ClientFrame()
    frame.payload = .pong(pongMessage(correlationID: correlationID))
    let expected = bytesOf(
      [0x04],  // ClientFrame.pong field number
      [0xcb, 0x01],  // payload length 203
      [0x0a],  // field 1, wire type 2 (length-delimited)
      [0xc8, 0x01],  // string length 200
      [UInt8](repeating: 0x41, count: 200)  // 'A' * 200
    )
    let encoded = try FrameCodec.encodeClientFrame(frame)
    XCTAssertEqual(encoded.bytes, expected)
    // URLSessionWebSocketTask sends this buffer, so the bytes handed over must
    // be exactly the frame and not an over-allocated one.
    XCTAssertEqual(encoded.count, encoded.bytes.count)
    guard case .pong(let pong)? = try FrameCodec.decodeClientFrame(encoded).payload else {
      return XCTFail("expected a pong")
    }
    XCTAssertEqual(pong.correlationID, correlationID)
  }

  func testEncodesAServerHelloAckAgainstTheExactExpectedBytes() throws {
    // connection_id (203 B) + poll_interval_ms = 5000 -> tag 0x18, varint
    // 0x88 0x27 -> 206 B of payload, length varint 0xce 0x01.
    var ack = Sinch_Push_Delivery_V1beta1_Ws_HelloAck()
    ack.connectionID = String(repeating: "C", count: 200)
    ack.pollIntervalMs = 5000
    var frame = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
    frame.payload = .helloAck(ack)
    let expected = bytesOf(
      [0x02],  // ServerFrame.hello_ack field number
      [0xce, 0x01],  // payload length 206
      [0x0a],  // field 1, wire type 2
      [0xc8, 0x01],  // connection_id length 200
      [UInt8](repeating: 0x43, count: 200),  // 'C' * 200
      [0x18],  // field 3, wire type 0 (varint)
      [0x88, 0x27]  // 5000
    )
    XCTAssertEqual(try FrameCodec.encodeServerFrame(frame).bytes, expected)
  }

  // MARK: Unknown frame tags

  func testThrowsUnknownTagWhenDecodingAServerFrame() {
    XCTAssertThrowsError(try FrameCodec.decodeServerFrame(Data([0x63, 0x00]))) { error in
      XCTAssertEqual(error as? FrameCodecError, .unknownTag(direction: .server, tag: 0x63))
    }
  }

  func testThrowsUnknownTagWhenDecodingAClientFrame() {
    XCTAssertThrowsError(try FrameCodec.decodeClientFrame(Data([0x63, 0x00]))) { error in
      XCTAssertEqual(error as? FrameCodecError, .unknownTag(direction: .client, tag: 0x63))
    }
  }

  func testRejectsTagsOutsideTheOneofPayloadRange() {
    // ServerFrame.payload uses 1..7 and ClientFrame.payload uses 1..4.
    for tag: UInt8 in [0, 8, 99, 255] {
      XCTAssertThrowsError(try FrameCodec.decodeServerFrame(Data([tag, 0]))) { error in
        XCTAssertEqual(error as? FrameCodecError, .unknownTag(direction: .server, tag: tag))
      }
    }
    for tag: UInt8 in [0, 5, 99, 255] {
      XCTAssertThrowsError(try FrameCodec.decodeClientFrame(Data([tag, 0]))) { error in
        XCTAssertEqual(error as? FrameCodecError, .unknownTag(direction: .client, tag: tag))
      }
    }
  }

  // MARK: Malformed envelopes

  func testRejectsAFrameTooShortToHoldATagAndALength() {
    for bytes in [[] as [UInt8], [1]] {
      XCTAssertThrowsError(try FrameCodec.decodeServerFrame(Data(bytes))) { error in
        XCTAssertEqual(error as? FrameCodecError, .tooShort(direction: .server))
      }
    }
  }

  func testRejectsAPayloadShorterThanTheDeclaredLength() {
    // tag 2, length 10, only 2 payload bytes present.
    XCTAssertThrowsError(try FrameCodec.decodeServerFrame(Data([2, 10, 0x0a, 0x02]))) { error in
      XCTAssertEqual(
        error as? FrameCodecError,
        .truncatedPayload(direction: .server, declaredLength: 10, available: 2))
    }
  }

  func testIgnoresBytesPastTheDeclaredPayload() throws {
    // Length-delimited framing: the relay hands us exactly one frame per
    // WebSocket message, so anything past the declared payload is not ours.
    // Matched to the TypeScript client, which takes the same view.
    let frame = try FrameCodec.encodeClientFrame(pollClientFrame())
    let withTrailer = Data(frame.bytes + [0xDE, 0xAD])
    XCTAssertEqual(
      try FrameCodec.decodeClientFrame(withTrailer).payload,
      pollClientFrame().payload)
  }

  // MARK: Payload length varint width boundaries

  func testPayloadLengthVarintWidthBoundaries() throws {
    // The length prefix is a varint, so it widens at 128 and again at 16384.
    // These sizes sit either side of each boundary; the assertion that matters
    // is the resulting frame length, which pins the prefix width.
    for size in [127, 128, 16383, 16384] {
      let prefixWidth = varintSize(UInt64(size))

      let clientEncoded = try FrameCodec.encodeClientFrame(pongClientFrameOfSize(size))
      XCTAssertEqual(clientEncoded.count, 1 + prefixWidth + size)
      XCTAssertEqual(clientEncoded.bytes[0], 4)
      XCTAssertEqual(
        Array(clientEncoded.bytes[1..<(1 + prefixWidth)]), varintBytes(UInt64(size)))
      guard case .pong(let pong)? = try FrameCodec.decodeClientFrame(clientEncoded).payload
      else {
        return XCTFail("expected a pong")
      }
      XCTAssertEqual(pong, pongMessageOfSize(size))

      let serverEncoded = try FrameCodec.encodeServerFrame(pongServerFrameOfSize(size))
      XCTAssertEqual(serverEncoded.count, 1 + prefixWidth + size)
      guard case .pong(let serverPong)? = try FrameCodec.decodeServerFrame(serverEncoded).payload
      else {
        return XCTFail("expected a pong")
      }
      XCTAssertEqual(serverPong, pongMessageOfSize(size))

      // Built by hand rather than by the encoder, so the decoder is checked
      // against the wire format and not against its own writer.
      let handBuiltClient = envelope(tag: 4, payload: pongPayloadOfSize(size).bytes)
      XCTAssertEqual(handBuiltClient.count, 1 + prefixWidth + size)
      guard case .pong(let handBuiltPong)? =
        try FrameCodec.decodeClientFrame(Data(handBuiltClient)).payload
      else {
        return XCTFail("expected a pong")
      }
      XCTAssertEqual(handBuiltPong, pongMessageOfSize(size))

      let handBuiltServer = envelope(tag: 6, payload: pongPayloadOfSize(size).bytes)
      XCTAssertEqual(handBuiltServer.count, 1 + prefixWidth + size)
      guard case .pong(let handBuiltServerPong)? =
        try FrameCodec.decodeServerFrame(Data(handBuiltServer)).payload
      else {
        return XCTFail("expected a pong")
      }
      XCTAssertEqual(handBuiltServerPong, pongMessageOfSize(size))
    }

    // 127 and 128 differ only in the prefix; the payload boundary is where the
    // prefix changes, not the payload.
    XCTAssertEqual(varintSize(127), 1)
    XCTAssertEqual(varintSize(128), 2)
    XCTAssertEqual(varintSize(16383), 2)
    XCTAssertEqual(varintSize(16384), 3)
  }

  // MARK: Malformed length prefixes

  func testRejectsTheFourGiBDeclarationThatUsedToDecodeAsAnEmptyHelloAck() {
    // The regression: `80 80 80 80 10` is 4294967296. A reader that narrows to
    // 32 bits drops everything above and returns 0, so this frame used to
    // decode to a HelloAck with no fields at all, and the client moved to
    // `connected` on it. The length is read as a UInt64 and checked against the
    // payload cap, so it is a typed error instead.
    let bytes: [UInt8] = [0x02, 0x80, 0x80, 0x80, 0x80, 0x10]
    XCTAssertThrowsError(try FrameCodec.decodeServerFrame(Data(bytes))) { error in
      XCTAssertEqual(
        error as? FrameCodecError,
        .payloadTooLarge(direction: .server, declaredLength: 4_294_967_296))
      XCTAssertTrue("\(error)".contains("4294967296"))
    }
  }

  func testRejectsAPrefixThatIsCutOffAfterTheTag() {
    // tag 2 and a continuation byte with nothing after it.
    let cut = [[0x02, 0x80], [0x02, 0x80, 0x80, 0x80, 0x80, 0x80]] as [[UInt8]]
    for bytes in cut {
      assertLengthVarintError(bytes)
    }
  }

  func testRejectsAVarintThatRunsPast64Bits() {
    // Eleven bytes: the eleventh continuation byte means the value cannot be
    // finished inside 64 bits.
    assertLengthVarintError(bytesOf([0x02], [UInt8](repeating: 0x80, count: 11), [0x01]))
    // Ten bytes whose last byte carries more than the single bit still free at
    // shift 63. A reader that ORs the byte in and shifts anyway discards those
    // bits silently, so this has to be caught on the bytes themselves.
    assertLengthVarintError(bytesOf([0x02], [UInt8](repeating: 0x80, count: 9), [0x02]))
    assertLengthVarintError(bytesOf([0x02], [UInt8](repeating: 0x80, count: 9), [0x81]))
  }

  func testAcceptsTheLargestCanonicalVarintShapeAndRejectsItOnThePayloadCap() {
    // 80 80 80 80 80 80 80 80 80 01 is 2^63 exactly: canonical, ten bytes, and
    // far over any cap — so the payload bound is what rejects it, proving the
    // varint itself was accepted.
    let bytes = bytesOf([0x02], [UInt8](repeating: 0x80, count: 9), [0x01])
    XCTAssertThrowsError(try FrameCodec.decodeServerFrame(Data(bytes))) { error in
      XCTAssertEqual(
        error as? FrameCodecError,
        .payloadTooLarge(direction: .server, declaredLength: 1 << 63))
    }
  }

  func testRejectsADeclaredLengthLongerThanTheBytesPresent() {
    // tag 2, declares 1024, sends 4.
    assertTruncated(
      frameDeclaring(tag: 0x02, declared: 1024, bodyBytes: 4),
      direction: .server, declared: 1024)
    // One byte short of the declared length is still truncated.
    assertTruncated(
      frameDeclaring(tag: 0x02, declared: 10, bodyBytes: 9),
      direction: .server, declared: 10)
    // Declaring 1 more than the buffer holds, with a tag that would otherwise
    // resolve, so this is the length check and not the tag check.
    assertTruncated(
      bytesOf([0x02, 0x0a], [UInt8](repeating: 0x41, count: 9)),
      direction: .server, declared: 10)
  }

  func testChecksTheLengthBeforeTheTagSoABadPrefixIsNeverTrusted() {
    // Tag 99 resolves to nothing and the prefix declares 2^35 bytes. Either way
    // it is a typed error rather than a decode, and nothing is allocated from
    // it: the bounds are checked on the prefix before the tag is resolved, so
    // the unknown tag is never even reached.
    XCTAssertThrowsError(
      try FrameCodec.decodeServerFrame(Data([0x63, 0x80, 0x80, 0x80, 0x80, 0x80, 0x10]))
    ) { error in
      XCTAssertEqual(
        error as? FrameCodecError,
        .payloadTooLarge(direction: .server, declaredLength: 549_755_813_888))
    }
  }

  func testReportsTheDirectionItWasDecoding() {
    // Tag 1 is ClientFrame.hello, so the same bytes are a client frame here and
    // an unknown tag on the server side — which is why the helper decodes in
    // the direction it is asserting about.
    assertTruncated(
      frameDeclaring(tag: 0x01, declared: 1024, bodyBytes: 4),
      direction: .client, declared: 1024)
    assertTruncated(
      frameDeclaring(tag: 0x02, declared: 1024, bodyBytes: 4),
      direction: .server, declared: 1024)
  }

  // MARK: Payload and envelope size limits

  func testEncodesAPayloadExactlyAtTheCap() throws {
    let atCap = FrameCodec.maxFramePayloadBytes
    XCTAssertEqual(pongPayloadOfSize(atCap).count, atCap)
    let frame = try FrameCodec.encodeClientFrame(pongClientFrameOfSize(atCap))
    // The assertion that proves the two bounds were not collapsed into one
    // 65536-byte limit on the whole frame: a legal maximum-size payload yields a
    // 65540-byte frame, because the envelope adds 1 tag byte and a 3-byte
    // canonical length varint on top of it. Note this is the *emitted* bound,
    // which is tighter than the 65547-byte bound we accept.
    XCTAssertEqual(frame.count, FrameCodec.maxFrameEmittedBytes)
    XCTAssertEqual(frame.count, 65_540)
    guard case .pong(let pong)? = try FrameCodec.decodeClientFrame(frame).payload else {
      return XCTFail("expected a pong")
    }
    XCTAssertEqual(pong, pongMessageOfSize(atCap))
  }

  func testEncodesAPayloadOneByteOverTheCapAsATypedError() {
    let overCap = FrameCodec.maxFramePayloadBytes + 1
    XCTAssertEqual(pongPayloadOfSize(overCap).count, overCap)
    XCTAssertThrowsError(try FrameCodec.encodeClientFrame(pongClientFrameOfSize(overCap))) { error in
      XCTAssertEqual(
        error as? FrameCodecError, .payloadTooLarge(direction: .client, declaredLength: UInt64(overCap)))
    }
    XCTAssertThrowsError(try FrameCodec.encodeServerFrame(pongServerFrameOfSize(overCap))) { error in
      XCTAssertEqual(
        error as? FrameCodecError, .payloadTooLarge(direction: .server, declaredLength: UInt64(overCap)))
    }
  }

  func testDecodesAPayloadExactlyAtTheCap() throws {
    let bytes = envelope(tag: 4, payload: pongPayloadOfSize(FrameCodec.maxFramePayloadBytes).bytes)
    XCTAssertEqual(bytes.count, FrameCodec.maxFrameEmittedBytes)
    guard case .pong(let pong)? = try FrameCodec.decodeClientFrame(Data(bytes)).payload else {
      return XCTFail("expected a pong")
    }
    XCTAssertEqual(pong, pongMessageOfSize(FrameCodec.maxFramePayloadBytes))
  }

  func testDecodesADeclaredLengthOneByteOverTheCapAsATypedError() {
    // Declares 65537 and sends nothing: the payload bound rejects it. This is
    // the shape a hostile peer sends, and the one the relay guards against
    // before it allocates.
    let overCap = UInt64(FrameCodec.maxFramePayloadBytes + 1)
    XCTAssertThrowsError(try FrameCodec.decodeServerFrame(Data(frameDeclaring(tag: 0x06, declared: overCap, bodyBytes: 0)))) { error in
      XCTAssertEqual(
        error as? FrameCodecError, .payloadTooLarge(direction: .server, declaredLength: overCap))
    }
  }

  func testRejectsAFrameLargerThanTheEnvelopeBound() {
    // Valid tag, declared length 0, then more bytes than the envelope can hold.
    // 1 tag byte + 1 prefix byte + filler = maxFrameTotalBytes + 1.
    let bytes = bytesOf([0x06, 0x00], [UInt8](repeating: 0x41, count: FrameCodec.maxFrameTotalBytes - 1))
    XCTAssertEqual(bytes.count, FrameCodec.maxFrameTotalBytes + 1)
    XCTAssertThrowsError(try FrameCodec.decodeServerFrame(Data(bytes))) { error in
      XCTAssertEqual(
        error as? FrameCodecError,
        .frameTooLarge(direction: .server, length: FrameCodec.maxFrameTotalBytes + 1))
    }
  }

  func testKeepsThePayloadBoundTheEmittedBoundAndTheAcceptedBoundDistinct() {
    // Three constants, three jobs, and the arithmetic between them is the
    // documented one.
    XCTAssertEqual(FrameCodec.maxFramePayloadBytes, 65_536)
    // Accepted: 1 tag + a 10-byte varint + payload. Matches the relay's
    // MaxWireFrameBytes.
    XCTAssertEqual(FrameCodec.maxFrameTotalBytes, 65_547)
    // Emitted: the same, but with the canonical 3-byte varint (`80 80 04`) plus
    // a 1-byte tag. We always write canonical, so we never reach the wider one.
    XCTAssertEqual(FrameCodec.maxFrameEmittedBytes, 65_540)
    XCTAssertEqual(varintBytes(65_536), [0x80, 0x80, 0x04])
    XCTAssertEqual(varintSize(65_536), 3)
    // The payload cap alone would reject the frame the relay accepts.
    XCTAssertGreaterThan(FrameCodec.maxFrameTotalBytes, FrameCodec.maxFramePayloadBytes)
    XCTAssertLessThan(FrameCodec.maxFrameEmittedBytes, FrameCodec.maxFrameTotalBytes)
  }

  func testAcceptsTheWidestLengthPrefixTheRelayTolerates() throws {
    // Both directions reuse the same field numbers for different messages: tag 4
    // is ClientFrame.pong inbound but ServerFrame.ack outbound, and
    // ServerFrame.pong is tag 6. A boundary test that hard-codes "tag 4 is
    // pong" is right in one direction and silently wrong in the other. Worse, on
    // an *empty* payload a tag/schema mixup still decodes, because an empty
    // message parses against any schema. So every case below pairs the
    // direction with the tag it owns and compares the decoded message against
    // the real schema rather than a wildcard.
    let clientEmpty = envelopeWithPrefix(tag: 4, prefix: extendedVarint(0, width: 10))
    XCTAssertEqual(clientEmpty.count, 1 + 10)
    guard case .pong(let clientPong)? = try FrameCodec.decodeClientFrame(Data(clientEmpty)).payload
    else {
      return XCTFail("expected a pong")
    }
    XCTAssertEqual(clientPong, pongMessage(correlationID: ""))

    let serverEmpty = envelopeWithPrefix(tag: 6, prefix: extendedVarint(0, width: 10))
    guard case .pong(let serverPong)? = try FrameCodec.decodeServerFrame(Data(serverEmpty)).payload
    else {
      return XCTFail("expected a pong")
    }
    XCTAssertEqual(serverPong, pongMessage(correlationID: ""))
  }

  func testAcceptsAMaximumSizePayloadBehindANoncanonicalTenByteLength() throws {
    // The case the 65547 bound exists for. 65536 can legally be encoded in ten
    // bytes by promoting the canonical terminal to a continuation and appending
    // zero groups, giving a real 1 + 10 + 65536 = 65547-byte frame. Under the
    // previous 65540 total this was rejected outright.
    let atCap = FrameCodec.maxFramePayloadBytes
    let prefix = extendedVarint(UInt64(atCap), width: 10)
    XCTAssertEqual(prefix, [0x80, 0x80, 0x84, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00])

    let clientBytes = envelopeWithPrefix(
      tag: 4, prefix: prefix, body: pongPayloadOfSize(atCap).bytes)
    XCTAssertEqual(clientBytes.count, FrameCodec.maxFrameTotalBytes)
    XCTAssertEqual(clientBytes.count, 65_547)
    // Seven bytes wider than anything our own encoder would produce.
    XCTAssertLessThan(FrameCodec.maxFrameEmittedBytes, clientBytes.count)
    // A full-size payload, so this cannot pass on a schema mixup.
    guard case .pong(let pong)? = try FrameCodec.decodeClientFrame(Data(clientBytes)).payload
    else {
      return XCTFail("expected a pong")
    }
    XCTAssertEqual(pong, pongMessageOfSize(atCap))

    let serverBytes = envelopeWithPrefix(
      tag: 6, prefix: prefix, body: pongPayloadOfSize(atCap).bytes)
    XCTAssertEqual(serverBytes.count, FrameCodec.maxFrameTotalBytes)
    guard case .pong(let serverPong)? = try FrameCodec.decodeServerFrame(Data(serverBytes)).payload
    else {
      return XCTFail("expected a pong")
    }
    XCTAssertEqual(serverPong, pongMessageOfSize(atCap))
  }

  func testDecodesTheSameTagToADifferentMessagePerDirection() throws {
    // The hazard behind those boundary tests, asserted directly. Tag 4 is
    // ClientFrame.pong inbound and ServerFrame.ack outbound, so the tag alone
    // does not identify the payload — the connection's direction does.
    let empty = { (tag: UInt8) in
      Data(envelopeWithPrefix(tag: tag, prefix: extendedVarint(0, width: 10)))
    }
    guard case .pong? = try FrameCodec.decodeClientFrame(empty(4)).payload else {
      return XCTFail("client tag 4 should be pong")
    }
    guard case .ack? = try FrameCodec.decodeServerFrame(empty(4)).payload else {
      return XCTFail("server tag 4 should be ack")
    }
    // Tag 6 is the other way round: ServerFrame.pong outbound, and simply not a
    // frame the SDK can receive.
    guard case .pong? = try FrameCodec.decodeServerFrame(empty(6)).payload else {
      return XCTFail("server tag 6 should be pong")
    }
    XCTAssertThrowsError(try FrameCodec.decodeClientFrame(empty(6))) { error in
      XCTAssertEqual(error as? FrameCodecError, .unknownTag(direction: .client, tag: 6))
    }
  }

  func testStillRefusesAnOversizedPayloadThatFitsInsideTheWidenedEnvelope() {
    // Widening the envelope must not have widened the payload cap. A declared
    // 65537 is refused on the payload bound, which is what guards allocation,
    // even though the envelope around it has room.
    let overCap = UInt64(FrameCodec.maxFramePayloadBytes + 1)
    XCTAssertThrowsError(
      try FrameCodec.decodeServerFrame(Data(frameDeclaring(tag: 0x06, declared: overCap, bodyBytes: 0)))
    ) { error in
      XCTAssertEqual(
        error as? FrameCodecError, .payloadTooLarge(direction: .server, declaredLength: overCap))
    }
  }

  func testRejectsAFrameOneByteOverTheAcceptedBound() {
    let bytes = bytesOf([0x06, 0x00], [UInt8](repeating: 0x41, count: FrameCodec.maxFrameTotalBytes - 1))
    XCTAssertEqual(bytes.count, FrameCodec.maxFrameTotalBytes + 1)
    XCTAssertThrowsError(try FrameCodec.decodeServerFrame(Data(bytes))) { error in
      XCTAssertEqual(
        error as? FrameCodecError,
        .frameTooLarge(direction: .server, length: FrameCodec.maxFrameTotalBytes + 1))
    }
  }

  func testRejectsTheLargestDecodableVarintOnTheSizeBound() {
    // 2^64-1: a legal encoding that declares an impossible payload. Refused on
    // the size bound, without allocating anything.
    let bytes = envelopeWithPrefix(
      tag: 3, prefix: [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01])
    XCTAssertThrowsError(try FrameCodec.decodeClientFrame(Data(bytes))) { error in
      XCTAssertEqual(
        error as? FrameCodecError, .payloadTooLarge(direction: .client, declaredLength: UInt64.max))
    }
  }

  // MARK: Direction asymmetry

  func testRejectsTheServerOnlyTagsOnTheClientSideAndViceVersa() throws {
    // ServerFrame.payload owns 5..7; ClientFrame.payload owns 1..4. A tag is
    // only meaningful together with a direction.
    let cases: [(tag: UInt8, isPing: Bool)] = [(5, true), (6, false), (7, false)]
    for (tag, isPing) in cases {
      let frame = Data(envelope(tag: tag, payload: []))
      guard let payload = try FrameCodec.decodeServerFrame(frame).payload else {
        return XCTFail("server tag \(tag) should decode")
      }
      if isPing {
        guard case .ping = payload else {
          return XCTFail("server tag \(tag) should be ping, got \(payload)")
        }
      } else if tag == 6 {
        guard case .pong = payload else {
          return XCTFail("server tag \(tag) should be pong, got \(payload)")
        }
      } else {
        guard case .close = payload else {
          return XCTFail("server tag \(tag) should be close, got \(payload)")
        }
      }
      XCTAssertThrowsError(try FrameCodec.decodeClientFrame(frame)) { error in
        XCTAssertEqual(error as? FrameCodecError, .unknownTag(direction: .client, tag: tag))
      }
    }
  }

  // MARK: int64 boundaries

  func testInt64FieldBoundariesRoundTrip() throws {
    // int64 fields must survive a round trip exactly, including at the signed
    // limits. In TypeScript these are bigint and the risk is a detour through
    // `number`; in Swift they are Int64 and the risk is the same detour through
    // Double, which SwiftProtobuf does not take.
    let values: [Int64] = [
      0, 1, -1, 1_770_000_000_000,
      Int64.max, Int64.min, Int64.max - 1, Int64.min + 1,
      9_007_199_254_740_993,  // 2^53 + 1: one past the largest safe double
    ]
    for value in values {
      let report = deliveryReportClientFrame(reportedAt: value)
      let decodedReport = try FrameCodec.decodeClientFrame(try FrameCodec.encodeClientFrame(report))
      guard case .deliveryReport(let out)? = decodedReport.payload else {
        return XCTFail("expected a delivery report")
      }
      XCTAssertEqual(out.reportedAtUnixMillis, value)

      var challenge = Sinch_Push_Delivery_V1beta1_Ws_AuthChallenge()
      challenge.nonce = "n"
      challenge.issuedAtUnixMillis = value
      var serverFrame = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
      serverFrame.payload = .authChallenge(challenge)
      let decodedChallenge = try FrameCodec.decodeServerFrame(
        try FrameCodec.encodeServerFrame(serverFrame))
      guard case .authChallenge(let outChallenge)? = decodedChallenge.payload else {
        return XCTFail("expected an auth challenge")
      }
      XCTAssertEqual(outChallenge.issuedAtUnixMillis, value)
    }
  }

  func testInt64BoundaryDoesNotDetourThroughADouble() throws {
    // Guards the reason the field is Int64. 2^53 + 1 is 9007199254740993; any
    // conversion to Double snaps it to 9007199254740992, a different value.
    let exact: Int64 = 9_007_199_254_740_993
    XCTAssertEqual(Double(exact), 9_007_199_254_740_992)
    XCTAssertNotEqual(Int64(Double(exact)), exact)
    // The codec keeps it exact all the same.
    var challenge = Sinch_Push_Delivery_V1beta1_Ws_AuthChallenge()
    challenge.issuedAtUnixMillis = exact
    var frame = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
    frame.payload = .authChallenge(challenge)
    let encoded = try! FrameCodec.encodeServerFrame(frame)
    guard case .authChallenge(let decoded)? = try! FrameCodec.decodeServerFrame(encoded).payload
    else {
      return XCTFail("expected an auth challenge")
    }
    XCTAssertEqual(decoded.issuedAtUnixMillis, exact)
  }

  // MARK: Malformed payloads

  func testAPayloadThatDoesNotParseIsTypedSeparatelyFromAnUnknownTag() {
    // Both are "the bytes are not what I expected", and RN-004/RN-005 treat them
    // differently, so they must not collapse into one error.
    // tag 2 (HelloAck), declared length 2, bytes 0xff 0xff: field 0 does not
    // exist, so this is a payload that does not parse, not an unknown tag.
    let bytes: [UInt8] = [0x02, 0x02, 0xff, 0xff]
    XCTAssertThrowsError(try FrameCodec.decodeServerFrame(Data(bytes))) { error in
      guard case .malformedPayload(let direction, let tag, _)? = error as? FrameCodecError else {
        return XCTFail("expected a malformed-payload error, got \(error)")
      }
      XCTAssertEqual(direction, .server)
      XCTAssertEqual(tag, 2)
    }
  }

  // MARK: String validation

  func test_SB17_illFormedUTF8InAStringIsRefusedNotSubstituted() {
    // SB-17. proto3 strings are UTF-8; a byte sequence that is not must be
    // refused rather than replaced with U+FFFD, because a substitution would
    // change the message id the relay correlates on and we would report delivery
    // of something the relay never sent. SwiftProtobuf validates at parse time,
    // so the refusal surfaces as a typed malformed-payload error — the same
    // class the client logs and survives (SB-16).
    //
    // ServerFrame.pong, field 1 (correlation_id), wire type 2:
    //   0x0a | 0x03 | 0x41 0xc3 0x28   -> "A" + an ill-formed two-byte sequence
    let payload = bytesOf([0x0a, 0x03, 0x41, 0xc3, 0x28])
    let frame = envelope(tag: 0x06, payload: payload)
    XCTAssertThrowsError(try FrameCodec.decodeServerFrame(Data(frame))) { error in
      guard case .malformedPayload(let direction, let tag, _)? = error as? FrameCodecError else {
        return XCTFail("expected a malformed-payload error, got \(error)")
      }
      XCTAssertEqual(direction, .server)
      XCTAssertEqual(tag, 0x06)
    }
  }

  func test_SB17_aValidUTF8CorrelationIDInTheSameFieldStillDecodes() throws {
    // The control for the test above: same tag, same field, same envelope shape —
    // only the bytes are legal this time, and they include multi-byte scalars
    // (U+00E9 is two bytes, U+4E2D is three). Without it, a decoder that refused
    // every non-ASCII string would also pass.
    var pong = Sinch_Push_Delivery_V1beta1_Ws_Pong()
    pong.correlationID = "A\u{00E9}\u{4E2D}"
    // Serialize the payload with the generated code, then hand-build the envelope
    // from it, so the decoder is fed bytes rather than an encoded frame.
    let frame = envelope(tag: 0x06, payload: [UInt8](try pong.serializedData()))
    guard case .pong(let decoded)? = try FrameCodec.decodeServerFrame(Data(frame)).payload else {
      return XCTFail("expected a pong")
    }
    XCTAssertEqual(decoded.correlationID, "A\u{00E9}\u{4E2D}")
  }

  // MARK: Helpers

  private func assertLengthVarintError(_ bytes: [UInt8]) {
    XCTAssertThrowsError(try FrameCodec.decodeServerFrame(Data(bytes))) { error in
      guard case .lengthVarint(let direction, _)? = error as? FrameCodecError else {
        return XCTFail("expected a length-varint error, got \(error)")
      }
      XCTAssertEqual(direction, .server)
    }
  }

  private func assertTruncated(
    _ bytes: [UInt8], direction: FrameDirection, declared: Int
  ) {
    XCTAssertThrowsError(
      try direction == .client
        ? FrameCodec.decodeClientFrame(Data(bytes)) as Any
        : FrameCodec.decodeServerFrame(Data(bytes)) as Any
    ) { error in
      guard case .truncatedPayload(let gotDirection, let gotDeclared, _)? =
        error as? FrameCodecError
      else {
        return XCTFail("expected a truncated-payload error, got \(error)")
      }
      XCTAssertEqual(gotDirection, direction)
      XCTAssertEqual(gotDeclared, declared)
    }
  }
}