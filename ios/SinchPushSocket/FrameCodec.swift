//  FrameCodec.swift — the delivery-service WebSocket envelope (RN-032).
//
//  Pure Swift. No React Native, no UIKit, no Foundation beyond `Data`: this
//  file is compiled twice, by CocoaPods inside the app and by
//  ios/SinchPushSocketTests under `swift test`, and it is the reason the test
//  package exists. Nothing here may import anything the test host does not have.
//
//  We own exactly two things, and everything else is SwiftProtobuf:
//
//    1. the envelope      [1-byte tag][varint payload length][payload]
//    2. the tag ↔ payload relationship, which is *derived* from the generated
//       types rather than written down
//
//  On the second point. A frame carries exactly one `oneof payload` member, and
//  the envelope tag is that member's protobuf field number
//  (websocket.proto:11). SwiftProtobuf has no runtime descriptor object to walk
//  the way protobuf-es does, but the generated `traverse` answers the same
//  question, so both directions read the tag back off the generated code:
//
//    * Encoding. A frame with one payload set serialises to
//      `key || length || payload`, and for a length-delimited field the key is
//      `(fieldNumber << 3) | 2`. The leading key of the frame's *own*
//      serialisation is therefore the tag, and everything after the key and the
//      length prefix is the payload to put on the wire.
//
//    * Decoding. `[tag][length][payload]` with the tag turned back into the key
//      it stands for *is* a valid encoding of the frame message, so rebuilding
//      it and handing it to the generated `init(serializedBytes:)` resolves the
//      tag to the right payload with the generated field numbers.
//
//  So no field number, no tag table and no payload switch appear anywhere in
//  this file: re-run `npm run proto:gen:swift` and the codec follows the protos.
//  ios/SinchPushSocketTests/FrameCodecTests.swift pins the derived tags against
//  the relay's own golden vectors, so "derived" cannot quietly become "wrong".
//
//  The bounds below are the protocol contract, not tuning knobs, and they are
//  the Priority 0 items of tickets/RN-030 — a hostile or broken peer is the
//  reason they are spelled out one by one. The TypeScript client this code
//  replaces is preserved at tag `ts-socket-client-snapshot`
//  (`src/pushSocket/frame.ts`); the rules and their reasoning are the same file
//  by file, and the differences are called out where they exist.
//
//  Visibility: everything here is `internal`, because that is what SwiftProtobuf
//  generates by default and a `public` signature cannot mention an `internal`
//  type. It costs nothing today — the pod is one module, so the `@objc` facade
//  the bridge talks to sees the codec, and the test target uses
//  `@testable import`. When the core is lifted into a module of its own (the
//  RN-032 goal), add `Visibility=Public` to the Swift plugin in
//  buf.gen.swift.yaml and widen these declarations in the same pass.

import Foundation
import SwiftProtobuf

// MARK: - Direction

/// Which side of the connection a frame travels on.
///
/// A tag is only meaningful together with a direction: field number 4 is
/// `ClientFrame.pong` inbound and `ServerFrame.ack` outbound, so nothing here
/// takes a tag without one.
enum FrameDirection: String, Sendable, Equatable {
  case client
  case server
}

// MARK: - Errors

/// Why an envelope could not be read or written.
///
/// Every case is typed and carries the direction, because the two are decided
/// by different layers: an envelope that does not parse is wrong no matter which
/// SDK reads it, while an unrecognised tag means the peer is ahead of this build
/// and the bytes around it are fine. RN-004/RN-005 apply a different policy to
/// the two — drop the frame, or fail the connection — so they stay distinct.
enum FrameCodecError: Error, Equatable, Sendable {
  /// Fewer than a tag byte plus a length byte.
  case tooShort(direction: FrameDirection)
  /// The length prefix is unterminated, or overflows 64 bits.
  case lengthVarint(direction: FrameDirection, detail: String)
  /// The declared (or to-be-written) payload is over `maxFramePayloadBytes`.
  case payloadTooLarge(direction: FrameDirection, declaredLength: UInt64)
  /// The whole frame is over `maxFrameTotalBytes`.
  case frameTooLarge(direction: FrameDirection, length: Int)
  /// Fewer payload bytes are present than the prefix declared.
  case truncatedPayload(direction: FrameDirection, declaredLength: Int, available: Int)
  /// The tag does not name a payload of the expected frame type.
  case unknownTag(direction: FrameDirection, tag: UInt8)
  /// The bytes inside the envelope are not a well-formed payload message.
  case malformedPayload(direction: FrameDirection, tag: UInt8, detail: String)
  /// Nothing was set in the frame's `oneof payload`, so there is no envelope.
  case noPayloadSet(direction: FrameDirection)
  /// The frame's own serialisation was not one length-delimited field, which
  /// the generated code cannot produce for a frame with a payload set.
  case noEnvelope(direction: FrameDirection, detail: String)
}

