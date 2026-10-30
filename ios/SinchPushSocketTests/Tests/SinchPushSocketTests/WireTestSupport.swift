//  WireTestSupport.swift — byte-level helpers for the frame codec tests.
//
//  These build envelopes by hand rather than through the encoder, so a test can
//  assert what the decoder does with bytes the encoder would never produce: a
//  length prefix of a chosen width, a declared length that does not match the
//  body, a prefix that overflows 64 bits. The TypeScript original is
//  `__tests__/utils/wire.ts` at tag ts-socket-client-snapshot.
//
//  Note there is deliberately no helper here that encodes a frame: every
//  hand-built envelope is written out byte by byte, so a test that "checks the
//  decoder" is checking it against the wire format and not against our own
//  writer.

import Foundation

@testable import SinchPushSocket

// MARK: - Hex

func bytes(hex: String) -> [UInt8] {
  let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
  precondition(clean.count % 2 == 0, "odd-length hex: \(clean)")
  var out: [UInt8] = []
  out.reserveCapacity(clean.count / 2)
  var index = clean.startIndex
  while index < clean.endIndex {
    let next = clean.index(index, offsetBy: 2)
    guard let byte = UInt8(clean[index..<next], radix: 16) else {
      fatalError("not hex: \(clean[index..<next])")
    }
    out.append(byte)
    index = next
  }
  return out
}

func hex(_ data: Data) -> String {
  data.map { String(format: "%02x", $0) }.joined()
}

func hex(_ values: [UInt8]) -> String {
  hex(Data(values))
}

func data(_ values: [UInt8]) -> Data {
  Data(values)
}

extension Data {
  /// The frame as `[UInt8]`, for readable assertions.
  var bytes: [UInt8] { [UInt8](self) }
}

// MARK: - Varints

/// Bytes an unsigned varint of `value` occupies on the wire.
func varintSize(_ value: UInt64) -> Int {
  var size = 1
  var rest = value >> 7
  while rest != 0 {
    size += 1
    rest >>= 7
  }
  return size
}

/// An unsigned varint of `value`, as bytes.
func varintBytes(_ value: UInt64) -> [UInt8] {
  var out: [UInt8] = []
  var rest = value
  while rest >= 0x80 {
    out.append(UInt8(rest & 0x7F) | 0x80)
    rest >>= 7
  }
  out.append(UInt8(rest))
  return out
}

/// The same value as ``varintBytes(_:)``, extended to exactly `width` bytes
/// without changing what it decodes to.
///
/// A varint decoder stops at the first byte with the high bit clear, so the
/// obvious padding — leading `0x80` continuation bytes — shifts the value by
/// `128^k` for every group added. `[80 80 04]` (65536) padded to ten bytes as
/// `[80 x7 80 80 04]` decodes to 65536·128⁷. That is a trap: it looks like
/// padding and silently encodes a different number.
///
/// The construction that does work is to keep every significant group exactly
/// where it is and extend past it. Set the canonical terminal byte's high bit so
/// it becomes a continuation carrying the same data bits, then append zero groups
/// terminated by `00`:
///
///     65536 canonical   80 80 04
///     extended to 10    80 80 84 80 80 80 80 80 80 00   -> decodes 65536
///
/// Nothing moves: `04` still supplies the 4 at group 2, and every group above it
/// is zero. This is the form protobuf permits and the relay accepts, so it is
/// the shape a noncanonical peer can actually send.
func extendedVarint(_ value: UInt64, width: Int) -> [UInt8] {
  var groups = varintBytes(value)
  precondition(
    width >= groups.count, "cannot extend a \(groups.count)-byte varint to \(width) bytes")
  if width == groups.count { return groups }
  groups[groups.count - 1] |= 0x80  // terminal becomes a continuation
  return groups + [UInt8](repeating: 0x80, count: width - groups.count - 1) + [0x00]
}

// MARK: - Envelopes

/// Concatenate byte-ish values into one `[UInt8]`.
func bytesOf(_ parts: [UInt8]...) -> [UInt8] {
  parts.reduce(into: []) { $0 += $1 }
}

/// `[tag][varint(payload.length)][payload]`, written out by hand.
func envelope(tag: UInt8, payload: [UInt8]) -> [UInt8] {
  bytesOf([tag], varintBytes(UInt64(payload.count)), payload)
}

/// `[tag][prefix as given][body]`, for prefixes ``varintBytes(_:)`` cannot produce.
func envelopeWithPrefix(tag: UInt8, prefix: [UInt8], body: [UInt8] = []) -> [UInt8] {
  bytesOf([tag], prefix, body)
}

/// `[tag][varint(declared)][filler]`, where the body is deliberately too short.
func frameDeclaring(tag: UInt8, declared: UInt64, bodyBytes: Int) -> [UInt8] {
  bytesOf([tag], varintBytes(declared), [UInt8](repeating: 0x41, count: bodyBytes))
}

// MARK: - Payloads

/// A `Pong` message whose serialised form is exactly `size` bytes.
///
/// `Pong` is one length-delimited string field, so the whole payload can be
/// written out by hand and a test can ask for a size exactly rather than
/// approximately: field 1, wire type 2 -> `0x0a`, the string length as a
/// varint, then that many bytes.
func pongMessageOfSize(_ size: Int) -> Sinch_Push_Delivery_V1beta1_Ws_Pong {
  for length in stride(from: size, through: 0, by: -1) {
    let candidate = String(repeating: "C", count: length)
    let message = pongMessage(correlationID: candidate)
    if (try? message.serializedData().count) == size { return message }
  }
  fatalError("no Pong payload serialises to exactly \(size) bytes")
}

/// A `Pong` payload of exactly `size` bytes.
func pongPayloadOfSize(_ size: Int) -> Data {
  try! pongMessageOfSize(size).serializedData()
}

/// A client `Pong` frame, for the encode/decode round trips.
func pongClientFrameOfSize(_ size: Int) -> Sinch_Push_Delivery_V1beta1_Ws_ClientFrame {
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ClientFrame()
  frame.payload = .pong(pongMessageOfSize(size))
  return frame
}

/// A server `Pong` frame, for the encode/decode round trips.
func pongServerFrameOfSize(_ size: Int) -> Sinch_Push_Delivery_V1beta1_Ws_ServerFrame {
  var frame = Sinch_Push_Delivery_V1beta1_Ws_ServerFrame()
  frame.payload = .pong(pongMessageOfSize(size))
  return frame
}

func pongMessage(correlationID: String) -> Sinch_Push_Delivery_V1beta1_Ws_Pong {
  var pong = Sinch_Push_Delivery_V1beta1_Ws_Pong()
  pong.correlationID = correlationID
  return pong
}