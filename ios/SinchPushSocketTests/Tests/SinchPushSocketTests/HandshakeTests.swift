//  HandshakeTests.swift — the first two frames and the state surface
//  (SB-18 … SB-24).
//
//  Everything here is about what the client does *around* the handshake: the
//  `Hello` field set, the values SB-19 fixes, the transitions SB-20 publishes,
//  the five steps SB-21 orders, the poll interval SB-22 floors, the immediate
//  poll SB-23 requires, and the state object SB-24 defines.
//
//  The relay is a fake, but the assertions are about the bytes: the frames are
//  decoded back out of the transport and read as proto messages, so a `Hello`
//  with the right values in the wrong fields fails here.

import XCTest

@testable import SinchPushSocket

final class HandshakeTests: XCTestCase {

  // MARK: - SB-18 Hello field set

  func test_SB18_helloIsTheFirstFrameOnAnOpenSocket() {
    let harness = makeHarness()

    // Nothing is sent before the socket opens: the relay would reject a frame
    // ahead of the upgrade, and the client has no session to speak of yet.
    XCTAssertTrue(harness.sentFrames.isEmpty)

    harness.transport.openSocket()

    XCTAssertEqual(harness.transport.sentKinds, ["hello"])
  }

  func test_SB18_helloCarriesTheIdentityTheRelayValidates() throws {
    let harness = makeHarness()

    harness.transport.openSocket()

    let hello = try XCTUnwrap(harness.hello)
    // The relay refuses a Hello with any of these empty, or with an
    // UNSPECIFIED platform, so they are the load-bearing assertions.
    XCTAssertEqual(hello.authToken, "jwt.token.value")
    XCTAssertEqual(hello.projectID, "project-1")
    XCTAssertEqual(hello.appID, "app-1")
    XCTAssertEqual(hello.userID, "user-1")
    XCTAssertNotEqual(hello.platform, Sinch_Push_Delivery_V1beta1_Ws_Platform.unspecified)
  }

  func test_SB18_aFreshCredentialReachesTheWireOnTheNextHello() {
    let harness = makeHarness()
    harness.handshake()

    // A new JWT is a fresh `Hello`, not a restart.
    harness.client.updateConfiguration(
      testConfiguration(authToken: "rotated.token.value"))
    XCTAssertEqual(harness.socketCount, 2)

    harness.transport.openSocket()
    XCTAssertEqual(harness.transport.sentKinds, ["hello"])
    XCTAssertEqual(harness.hello?.authToken, "rotated.token.value")
  }

  // MARK: - SB-19 platform and sdk_version

  func test_SB19_platformIsIOSAndNotDerivedFromBackground() throws {
    let harness = makeHarness()
    harness.transport.openSocket()

    let hello = try XCTUnwrap(harness.hello)
    XCTAssertEqual(hello.platform, Sinch_Push_Delivery_V1beta1_Ws_Platform.ios)
    // The snapshot derived one from the other (`platformCode()`); asserting the
    // pair together is what pins that they are independent fields now.
    XCTAssertFalse(hello.background)
  }

  func test_SB19_sdkVersionIsTheStringTheConfigCarries() {
    let harness = makeHarness(
      configuration: testConfiguration(sdkVersion: "rn-sinch-push/9.9.9"))

    harness.transport.openSocket()

    XCTAssertEqual(harness.hello?.sdkVersion, "rn-sinch-push/9.9.9")
  }

  func test_SB19_fallbackSDKVersionIsPinnedToPackageJSON() {
    // The Kotlin client hard-codes "rn-sinch-push/1.1.0" in three places and
    // nothing fails when the published version moves (spec §8, SB-19). The Swift
    // fallback is the *same* string — so it has to be the same on both sides,
    // and this is the test that makes drift a failure rather than a surprise.
    let version = packageVersion()
    XCTAssertEqual(
      SocketConfiguration.defaultSDKVersion,
      "rn-sinch-push/\(version)",
      "SocketConfiguration.defaultSDKVersion has drifted from package.json; "
        + "it must be updated in lockstep (and on the Kotlin side too)")
  }

  func test_SB19_emptyConfiguredVersionFallsBackRatherThanSendingNothing() {
    // `sdk_version` is free-form, so an empty string is not refused by the relay
    // the way an empty token is — but sending nothing loses the version from
    // every relay-side report, so the fallback is used instead.
    let harness = makeHarness(configuration: testConfiguration(sdkVersion: ""))

    harness.transport.openSocket()

    XCTAssertEqual(harness.hello?.sdkVersion, SocketConfiguration.defaultSDKVersion)
  }