extension FrameCodecError: CustomStringConvertible {
  var description: String {
    switch self {
    case .tooShort(let direction):
      return "ws frame (\(direction)): too short"
    case .lengthVarint(let direction, let detail):
      return "ws frame (\(direction)): \(detail)"
    case .payloadTooLarge(let direction, let declaredLength):
      return "ws frame (\(direction)): declared payload \(declaredLength) bytes exceeds \(FrameCodec.maxFramePayloadBytes)"
    case .frameTooLarge(let direction, let length):
      return "ws frame (\(direction)): \(length) bytes exceeds the \(FrameCodec.maxFrameTotalBytes)-byte frame limit"
    case .truncatedPayload(let direction, let declaredLength, let available):
      return "ws frame (\(direction)): truncated payload (need \(declaredLength) bytes, have \(available))"
    case .unknownTag(let direction, let tag):
      return "ws frame (\(direction)): unknown frame tag \(tag)"
    case .malformedPayload(let direction, let tag, let detail):
      return "ws frame (\(direction)): payload for tag \(tag) does not parse (\(detail))"
    case .noPayloadSet(let direction):
      return "ws frame (\(direction)): frame has no payload set"
    case .noEnvelope(let direction, let detail):
      return "ws frame (\(direction)): \(detail)"
    }
  }
}

extension FrameCodecError: LocalizedError {
  var errorDescription: String? { description }
}

// MARK: - Codec

/// The delivery-service WebSocket frame codec.
enum FrameCodec {
  // MARK: Size contract

  /// Largest protobuf payload a single frame may carry, in bytes.
  ///
  /// This is the v1beta1 protocol contract, not a placeholder. It mirrors
  /// `MaxFramePayloadBytes` in the relay's `internal/ws/codec.go`, which the
  /// relay enforces inbound *before* it allocates the declared length and
  /// outbound before it writes. The relay's `docs/protocol-contract.md` is the
  /// source of truth for the number; it exists here so the SDK cannot produce a
  /// frame the relay would refuse.
  ///
  /// The bound is on the *payload*, not on the frame — see
  /// ``maxFrameTotalBytes`` for the other, larger number.
  static let maxFramePayloadBytes = 65_536

  /// Widest varint a *canonical* length prefix can need. 65536 encodes as
  /// `80 80 04`, so three bytes is the most the length prefix occupies in a
  /// frame this SDK writes.
  static let canonicalLengthVarintMaxBytes = 3

  /// Widest varint a length prefix can legally occupy on the wire: 10 bytes for
  /// a 64-bit value. Protobuf accepts a non-minimal encoding of the same
  /// length — see ``maxFrameTotalBytes`` — and the relay's `readVarint`
  /// accepts it too.
  static let lengthVarintMaxBytes64 = 10

  /// Largest *whole* frame this SDK will accept on the wire, in bytes.
  ///
  /// Derived from ``maxFramePayloadBytes`` and never configured on its own:
  /// 1 tag byte + at most ``lengthVarintMaxBytes64`` length-varint bytes + at
  /// most ``maxFramePayloadBytes`` payload bytes = `1 + 10 + 65536 = 65547`,
  /// matching the relay's `MaxWireFrameBytes`.
  ///
  /// The gap between this and ``maxFrameEmittedBytes`` is real for
  /// noncanonical peers. A length does not have to be encoded canonically:
  /// setting the canonical terminal byte's high bit and appending zero groups
  /// preserves the value at any width up to 10 bytes, so 65536 can legitimately
  /// arrive as the ten-byte `80 80 84 80 80 80 80 80 80 00`, making a real frame
  /// `1 + 10 + 65536 = 65547` bytes. Our own encoder never emits one.
  ///
  /// Note the trap in the other direction, because the obvious padding is
  /// wrong: leading `0x80` bytes *shift* the value rather than preserving it, so
  /// `[80 80 04]` padded to ten bytes as `[80 x7 80 80 04]` decodes to
  /// 65536·128⁷. Widening the bound is only safe because ``readVarint`` still
  /// rejects a tenth byte above `0x01`.
  ///
  /// The payload cap stays the real safety limit: nothing is ever allocated on
  /// the strength of a length prefix, only bounded by
  /// ``maxFramePayloadBytes``. The two limits are deliberately separate and both
  /// are enforced. Collapsing them into one 65536-byte check on the frame would
  /// reject a legal maximum-size payload.
  static let maxFrameTotalBytes = maxFramePayloadBytes + 1 + lengthVarintMaxBytes64

