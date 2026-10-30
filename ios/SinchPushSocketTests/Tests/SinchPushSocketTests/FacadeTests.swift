//  FacadeTests.swift — the @objc surface `SinchPush.mm` calls into, and the two
//  promises that surface makes (SB-18, SB-19, SB-24, SB-30).
//
//  The facade is deliberately thin: it decodes the `PushSocketConfig` map JS
//  sends, forwards lifecycle signals, and translates five method calls into the
//  state machine below it. What is worth testing is therefore the *edges* —
//  which is also the only part the socket suites cannot reach, because they
//  construct a `SocketClient` directly.
//
//  The one test that calls `start(config:)` does open a real
//  `URLSessionWebSocketTask`, against `ws://127.0.0.1:1/ws`, which refuses the
//  connection immediately on a loopback. That is deliberate: the point is that
//  the config reaches the token store and *not* the state store, and there is no
//  way to observe that without the real start path.

import XCTest

@testable import SinchPushSocket

final class FacadeTests: XCTestCase {

  private let configMap: NSDictionary = [
    "url": "ws://127.0.0.1:8080/ws",
    "authToken": "jwt.token.value",
    "projectId": "project-1",
    "appId": "app-1",
    "userId": "user-1",
    "pollIntervalMs": 2500,
    "sdkVersion": "rn-sinch-push/1.1.0",
    "displayNotifications": "always",
  ]

  // MARK: - SB-18 the config map

  func test_SB18_theConfigMapBecomesTheConnectionConfiguration() throws {
    let configuration = try XCTUnwrap(SocketConfiguration(configMap: configMap))

    XCTAssertEqual(configuration.url, "ws://127.0.0.1:8080/ws")
    XCTAssertEqual(configuration.authToken, "jwt.token.value")
    XCTAssertEqual(configuration.projectID, "project-1")
    XCTAssertEqual(configuration.appID, "app-1")
    XCTAssertEqual(configuration.userID, "user-1")
    XCTAssertEqual(configuration.pollIntervalMs, 2500)
  }

  func test_SB18_aConfigMapWithoutTheRequiredFieldsIsRefused() {
    // JS validates first and rejects the promise with a better message than a
    // native `nil` would; these are the fields the relay itself refuses.
    XCTAssertNil(SocketConfiguration(configMap: [
      "authToken": "t", "appId": "a", "userId": "u",
    ]))
    XCTAssertNil(SocketConfiguration(configMap: [
      "url": "ws://x/ws", "appId": "a", "userId": "u",
    ]))
    XCTAssertNil(SocketConfiguration(configMap: [
      "url": "ws://x/ws", "authToken": "t", "userId": "u",
    ]))
    XCTAssertNil(SocketConfiguration(configMap: [
      "url": "ws://x/ws", "authToken": "t", "appId": "a",
    ]))
  }

  func test_SB19_theConfigMapCarriesTheSdkVersionAndDisplayRule() throws {
    let configuration = try XCTUnwrap(SocketConfiguration(configMap: configMap))

    // SB-19's "the same default string in both configuration paths" — this is
    // the iOS side of that sentence, and the version arrives from JS rather
    // than from a literal here.
    XCTAssertEqual(configuration.sdkVersion, "rn-sinch-push/1.1.0")
    XCTAssertEqual(configuration.displayNotifications, .always)

    // Without them: the pinned fallback and the RN-031 default.
    let bare = try XCTUnwrap(SocketConfiguration(configMap: [
      "url": "ws://127.0.0.1:8080/ws", "authToken": "t", "appId": "a", "userId": "u",
    ]))
    XCTAssertNil(bare.sdkVersion)
    XCTAssertEqual(bare.resolvedSDKVersion, SocketConfiguration.defaultSDKVersion)
    XCTAssertEqual(bare.displayNotifications, .whenUnhandled)
    XCTAssertEqual(bare.pollIntervalMs, 0, "0 means: let the server decide")
  }