  // MARK: - SB-59 / SB-60 device info

  func test_SB18_helloCarriesAllTwelveFieldsOfTheRelayContract() throws {
    let harness = makeHarness(
      store: FakeSocketStateStore(lastSeen: "msg-9"),
      deviceInfo: testDeviceInfo(
        installationId: "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11",
        osVersion: "17.5.1", bundleId: "com.example.host"))
    harness.transport.openSocket()

    let hello = try XCTUnwrap(harness.hello)
    XCTAssertEqual(hello.authToken, "jwt.token.value")
    XCTAssertEqual(hello.projectID, "project-1")
    XCTAssertEqual(hello.appID, "app-1")
    XCTAssertEqual(hello.userID, "user-1")
    XCTAssertEqual(hello.platform, .ios)
    // SB-57: `background` is false on the iOS path.
    XCTAssertFalse(hello.background)
    XCTAssertEqual(hello.lastSeenMessageID, "msg-9")
    XCTAssertEqual(hello.sdkVersion, SocketConfiguration.defaultSDKVersion)
    XCTAssertEqual(hello.installationID, "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11")
    XCTAssertEqual(hello.osVersion, "17.5.1")
    XCTAssertEqual(hello.bundleID, "com.example.host")
    XCTAssertEqual(hello.backgroundService, .unsupported)
  }

  func test_SB60_iosBackgroundServiceIsUnsupportedWhateverTheConfigurationSays() throws {
    // There is no configuration input for it: SocketConfiguration has no such
    // field, so the only way to move it off UNSUPPORTED is a code change. Pin
    // the value on every Hello of a reconnecting session, not just the first.
    let harness = makeHarness()
    harness.handshake()
    harness.serverClose(reason: .shutdown)
    harness.scheduler.advance(by: 60_000)
    harness.transport.openSocket()

    XCTAssertEqual(harness.hello?.backgroundService, .unsupported)
  }

  func test_SB59_anUnavailableInstallationIdSendsAnEmptyIdAndKeepsTheConnection() throws {
    struct Locked: Error {}
    let logger = RecordingLogger()
    let provider = SystemDeviceInfoProvider(
      installationId: { throw Locked() }, osVersion: { "17.5" },
      bundleId: { "com.example.host" }, logger: logger)
    let harness = makeHarness(deviceInfo: provider)

    harness.transport.openSocket()

    let hello = try XCTUnwrap(harness.hello, "the Hello must still be sent")
    XCTAssertEqual(hello.installationID, "")
    XCTAssertEqual(hello.osVersion, "17.5", "the rest of the device info is unaffected")
    XCTAssertEqual(hello.bundleID, "com.example.host")
    XCTAssertTrue(logger.contains("installation id unavailable"))
    XCTAssertFalse(harness.published(.error), "an unavailable id must not fail the connection")
  }

  func test_SB59_anInstallationIdThatWasUnavailableIsRetriedOnTheNextHello() throws {
    struct Locked: Error {}
    final class Flaky {
      var locked = true
      func read() throws -> String {
        if locked { throw Locked() }
        return "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11"
      }
    }
    let flaky = Flaky()
    let provider = SystemDeviceInfoProvider(
      installationId: { try flaky.read() }, osVersion: { "17.5" }, bundleId: { "b" })
    let harness = makeHarness(deviceInfo: provider)
    harness.transport.openSocket()
    XCTAssertEqual(harness.hello?.installationID, "")

    flaky.locked = false
    harness.serverClose(reason: .shutdown)
    harness.scheduler.advance(by: 60_000)
    harness.transport.openSocket()

    XCTAssertEqual(harness.hello?.installationID, "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11")
  }

  func test_SB59_theInstallationIdIsTheOneTheInstallationIdStoreHandsOut() throws {
    let store = KeychainInstallationIdStore(backing: InMemoryInstallationIdBacking())
    let provider = SystemDeviceInfoProvider(
      installationId: { try store.installationId() }, osVersion: { "17.5" }, bundleId: { "b" })
    let harness = makeHarness(deviceInfo: provider)

    harness.transport.openSocket()

    XCTAssertEqual(harness.hello?.installationID, try store.installationId())
    XCTAssertFalse(try XCTUnwrap(harness.hello?.installationID).isEmpty)
  }

