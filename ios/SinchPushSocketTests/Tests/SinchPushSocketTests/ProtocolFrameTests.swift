//  ProtocolFrameTests.swift — the inbound frames the client must survive
//  (SB-16, SB-38, SB-39).
//
//  Three frame types that are not about delivery, and three different ways to get
//  them wrong:
//
//  * `Ping` must be answered, on this connection, without touching the poll
//    timer or the backoff budget (SB-38). A client that answers a Ping by
//    reconnecting turns a keepalive into an outage.
//  * `AuthChallenge` is reserved for a future token refresh: keep the connection
//    (SB-39). The snapshot breaks out of its switch silently; the Kotlin client
//    has no branch for it at all and logs "unknown frame tag 1".
//  * A frame this build cannot read is *recoverable* (SB-16), and the two
//    reasons have to stay distinguishable in the log: "the peer is ahead" is a
//    version problem, "the bytes are wrong" is a network problem, and a policy
//    that cannot tell them apart cannot be written.
//
//  The bad frames are hand-built envelopes (see WireTestSupport), not
//  re-encodings, so the client is being asked to survive bytes the codec's own
//  writer would never produce.

import XCTest

@testable import SinchPushSocket

final class ProtocolFrameTests: XCTestCase {

  private func harness() -> SocketHarness {
    makeHarness(configuration: testConfiguration(displayNotifications: .never))
  }

  // MARK: - SB-38 Ping

  func test_SB38_aPingIsAnsweredWithAPongThatEchoesTheCorrelationId() {
    let harness = self.harness()
    harness.handshake()

    var ping = Sinch_Push_Delivery_V1beta1_Ws_Ping()
    ping.correlationID = "corr-7"
    harness.transport.deliver(ServerFrame(ping))

    XCTAssertEqual(harness.pongs.count, 1)
    // Verbatim: a mismatched correlation is a ping we cannot correlate.
    XCTAssertEqual(harness.pongs.first?.correlationID, "corr-7")
  }

  func test_SB38_aPingDoesNotDisturbThePollTimerOrTheBudget() {
    let harness = self.harness()
    harness.handshake()
    let pollsBefore = harness.polls.count
    let timersBefore = harness.pendingTimers

    var ping = Sinch_Push_Delivery_V1beta1_Ws_Ping()
    ping.correlationID = "corr-1"
    harness.transport.deliver(ServerFrame(ping))

    XCTAssertEqual(harness.polls.count, pollsBefore)
    XCTAssertEqual(harness.pendingTimers, timersBefore)
    XCTAssertEqual(harness.client.backoffState.attempts, 0)

    // And the poll timer still fires on its own schedule afterwards.
    harness.scheduler.advance(by: 5_000)
    XCTAssertEqual(harness.polls.count, pollsBefore + 1)
  }

  func test_SB38_aPingWithNoCorrelationIdIsStillAnswered() {
    let harness = self.harness()
    harness.handshake()

    harness.transport.deliver(ServerFrame(Sinch_Push_Delivery_V1beta1_Ws_Ping()))

    XCTAssertEqual(harness.pongs.count, 1)
    XCTAssertEqual(harness.pongs.first?.correlationID, "")
  }

  // MARK: - SB-39 AuthChallenge

  func test_SB39_anAuthChallengeKeepsTheConnectionAndIsLogged() {
    let harness = self.harness()
    harness.handshake()

    var challenge = Sinch_Push_Delivery_V1beta1_Ws_AuthChallenge()
    challenge.nonce = "nonce-1"
    harness.transport.deliver(ServerFrame(challenge))

    // Not a reason to close and not a reason to reconnect: it is reserved.
    XCTAssertEqual(harness.recorder.current?.status, .connected)
    XCTAssertEqual(harness.socketCount, 1)
    XCTAssertTrue(harness.logger.contains("auth challenge"))
    // The Kotlin client has no branch for this frame and logs "unknown frame
    // tag 1" — the one frame in that set that is known and reserved.
    XCTAssertFalse(harness.logger.contains("unknown frame tag"))
  }

  func test_SB39_anUnexpectedPongIsIgnoredWithoutAReply() {
    let harness = self.harness()
    harness.handshake()
    let frames = harness.sentFrames.count

    // The relay only sends a Pong for a Ping it did not get an answer to; there
    // is nothing to say back to a Pong.
    var pong = Sinch_Push_Delivery_V1beta1_Ws_Pong()
    pong.correlationID = "corr-stray"
    harness.transport.deliver(ServerFrame(pong))

    XCTAssertEqual(harness.sentFrames.count, frames)
    XCTAssertEqual(harness.recorder.current?.status, .connected)
  }

  // MARK: - SB-16 non-fatal frame errors

  func test_SB16_anUnknownTagIsLoggedAndIgnored() {
    let harness = self.harness()
    harness.handshake()

    // Tag 200 is a valid one-byte envelope tag that names no payload in this
    // build — the peer is a version ahead of us.
    harness.transport.deliverRaw(envelope(tag: 200, payload: [0x01, 0x02]))

    XCTAssertTrue(harness.logger.contains("unknown frame tag 200"))
    XCTAssertEqual(harness.recorder.current?.status, .connected)
    XCTAssertEqual(harness.socketCount, 1)
  }

  func test_SB16_aMalformedEnvelopeIsLoggedSeparatelyAndSurvives() {
    let harness = self.harness()
    harness.handshake()

    // One byte: too short to hold even a tag and a length.
    harness.transport.deliverRaw([0x01])
    // A declared length the body does not have.
    harness.transport.deliverRaw(frameDeclaring(tag: 2, declared: 64, bodyBytes: 3))

    XCTAssertTrue(harness.logger.contains("malformed server frame"))
    XCTAssertFalse(
      harness.logger.contains("unknown frame tag"),
      "a malformed envelope was logged as an unknown tag")
    XCTAssertEqual(harness.recorder.current?.status, .connected)
    XCTAssertEqual(harness.socketCount, 1)
  }

  func test_SB16_theTwoFrameFailuresAreDistinguishableLines() {
    let harness = self.harness()
    harness.handshake()

    harness.transport.deliverRaw(envelope(tag: 200, payload: []))
    harness.transport.deliverRaw([0x01])

    let unknown = harness.logger.lines.filter { $0.contains("unknown frame tag 200") }
    let malformed = harness.logger.lines.filter { $0.contains("malformed server frame") }
    XCTAssertEqual(unknown.count, 1)
    XCTAssertEqual(malformed.count, 1)
    XCTAssertNotEqual(unknown.first, malformed.first)
  }

  func test_SB16_aBadFrameDoesNotStopTheClientFromCarryingOn() {
    let harness = self.harness()
    harness.handshake()

    harness.transport.deliverRaw(envelope(tag: 200, payload: []))
    harness.deliverMessage(pooledMessage(messageID: "msg-after-garbage"))

    // The frame that follows a bad one is still processed, which is the whole
    // point of "recoverable at the frame level".
    XCTAssertEqual(harness.deliveredMessageIDs, ["msg-after-garbage"])
    XCTAssertEqual(harness.reports(.delivered).count, 1)
  }
}