  /// Largest frame this SDK ever *writes*, which is strictly smaller than what
  /// it accepts. We always emit a canonical varint, so the widest frame we
  /// produce is `1 + 3 + 65536 = 65540`. Exported so the asymmetry is asserted
  /// rather than assumed: emit canonical, accept a noncanonical extension.
  static let maxFrameEmittedBytes =
    maxFramePayloadBytes + 1 + canonicalLengthVarintMaxBytes

  // MARK: Decoding

  /// Decode an inbound server frame.
  ///
  /// - Throws: ``FrameCodecError/unknownTag(direction:tag:)`` when the tag names
  ///   no `ServerFrame` payload, and a malformed-envelope error otherwise.
  static func decodeServerFrame(
    _ data: Data
  ) throws -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame {
    let decoded: (frame: Sinch_Push_Delivery_V1beta1_Ws_ServerFrame, tag: UInt8) =
      try decodeFrame(data, direction: .server)
    guard decoded.frame.payload != nil else {
      throw FrameCodecError.unknownTag(direction: .server, tag: decoded.tag)
    }
    return decoded.frame
  }

  /// Decode an inbound client frame. The SDK only ever *sends* client frames,
  /// so this exists for tests and for the golden vectors of RN-002.
  static func decodeClientFrame(
    _ data: Data
  ) throws -> Sinch_Push_Delivery_V1beta1_Ws_ClientFrame {
    let decoded: (frame: Sinch_Push_Delivery_V1beta1_Ws_ClientFrame, tag: UInt8) =
      try decodeFrame(data, direction: .client)
    guard decoded.frame.payload != nil else {
      throw FrameCodecError.unknownTag(direction: .client, tag: decoded.tag)
    }
    return decoded.frame
  }

  // MARK: Encoding

  /// Encode a `ClientFrame` as `[tag][varint length][protobuf payload]`.
  static func encodeClientFrame(
    _ frame: Sinch_Push_Delivery_V1beta1_Ws_ClientFrame
  ) throws -> Data {
    try encodeFrame(frame, direction: .client) { $0.payload == nil }
  }

  /// Encode a `ServerFrame` the same way.
  static func encodeServerFrame(
    _ frame: Sinch_Push_Delivery_V1beta1_Ws_ServerFrame
  ) throws -> Data {
    try encodeFrame(frame, direction: .server) { $0.payload == nil }
  }

  // MARK: - Envelope

  /// A frame split into its envelope tag and the span of the frame message's own
  /// protobuf encoding.
  ///
  /// The span runs from the *second* byte of the frame — the tag byte is not a
  /// protobuf key — to the end of the declared payload, so it holds the length
  /// prefix and the payload verbatim.
  private struct Envelope {
    let direction: FrameDirection
    let tag: UInt8
    /// Offsets from the start of the buffer, not `Data` indices.
    let bodyStart: Int
    let bodyEnd: Int
  }

  /// Read the envelope, applying both bounds before anything is sliced.
  private static func readEnvelope(_ direction: FrameDirection, _ data: Data) throws -> Envelope {
    guard data.count >= 2 else {
      throw FrameCodecError.tooShort(direction: direction)
    }
    guard data.count <= maxFrameTotalBytes else {
      throw FrameCodecError.frameTooLarge(direction: direction, length: data.count)
    }
    let (tag, declaredLength, prefixWidth) = try data.withUnsafeBytes { raw in
      let tag = raw[0]
      let (length, width) = try readVarint(direction: direction, bytes: raw, from: 1)
      return (tag, length, width)
    }
    // The bound that guards allocation, checked against the length as read —
    // a UInt64, never narrowed first. A declared length of 2^32 truncated to
    // Int is not a near miss: `80 80 80 80 10` truncates to 0, and the decoder
    // then returns an empty HelloAck the client moves to `connected` on. The
    // TypeScript client shipped a fix for exactly that
    // (ts-socket-client-snapshot: `reader.uint64()`); `Int(declaredLength)`
    // below is only reached because the value is now known to be ≤ 65536.
    guard declaredLength <= UInt64(maxFramePayloadBytes) else {
      throw FrameCodecError.payloadTooLarge(
        direction: direction, declaredLength: declaredLength)
    }
    let length = Int(declaredLength)
    let bodyStart = 1 + prefixWidth
    // Cannot overflow: both operands are at most 65547.
    let bodyEnd = bodyStart + length
    guard bodyEnd <= data.count else {
      throw FrameCodecError.truncatedPayload(
        direction: direction,
        declaredLength: length,
        available: max(0, data.count - bodyStart)
      )
    }
    return Envelope(direction: direction, tag: tag, bodyStart: bodyStart, bodyEnd: bodyEnd)
  }

