//  RelaySwitchTests.swift — the relay off switch (SB-66).
//
//  Four things are pinned here: the store (default off, persisted across
//  instances), the device-info provider (`RELAY_DISABLED` wherever it is read),
//  `start` being refused while off, and `setRelayEnabled(false)` stopping a
//  client that is running.

import XCTest

@testable import SinchPushSocket

final class RelaySwitchTests: XCTestCase {

  private let configMap: NSDictionary = [
    "url": "ws://127.0.0.1:1/ws",
    "authToken": "t",
    "appId": "a",
    "userId": "u",
  ]

  /// A private suite per test, so nothing leaks into `UserDefaults.standard`.
  private func freshDefaults() -> UserDefaults {
    let name = "RelaySwitchTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    addTeardownBlock { defaults.removePersistentDomain(forName: name) }
    return defaults
  }

  /// The facade over the socket fakes and a manual clock.
  ///
  /// Most of what the relay switch changes is on the edges of a connection that
  /// never gets one. The rules below are about *not* opening a socket, which is
  /// only an assertion if opening one is countable — so these take the fake
  /// transport and a clock whose work runs inline, and "no new socket" is a
  /// settled fact when the call returns rather than a race against a queue.
  private func facadeOverFakes(
    relaySwitch: RelaySwitchStore = InMemoryRelaySwitchStore(enabled: true),
    store: FakeSocketStateStore = FakeSocketStateStore(),
    lifecycleFactory: ((SocketClient) -> FakeLifecycleObserver)? = nil
  ) -> (
    facade: SinchPushSocketFacade,
    sockets: FakeSocketTransportFactory,
    observers: () -> [FakeLifecycleObserver]
  ) {
    let sockets = FakeSocketTransportFactory()
    var made: [FakeLifecycleObserver] = []
    // Copied out of the parameter before it is captured: the facade keeps the
    // factory for the life of the facade, and an argument is not escaping.
    let supplied: ((SocketClient) -> FakeLifecycleObserver)? = lifecycleFactory
    var factory: SocketLifecycleObserverFactory?
    if let supplied {
      factory = { client in
        let observer = supplied(client)
        made.append(observer)
        return observer
      }
    }
    let facade = SinchPushSocketFacade(
      store: store,
      tokenStore: InMemoryAuthTokenStore(),
      installationIdStore: KeychainInstallationIdStore(
        backing: InMemoryInstallationIdBacking(), logger: SilentSocketLogger()),
      relaySwitch: relaySwitch,
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger(),
      transportFactory: sockets,
      scheduler: ManualScheduler(),
      lifecycleFactory: factory)
    return (facade, sockets, { made })
  }

  // MARK: - The store

  func test_SB66_theUserDefaultsStoreDefaultsToOffUnderTheDocumentedKey() {
    let defaults = freshDefaults()
    let store = UserDefaultsRelaySwitchStore(defaults: defaults)

    XCTAssertFalse(store.isEnabled, "a missing key means never switched on")
    XCTAssertEqual(UserDefaultsRelaySwitchStore.key, "com.sinch.push.relay.enabled")

    store.setEnabled(true)
    XCTAssertEqual(defaults.object(forKey: "com.sinch.push.relay.enabled") as? Bool, true)
  }

  func test_SB66_theSwitchSurvivesANewStoreOverTheSameDefaults() {
    let defaults = freshDefaults()
    UserDefaultsRelaySwitchStore(defaults: defaults).setEnabled(true)

    XCTAssertTrue(UserDefaultsRelaySwitchStore(defaults: defaults).isEnabled)

    UserDefaultsRelaySwitchStore(defaults: defaults).setEnabled(false)
    XCTAssertFalse(UserDefaultsRelaySwitchStore(defaults: defaults).isEnabled)
  }

  func test_SB66_aFacadeOverTheSameStoreSeesTheSwitchAfterARelaunch() {
    let defaults = freshDefaults()
    let switched = facadeOverFakes(relaySwitch: UserDefaultsRelaySwitchStore(defaults: defaults))
    switched.facade.setRelayEnabled(true)

    let relaunched = facadeOverFakes(relaySwitch: UserDefaultsRelaySwitchStore(defaults: defaults))

    XCTAssertTrue(relaunched.facade.isRelayEnabled())
  }

  func test_SB66_theInMemoryStoreDefaultsToOffAndKeepsTheLastValue() {
    let store = InMemoryRelaySwitchStore()
    XCTAssertFalse(store.isEnabled)
    store.setEnabled(true)
    XCTAssertTrue(store.isEnabled)
    store.setEnabled(false)
    XCTAssertFalse(store.isEnabled)
  }

  // MARK: - SB-60 / SB-61: RELAY_DISABLED