  func test_SB59_osVersionIsMajorMinorAndPatchOnlyWhenNonZero() {
    func format(_ major: Int, _ minor: Int, _ patch: Int) -> String {
      SystemDeviceInfoProvider.formatOSVersion(
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch))
    }
    XCTAssertEqual(format(17, 5, 0), "17.5")
    XCTAssertEqual(format(17, 5, 1), "17.5.1")
    XCTAssertEqual(format(14, 0, 0), "14.0")
    XCTAssertEqual(format(26, 0, 3), "26.0.3")
  }

  func test_SB59_theLiveOsVersionIsNeverEmpty() {
    // ProcessInfo formatted by the SB-59 rule on every platform; a Hello must
    // not go out with the field blank.
    XCTAssertFalse(SystemDeviceInfoProvider.systemOSVersion().isEmpty)
  }

  func test_SB59_sdkVersionHasOneSourceAndTheConfigOverrideWins() {
    let provider = StaticDeviceInfoProvider()
    XCTAssertEqual(
      provider.current(sdkVersionOverride: nil).sdkVersion, SocketConfiguration.defaultSDKVersion)
    XCTAssertEqual(
      provider.current(sdkVersionOverride: "").sdkVersion, SocketConfiguration.defaultSDKVersion)
    XCTAssertEqual(
      provider.current(sdkVersionOverride: "rn-sinch-push/9.9.9").sdkVersion,
      "rn-sinch-push/9.9.9")
    let system = SystemDeviceInfoProvider(installationId: { "x" })
    XCTAssertEqual(
      system.current(sdkVersionOverride: nil).sdkVersion, SocketConfiguration.defaultSDKVersion)
  }

  // MARK: - SB-20 transitions

  func test_SB20_firstAttemptPublishesConnectingAndLaterAttemptsReconnecting() {
    let harness = makeHarness()

    XCTAssertEqual(harness.recorder.statuses, [.connecting])

    harness.handshake()
    harness.transport.failTransport(code: 1006)
    XCTAssertEqual(harness.recorder.current?.status, .reconnecting)

    // The reconnect is itself an attempt, and it is not the first one.
    harness.scheduler.advance(by: 500)
    XCTAssertEqual(
      harness.recorder.statuses,
      [.connecting, .connected, .reconnecting, .reconnecting])
  }

  func test_SB20_aNewAttemptClearsTheErrorLeftByTheLastOne() {
    let harness = makeHarness()
    harness.transport.failTransport(code: 1006)
    XCTAssertEqual(harness.recorder.current?.lastError, "socket closed (code=1006)")

    harness.scheduler.advance(by: 500)

    // SB-24 says the same thing about the published surface: a failure's error
    // must not survive into the fresh attempt that is about to succeed.
    XCTAssertNil(harness.recorder.current?.lastError)
  }

  // MARK: - SB-21 HelloAck handling

  func test_SB21_helloAckPublishesConnectedWithTheConnectionId() {
    let harness = makeHarness()

    harness.handshake(connectionID: "conn-7")

    XCTAssertEqual(harness.recorder.current?.status, .connected)
    XCTAssertEqual(harness.recorder.current?.connectionId, "conn-7")
  }

  func test_SB21_helloAckDrainsPooledMessagesWithAnEmptyAckToken() throws {
    let harness = makeHarness(configuration: testConfiguration(displayNotifications: .never))

    // `HelloAck` carries bare pooled messages, with no `Message` wrapper and so
    // no per-message ack token: SB-21.3 says the emitted event's token is empty.
    // The whole pool is drained, in order, in the handshake itself.
    let pooled = [pooledMessage(messageID: "msg-a"), pooledMessage(messageID: "msg-b")]
    harness.handshake(messages: pooled)

    XCTAssertEqual(harness.deliveredMessageIDs, ["msg-a", "msg-b"])
    for id in ["msg-a", "msg-b"] {
      let pending = try XCTUnwrap(harness.client.currentPendingMessages.first { $0.id == id })
      XCTAssertEqual(pending.ackToken, "")
    }
    // SB-29: the newest one is what the *next* Hello reports.
    XCTAssertEqual(harness.store.lastSeen, "msg-b")
  }

  func test_SB22_configWinsOverTheServerValue() {
    let harness = makeHarness(
      configuration: testConfiguration(pollIntervalMs: 2000))

    harness.handshake(pollIntervalMs: 30000)

    XCTAssertEqual(harness.recorder.current?.pollIntervalMs, 2000)
  }

  func test_SB22_serverValueIsUsedWhenConfigIsAbsent() {
    let harness = makeHarness(configuration: testConfiguration(pollIntervalMs: 0))

    harness.handshake(pollIntervalMs: 15000)

    XCTAssertEqual(harness.recorder.current?.pollIntervalMs, 15000)
  }

  func test_SB22_defaultIsUsedWhenNeitherConfigNorServerHasOne() {
    let harness = makeHarness(configuration: testConfiguration(pollIntervalMs: 0))

    harness.handshake(pollIntervalMs: 0)

    XCTAssertEqual(harness.recorder.current?.pollIntervalMs, SocketClient.defaultPollIntervalMs)
    XCTAssertEqual(harness.recorder.current?.pollIntervalMs, 5000)
  }

  func test_SB22_aSubSecondServerValueIsFlooredInStateAndInTheTimer() {
    // The Kotlin client floors the value at the timer and publishes the raw one,
    // so state reports 50 while the client polls at 1000 (spec §8, SB-22).
    let harness = makeHarness()

    harness.handshake(pollIntervalMs: 50)

    XCTAssertEqual(harness.recorder.current?.pollIntervalMs, 1000)
    // ...and the floored value is what the timer uses, so no poll at 50 ms.
    harness.scheduler.advance(by: 999)
    XCTAssertEqual(harness.polls.count, 1, "the immediate poll only")
    harness.scheduler.advance(by: 1)
    XCTAssertEqual(harness.polls.count, 2)
  }

  // MARK: - SB-23 immediate poll

  func test_SB23_aPollIsSentImmediatelyAfterEveryHelloAck() {
    let harness = makeHarness()

    harness.handshake()

    // Before any timer has run: hello, poll. The snapshot armed an interval and
    // waited a full period for its first poll (OPEN-1).
    XCTAssertEqual(harness.transport.sentKinds, ["hello", "poll"])
  }

  func test_SB23_theImmediatePollArrivesOnEveryReconnectToo() {
    let harness = makeHarness()
    harness.handshake()

    harness.transport.failTransport(code: 1006)
    harness.scheduler.advance(by: 500)
    harness.handshake(connectionID: "conn-2")

    XCTAssertEqual(harness.transport.sentKinds, ["hello", "poll"])
  }

  // MARK: - SB-24 state surface

  func test_SB24_stateCarriesEveryRequiredField() throws {
    let harness = makeHarness()

    harness.handshake(connectionID: "conn-3")

    let dictionary = try XCTUnwrap(harness.recorder.current).dictionary
    for key in ["status", "transport", "connectionId", "pollIntervalMs", "reconnectAttempts"] {
      XCTAssertNotNil(dictionary[key], "state is missing \(key)")
    }
    XCTAssertEqual(dictionary["status"] as? String, "connected")
    XCTAssertEqual(dictionary["transport"] as? String, "native")
    XCTAssertEqual(dictionary["connectionId"] as? String, "conn-3")
    // `lastError` is absent rather than nil-valued when there is no error.
    XCTAssertNil(dictionary["lastError"])
  }

  func test_SB24_lastErrorCarriesACloseDetailsText() {
    let harness = makeHarness()
    harness.handshake()

    harness.serverClose(reason: .poolFull, detail: "rate_limited")

    XCTAssertEqual(harness.recorder.current?.lastError, "rate_limited")
  }

  func test_SB24_aCloseWithoutDetailStillCarriesAReason() {
    let harness = makeHarness()
    harness.handshake()

    harness.serverClose(reason: .shutdown)

    // SB-24's fallback form. The raw enum name would be a leak of the protocol
    // into the JS surface, so the number goes out instead.
    XCTAssertEqual(
      harness.recorder.current?.lastError,
      "server closed (reason=\(Sinch_Push_Delivery_V1beta1_Ws_CloseReason.shutdown.rawValue))")
  }

  func test_SB24_connectionIdIsEmptyBeforeTheFirstHandshake() {
    let harness = makeHarness()

    XCTAssertEqual(harness.recorder.current?.connectionId, "")
    XCTAssertEqual(harness.client.currentState.connectionId, "")
  }
}