  /// Build the frame message's own protobuf encoding from a received envelope.
  ///
  /// `[tag][length][payload]` with the raw tag byte replaced by the key it
  /// stands for, which is exactly a wire encoding of the frame message, so the
  /// generated decoder resolves the tag to a payload with the generated field
  /// numbers.
  private static func protobufBody(
    direction: FrameDirection,
    envelope: Envelope,
    of data: Data
  ) throws -> Data {
    // Field number 0 is not a field: protobuf reserves it, so a zero tag can
    // never resolve to a payload and must not be dressed up as one.
    guard envelope.tag != 0 else {
      throw FrameCodecError.unknownTag(direction: direction, tag: envelope.tag)
    }
    // (fieldNumber << 3) | 2 — wire type 2, length-delimited, is what a
    // `oneof payload` member always is. The tag goes on the wire as one raw
    // byte, so a field number above 255 would wrap; that is caught here rather
    // than by sending a frame the relay reads as a different payload type.
    let key = UInt32(envelope.tag) << 3 | 0x02
    var body = Data()
    // Everything from the length prefix onwards, verbatim: the rebuilt message
    // is `key || length || payload`, and re-encoding the length here would throw
    // away the peer's own prefix — including a noncanonical one, which protobuf
    // accepts and which the relay tolerates.
    body.reserveCapacity(envelope.bodyEnd - 1 + keyWidth(for: key))
    appendCanonicalVarint(UInt64(key), to: &body)
    body.append(data[(data.startIndex + 1)..<(data.startIndex + envelope.bodyEnd)])
    return body
  }

  /// Split a frame message's own serialisation into its envelope tag and the
  /// payload that goes on the wire.
  private static func splitEnvelope(
    direction: FrameDirection,
    _ wire: Data
  ) throws -> (tag: UInt8, payload: Data) {
    // A frame with a payload set always serialises to at least a key byte and a
    // length byte, so this is unreachable in practice; it is here so that a
    // future change fails as a typed error instead of a trap.
    guard wire.count >= 2 else {
      throw FrameCodecError.noEnvelope(
        direction: direction,
        detail: "a frame with a payload set serialises to at least two bytes, got \(wire.count)"
      )
    }
    return try wire.withUnsafeBytes { raw -> (UInt8, Data) in
      let (key, keyWidth) = try readVarint(direction: direction, bytes: raw, from: 0)
      guard key & 0x07 == 0x02 else {
        throw FrameCodecError.noEnvelope(
          direction: direction,
          detail: "frame serialised with wire type \(key & 0x07), expected length-delimited"
        )
      }
      let fieldNumber = key >> 3
      guard fieldNumber >= 1, fieldNumber <= UInt64(UInt8.max) else {
        throw FrameCodecError.noEnvelope(
          direction: direction,
          detail: "payload field number \(fieldNumber) does not fit the one-byte envelope tag"
        )
      }
      let (length, lengthWidth) = try readVarint(direction: direction, bytes: raw, from: keyWidth)
      let bodyStart = keyWidth + lengthWidth
      // The bytes are the generated encoder's own, so this holds; checked
      // anyway because the alternative is a trap on a hostile conversion.
      guard length <= UInt64(raw.count - bodyStart) else {
        throw FrameCodecError.noEnvelope(
          direction: direction,
          detail: "serialised payload length \(length) exceeds the \(raw.count - bodyStart) bytes present"
        )
      }
      return (UInt8(fieldNumber), Data(raw[bodyStart..<(bodyStart + Int(length))]))
    }
  }

  private static func encodeFrame<M: SwiftProtobuf.Message>(
    _ frame: M,
    direction: FrameDirection,
    isPayloadless: (M) -> Bool
  ) throws -> Data {
    guard !isPayloadless(frame) else {
      throw FrameCodecError.noPayloadSet(direction: direction)
    }
    let wire: Data = try frame.serializedData()
    let envelope = try splitEnvelope(direction: direction, wire)
    return try writeEnvelope(direction: direction, tag: envelope.tag, payload: envelope.payload)
  }