  func test_SB60_theProviderReportsRelayDisabledWhileOffAndUnsupportedOtherwise() {
    let relaySwitch = InMemoryRelaySwitchStore(enabled: true)
    let provider = SystemDeviceInfoProvider(
      installationId: { "id" }, relaySwitch: relaySwitch)

    XCTAssertEqual(provider.current(sdkVersionOverride: nil).backgroundService, .unsupported)

    relaySwitch.setEnabled(false)
    XCTAssertEqual(provider.current(sdkVersionOverride: nil).backgroundService, .relayDisabled)

    relaySwitch.setEnabled(true)
    XCTAssertEqual(provider.current(sdkVersionOverride: nil).backgroundService, .unsupported)
  }

  func test_SB61_getDeviceInfoNamesRelayDisabledForJS() throws {
    let (facade, _, _) = facadeOverFakes()
    facade.setRelayEnabled(false)

    let off = try XCTUnwrap(facade.deviceInfo() as? [String: String])
    XCTAssertEqual(off["backgroundService"], "RELAY_DISABLED")

    facade.setRelayEnabled(true)
    let on = try XCTUnwrap(facade.deviceInfo() as? [String: String])
    XCTAssertEqual(on["backgroundService"], "UNSUPPORTED")
  }

  // MARK: - SB-66: start is refused, a running client is stopped

  func test_SB66_startIsRefusedWhileTheRelayIsOffAndOpensNothing() {
    let store = FakeSocketStateStore()
    let (facade, _, _) = facadeOverFakes(
      relaySwitch: InMemoryRelaySwitchStore(enabled: false), store: store)

    XCTAssertThrowsError(try facade.start(config: configMap)) { error in
      let nsError = error as NSError
      XCTAssertEqual(nsError.domain, "SinchPushSocketErrorDomain")
      XCTAssertEqual(nsError.code, SinchPushSocketFacade.relayDisabledErrorCode)
      // Domain and code together are what `SinchPush.mm` matches on, so the
      // domain is exposed for exactly this: the code on its own is one other
      // domains use, and matching it alone would blame the switch for a failure
      // that has nothing to do with it.
      XCTAssertEqual(nsError.domain, SinchPushSocketFacade.relayDisabledErrorDomain)
      XCTAssertNotEqual(NSError(domain: "SomeOtherDomain", code: nsError.code).domain,
                        SinchPushSocketFacade.relayDisabledErrorDomain)
    }
    XCTAssertNil(facade.client, "no client was created for a refused start")
    XCTAssertNil(store.configuration, "nothing was persisted for a refused start")
    XCTAssertEqual(facade.stateDictionary()["status"] as? String, "idle")
  }

  func test_SB66_turningTheRelayBackOnStartsNothingButAllowsAStart() throws {
    let (facade, _, _) = facadeOverFakes(
      relaySwitch: InMemoryRelaySwitchStore(enabled: false))

    facade.setRelayEnabled(true)

    XCTAssertTrue(facade.isRelayEnabled())
    XCTAssertNil(facade.client, "switching on must not open a socket")
    try facade.start(config: configMap)
    defer { facade.stop() }
    XCTAssertNotNil(facade.client)
  }

  func test_SB66_switchingTheRelayOffStopsARunningClient() throws {
    let (facade, sockets, _) = facadeOverFakes()
    try facade.start(config: configMap)
    sockets.current?.openSocket()
    XCTAssertNotNil(facade.client)

    facade.setRelayEnabled(false)

    // The manual clock runs the client's work inline, so the stopped state is
    // settled when the call returns: no background poller, no race.
    XCTAssertEqual(facade.stateDictionary()["status"] as? String, "stopped")
    XCTAssertFalse(facade.isRelayEnabled())
    XCTAssertThrowsError(try facade.start(config: configMap))
  }

  func test_SB66_switchingTheRelayOffBeforeAnyStartIsHarmless() {
    let (facade, _, _) = facadeOverFakes()

    facade.setRelayEnabled(false)

    XCTAssertFalse(facade.isRelayEnabled())
    XCTAssertEqual(facade.stateDictionary()["status"] as? String, "idle")
  }

  // MARK: - SB-66: nothing else reopens the socket while it is off
  //
  // `setRelayEnabled(false)` is not the last word on "no socket". The stop it
  // performs is an ordinary one, and two ordinary paths would otherwise undo
  // it: the host rotating its credential (`auth_required`), and the app
  // coming back to the foreground (SB-56). Both reach the client's reconnect
  // code, so both have to ask the switch first.