  func test_SB19_anUnknownDisplayRuleFallsBackRatherThanFailing() throws {
    let configuration = try XCTUnwrap(SocketConfiguration(configMap: [
      "url": "ws://127.0.0.1:8080/ws", "authToken": "t", "appId": "a", "userId": "u",
      "displayNotifications": "sometimes",
    ]))

    // A newer JS that sends a value this build has not heard of must not leave
    // the app with no notifications at all.
    XCTAssertEqual(configuration.displayNotifications, .whenUnhandled)
  }

  // MARK: - SB-24 state before start

  func test_SB24_theFacadeReportsIdleRatherThanFabricatingASession() {
    let facade = SinchPushSocketFacade(
      store: FakeSocketStateStore(),
      tokenStore: InMemoryAuthTokenStore(),
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger())

    let state = facade.stateDictionary()
    XCTAssertEqual(state["status"] as? String, "idle")
    XCTAssertEqual(state["transport"] as? String, "native")
    XCTAssertEqual(facade.pendingMessages().count, 0)
  }

  func test_SB24_clearingPendingMessagesOnAFreshFacadeIsHarmless() {
    let facade = SinchPushSocketFacade(
      store: FakeSocketStateStore(),
      tokenStore: InMemoryAuthTokenStore(),
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger())

    facade.clearPendingMessages()

    XCTAssertEqual(facade.pendingMessages().count, 0)
  }

  // MARK: - SB-30 the host entry point

  func test_SB30_theFacadeRefusesAStatusOnlyTheSdkMayReport() {
    let logger = RecordingLogger()
    let presenter = FakeNotificationPresenter()
    let facade = SinchPushSocketFacade(
      store: FakeSocketStateStore(),
      tokenStore: InMemoryAuthTokenStore(),
      presenter: presenter,
      logger: logger)

    // DELIVERED and FAILED describe what the SDK observed; a host claiming them
    // would put records in the sink the SDK never earned.
    facade.report(messageId: "msg-1", status: "delivered")
    facade.report(messageId: "msg-1", status: "failed")
    facade.report(messageId: "msg-1", status: "DELIVERED")

    XCTAssertTrue(logger.contains("not a host-reportable status"))
    XCTAssertEqual(presenter.posted.count, 0)
    XCTAssertEqual(facade.stateDictionary()["status"] as? String, "idle")
  }

  func test_SB30_theHostDisplayRuleReachesThePresenter() {
    let presenter = FakeNotificationPresenter()
    let facade = SinchPushSocketFacade(
      store: FakeSocketStateStore(),
      tokenStore: InMemoryAuthTokenStore(),
      presenter: presenter,
      logger: SilentSocketLogger())

    facade.setHandlerRegistered(true)
    XCTAssertTrue(presenter.handlerRegistered)

    facade.setHandlerRegistered(false)
    XCTAssertFalse(presenter.handlerRegistered)
  }

  // MARK: - SB-18 / SB-31 where the credential is kept

  func test_SB18_theTokenIsPersistedInTheTokenStoreAndNotInTheStateStore() throws {
    let store = FakeSocketStateStore()
    let tokenStore = InMemoryAuthTokenStore()
    let persisted = expectation(description: "configuration persisted")
    store.onSaveConfiguration = { _ in persisted.fulfill() }

    let facade = SinchPushSocketFacade(
      store: store,
      tokenStore: tokenStore,
      relaySwitch: InMemoryRelaySwitchStore(enabled: true),
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger())
    // Loopback port 1: the upgrade is refused, which is SB-50's retryable path.
    try facade.start(config: configMap)
    wait(for: [persisted], timeout: 10)
    facade.stop()

    XCTAssertEqual(tokenStore.loadToken(), "jwt.token.value")
    // The JWT must not reach a plist, a file or a crash report. Asserted against
    // the encoded form of every slice, not against one field, because the whole
    // point is that no *mapping* could leak it either.
    XCTAssertFalse(store.persistedText(contains: "jwt.token.value"))
    XCTAssertEqual(store.configuration?.url, "ws://127.0.0.1:8080/ws")
  }
}