  private static func decodeFrame<M: SwiftProtobuf.Message>(
    _ data: Data,
    direction: FrameDirection
  ) throws -> (frame: M, tag: UInt8) {
    let envelope = try readEnvelope(direction, data)
    let body = try protobufBody(direction: direction, envelope: envelope, of: data)
    let frame: M
    do {
      frame = try M(serializedBytes: body)
    } catch {
      throw FrameCodecError.malformedPayload(
        direction: direction, tag: envelope.tag, detail: "\(error)")
    }
    // A tag this build does not know is *not* a decoding failure: protobuf keeps
    // an unrecognised field number as an unknown field, so the frame comes back
    // with nothing in its `oneof payload`. That is how an unknown tag is told
    // apart from a payload whose bytes did not parse, and it is why the caller
    // checks `payload != nil` rather than this function throwing.
    return (frame, envelope.tag)
  }

  private static func writeEnvelope(
    direction: FrameDirection,
    tag: UInt8,
    payload: Data
  ) throws -> Data {
    // Refuse to build a frame the relay would reject. It caps the payload on the
    // way in and on the way out, so a frame above either bound fails here, at
    // the call site, instead of turning into a dropped connection.
    guard payload.count <= maxFramePayloadBytes else {
      throw FrameCodecError.payloadTooLarge(
        direction: direction, declaredLength: UInt64(payload.count))
    }
    var frame = Data()
    frame.reserveCapacity(1 + canonicalLengthVarintMaxBytes + payload.count)
    frame.append(tag)
    // Always canonical, which is why the widest frame we produce is
    // maxFrameEmittedBytes and not maxFrameTotalBytes.
    appendCanonicalVarint(UInt64(payload.count), to: &frame)
    frame.append(payload)
    // The envelope adds bytes on top of the payload, so it has its own bound.
    // Unreachable while the payload cap holds; checked so the invariant is
    // enforced rather than assumed.
    guard frame.count <= maxFrameTotalBytes else {
      throw FrameCodecError.frameTooLarge(direction: direction, length: frame.count)
    }
    return frame
  }

  // MARK: - Varints

  /// Read an unsigned varint starting at `from`, which is an offset into
  /// `bytes`.
  ///
  /// The length prefix is a full 64-bit field on the wire — the relay reads it
  /// as a uint64 — so it is read losslessly and checked against the payload
  /// bound *before* it is narrowed. Two shapes are rejected on the bytes
  /// themselves, because a reader that merely accumulates would silently accept
  /// both: an unterminated prefix, and a tenth byte carrying more than the one
  /// bit still free at shift 63. The relay rejects the same two
  /// (`internal/ws/codec.go:360`).
  private static func readVarint(
    direction: FrameDirection,
    bytes: UnsafeRawBufferPointer,
    from offset: Int
  ) throws -> (value: UInt64, width: Int) {
    var value: UInt64 = 0
    for index in 0..<lengthVarintMaxBytes64 {
      guard offset + index < bytes.count else {
        throw FrameCodecError.lengthVarint(
          direction: direction, detail: "unterminated length varint after \(index) bytes")
      }
      let byte = bytes[offset + index]
      if index == lengthVarintMaxBytes64 - 1 && byte > 0x01 {
        throw FrameCodecError.lengthVarint(
          direction: direction, detail: "length varint overflows 64 bits")
      }
      // index <= 9, so the shift is at most 63: a tenth byte contributes its
      // low bit only, and the check above has already refused everything else.
      value |= UInt64(byte & 0x7F) << (7 * UInt64(index))
      if byte & 0x80 == 0 {
        return (value, index + 1)
      }
    }
    // Eleven bytes: the eleventh continuation byte means the value cannot be
    // finished inside 64 bits.
    throw FrameCodecError.lengthVarint(
      direction: direction, detail: "length varint overflows 64 bits")
  }

  /// Bytes an unsigned varint of `value` occupies on the wire.
  static func varintWidth(_ value: UInt64) -> Int {
    var width = 1
    var rest = value >> 7
    while rest != 0 {
      width += 1
      rest >>= 7
    }
    return width
  }

  /// Bytes a protobuf *key* for `value` occupies: same rule as any varint.
  static func keyWidth(for key: UInt32) -> Int {
    var width = 1
    var rest = key >> 7
    while rest != 0 {
      width += 1
      rest >>= 7
    }
    return width
  }

  /// Append `value` as a minimal, canonical varint. We never emit a
  /// non-canonical prefix: the relay accepts one, but emitting it would mean
  /// every frame this SDK writes is up to seven bytes wider than it needs to be.
  private static func appendCanonicalVarint(_ value: UInt64, to data: inout Data) {
    var rest = value
    while rest >= 0x80 {
      data.append(UInt8(rest & 0x7F) | 0x80)
      rest >>= 7
    }
    data.append(UInt8(rest))
  }
}