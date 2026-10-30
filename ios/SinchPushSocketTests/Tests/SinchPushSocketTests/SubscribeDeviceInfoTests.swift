//  SubscribeDeviceInfoTests.swift — `getDeviceInfo()` on iOS (SB-61).
//
//  The facade answers with the collectors `Hello` uses (SB-59, SB-60), so these
//  tests pin the *dictionary* JS receives and that it agrees with the Hello's
//  provider and the installation-id accessor. The wire mapping onto the push
//  API's enums is JS's (`__tests__/subscribeDeviceInfo.test.ts`).

import XCTest

@testable import SinchPushSocket

final class SubscribeDeviceInfoTests: XCTestCase {

  /// A slot that cannot be read, as before the first unlock after boot.
  private final class LockedBacking: InstallationIdBacking {
    func loadInstallationId() -> InstallationIdLoad {
      return .unavailable(reason: "the keychain returned status -25308")
    }
    func saveInstallationId(_ id: String) -> Bool { return false }
  }

  /// The facade over the socket fakes and a manual clock, so the one test that
  /// starts a client gets a settled socket instead of a connection attempt.
  private func facade(backing: InstallationIdBacking = InMemoryInstallationIdBacking())
    -> SinchPushSocketFacade
  {
    return SinchPushSocketFacade(
      store: FakeSocketStateStore(),
      tokenStore: InMemoryAuthTokenStore(),
      installationIdStore: KeychainInstallationIdStore(
        backing: backing, logger: SilentSocketLogger()),
      relaySwitch: InMemoryRelaySwitchStore(enabled: true),
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger(),
      transportFactory: FakeSocketTransportFactory(),
      scheduler: ManualScheduler())
  }

  func test_SB61_theFacadeAnswersWithAllSixFieldsAsStrings() throws {
    let facade = facade()

    let info = try XCTUnwrap(facade.deviceInfo() as? [String: String])

    XCTAssertEqual(
      Set(info.keys),
      ["installationId", "platform", "osVersion", "sdkVersion", "bundleId", "backgroundService"])
    XCTAssertEqual(info["platform"], "ios")
    XCTAssertEqual(info["backgroundService"], "UNSUPPORTED")
    XCTAssertEqual(info["sdkVersion"], SocketConfiguration.defaultSDKVersion)
    XCTAssertEqual(info["osVersion"], SystemDeviceInfoProvider.systemOSVersion())
    XCTAssertFalse(try XCTUnwrap(info["osVersion"]).isEmpty)
  }

  func test_SB61_theInstallationIdIsTheOneGetInstallationIdReturns() throws {
    let facade = facade()

    let info = try XCTUnwrap(facade.deviceInfo() as? [String: String])

    XCTAssertEqual(info["installationId"], facade.installationId())
    XCTAssertEqual(
      (facade.deviceInfo() as? [String: String])?["installationId"], info["installationId"],
      "a second call minted a different id")
  }

  func test_SB61_subscribeAndHelloAreToldTheSameFacts() throws {
    let backing = InMemoryInstallationIdBacking()
    let facade = facade(backing: backing)
    let info = try XCTUnwrap(facade.deviceInfo() as? [String: String])

    // Hello's provider over the same store, as the facade wires it.
    let store = KeychainInstallationIdStore(backing: backing, logger: SilentSocketLogger())
    let hello = SystemDeviceInfoProvider(
      installationId: { try store.installationId() },
      relaySwitch: InMemoryRelaySwitchStore(enabled: true)
    )
    .current(sdkVersionOverride: nil)

    XCTAssertEqual(info, hello.dictionary)
  }

  func test_SB61_noIdMeansNoDeviceInfoRatherThanOneWithAnInventedId() {
    let facade = facade(backing: LockedBacking())

    // `SinchPush.mm` rejects with E_INSTALLATION_ID_UNAVAILABLE; JS then
    // subscribes without device info.
    XCTAssertNil(facade.deviceInfo())
  }

  func test_SB61_theSdkVersionOverrideIsForHelloOnlyAndSubscribeAlwaysReportsTheBuiltInOne() throws {
    let facade = facade()
    try facade.start(config: [
      "url": "ws://127.0.0.1:1/ws", "authToken": "t", "appId": "a", "userId": "u",
      "sdkVersion": "rn-sinch-push/9.9.9",
    ])
    defer { facade.stop() }

    let info = try XCTUnwrap(facade.deviceInfo() as? [String: String])

    XCTAssertEqual(info["sdkVersion"], SocketConfiguration.defaultSDKVersion)
  }

  func test_SB61_everyBackgroundServiceStateHasItsNameForJS() {
    let names: [(DeviceInfo.BackgroundServiceState, String)] = [
      (.unsupported, "UNSUPPORTED"),
      (.disabled, "DISABLED"),
      (.enabledRunning, "ENABLED_RUNNING"),
      (.enabledNotRunning, "ENABLED_NOT_RUNNING"),
      (.relayDisabled, "RELAY_DISABLED"),
    ]
    for (state, name) in names {
      var info = StaticDeviceInfoProvider(installationId: "i").current(sdkVersionOverride: nil)
      info.backgroundService = state
      XCTAssertEqual(info.dictionary["backgroundService"], name)
    }
  }
}