  func test_SB66_aTokenRotationWhileTheRelayIsOffOpensNoSocket() throws {
    let relaySwitch = InMemoryRelaySwitchStore(enabled: true)
    let (facade, sockets, _) = facadeOverFakes(relaySwitch: relaySwitch)
    try facade.start(config: configMap)
    sockets.current?.openSocket()
    XCTAssertEqual(sockets.createdCount, 1)
    XCTAssertEqual(sockets.current?.hellos.count, 1)

    facade.setRelayEnabled(false)
    facade.updateToken("rotated.jwt")

    XCTAssertEqual(
      sockets.createdCount, 1,
      "updateConfiguration clears `stopped` and opens, so an unguarded rotation revives the socket")
    XCTAssertEqual(sockets.current?.hellos.count, 1, "a second Hello means a second connection")
    XCTAssertEqual(
      facade.stateDictionary()["status"] as? String, "stopped",
      "the relay is off, so the client has to stay stopped rather than merely quiet")
  }

  func test_SB66_aTokenRotationWhileTheRelayIsOnStillReconnects() throws {
    let (facade, sockets, _) = facadeOverFakes()
    try facade.start(config: configMap)
    sockets.current?.openSocket()
    XCTAssertEqual(sockets.createdCount, 1)

    // The control for the test above: a credential rotation is not a casualty
    // of the guard.
    facade.updateToken("rotated.jwt")

    XCTAssertEqual(sockets.createdCount, 2, "a rotation while the relay is on reconnects")
    sockets.current?.openSocket()
    XCTAssertEqual(sockets.current?.hellos.last?.authToken, "rotated.jwt")
  }

  func test_SB66_aForegroundSignalWhileTheRelayIsOffOpensNoSocket() throws {
    let relaySwitch = InMemoryRelaySwitchStore(enabled: true)
    let (facade, sockets, _) = facadeOverFakes(relaySwitch: relaySwitch)
    try facade.start(config: configMap)
    sockets.current?.openSocket()
    facade.applyLifecycleSignal("background")
    XCTAssertEqual(sockets.createdCount, 1, "the background transition is what there is to resume from")

    // The switch is persisted and read by native code, so it can be off while
    // this process still believes it is running: `initialize` applying the
    // persisted value, or a second facade over the same store, both write the
    // value without stopping this client. A resume is the dangerous direction —
    // it is the one that dials.
    relaySwitch.setEnabled(false)
    facade.applyLifecycleSignal("foreground")

    XCTAssertEqual(
      sockets.createdCount, 1,
      "the app came back to the foreground and dialled a socket the host turned off")
    XCTAssertEqual(sockets.current?.hellos.count, 1)
  }

  func test_SB66_aForegroundSignalWhileTheRelayIsOnStillReconnects() throws {
    let (facade, sockets, _) = facadeOverFakes()
    try facade.start(config: configMap)
    sockets.current?.openSocket()

    facade.applyLifecycleSignal("background")
    facade.applyLifecycleSignal("foreground")

    XCTAssertEqual(sockets.createdCount, 2, "SB-56's foreground reconnect is untouched")
  }

  // MARK: - SB-66: the lifecycle observer survives a stop

  func test_SB66_theLifecycleObserverIsReattachedAfterAStop() throws {
    let (facade, sockets, observers) = facadeOverFakes(
      lifecycleFactory: { FakeLifecycleObserver(client: $0) })
    try facade.start(config: configMap)
    XCTAssertEqual(observers().count, 1)
    XCTAssertTrue(observers().last?.isObserving == true)

    facade.stop()
    XCTAssertEqual(observers()[0].stopCount, 1, "a stop detaches the observer")

    try facade.start(config: configMap)

    XCTAssertEqual(observers().count, 2, "the second start found the observer flag still set")
    let reattached = observers()[1]
    XCTAssertTrue(
      reattached.isObserving,
      "a socket that does not follow the app is a socket that stops reconnecting")

    // Attached is not the same as wired: the observer that came back has to be
    // the one driving the running client, which is what a foreground transition
    // arriving through it proves.
    let before = sockets.createdCount
    reattached.goBackground()
    reattached.goForeground()
    XCTAssertEqual(sockets.createdCount, before + 1, "the reattached observer does not drive the client")
  }

  func test_SB66_theLifecycleObserverIsReattachedAfterARelayRoundTrip() throws {
    let (facade, _, observers) = facadeOverFakes(
      lifecycleFactory: { FakeLifecycleObserver(client: $0) })
    try facade.start(config: configMap)
    XCTAssertEqual(observers().count, 1)

    facade.setRelayEnabled(false)
    facade.setRelayEnabled(true)
    try facade.start(config: configMap)

    XCTAssertEqual(observers().count, 2, "the start after switching the relay back on attached nothing")
    XCTAssertTrue(observers().last?.isObserving == true)
    XCTAssertFalse(observers()[0].isObserving, "the observer the switch-off detached is still attached")
  }
}
