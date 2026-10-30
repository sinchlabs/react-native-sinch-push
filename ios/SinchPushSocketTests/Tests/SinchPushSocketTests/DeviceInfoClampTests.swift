//  DeviceInfoClampTests.swift — CONTRACT §2.6's 128-byte cap on
//  `os_version`, `bundle_id` and `sdk_version` (SB-59).
//
//  Both places that carry these three fields build their message from the same
//  `DeviceInfo` (`SocketClient.makeHello` and the facade's `getDeviceInfo()` for
//  `Subscribe`), so clamping where `DeviceInfo` is built covers both. The tests
//  are written against the provider rather than against each consumer, with one
//  end-to-end pass through the client, because "the bytes that would reach the
//  relay are within the cap" is the claim that actually matters.

import Foundation
import XCTest

@testable import SinchPushSocket

final class DeviceInfoClampTests: XCTestCase {

  // MARK: - The helper

  func test_SB59_aValueInsideTheCapIsReturnedUnchanged() throws {
    // Values within the cap remain unchanged.
    let bundleId = "com.sinch.example"
    let clamped = DeviceInfo.clampedUTF8(bundleId)
    XCTAssertEqual(clamped, bundleId)
    XCTAssertEqual(clamped.utf8.count, bundleId.utf8.count)
    XCTAssertEqual(bundleId.utf8.count, 17)
  }

  func test_SB59_aLongAsciiValueIsCutToExactlyTheCap() {
    // 200 ASCII bytes: one byte per Character, so the cut lands on 128 exactly.
    let long = String(repeating: "a", count: 200)
    XCTAssertEqual(long.utf8.count, 200)
    let clamped = DeviceInfo.clampedUTF8(long)
    XCTAssertEqual(clamped.utf8.count, 128)
    XCTAssertEqual(clamped, String(repeating: "a", count: 128))
  }

  func test_SB59_aMultiByteValueIsCutToTheCapWithoutBreakingACharacter() {
    // "ż" is two UTF-8 bytes, so the budget is bytes and not characters: a
    // 128-*Character* budget would put 256 bytes on the wire.
    let long = String(repeating: "ż", count: 100)
    XCTAssertEqual(long.utf8.count, 200)
    let clamped = DeviceInfo.clampedUTF8(long)
    XCTAssertLessThanOrEqual(clamped.utf8.count, DeviceInfo.maxDeviceInfoValueBytes)
    // 64 of the 100 fit; the 65th would need byte 129.
    XCTAssertEqual(clamped.utf8.count, 128)
    XCTAssertEqual(clamped, String(repeating: "ż", count: 64))
    // Well-formed, and still the same string the device had rather than a
    // replacement-character rendering of it. `String(decoding:as:UTF8.self)`
    // substitutes U+FFFD for anything malformed, so this catches a cut inside a
    // scalar.
    let roundTripped = String(decoding: clamped.utf8, as: UTF8.self)
    XCTAssertEqual(roundTripped, clamped)
    XCTAssertFalse(roundTripped.unicodeScalars.contains("\u{FFFD}"))
  }

  func test_SB59_aThreeByteValueIsCutAtTheLastWholeCharacter() {
    // 128 is not a multiple of 3, so the cap is not reachable exactly here: the
    // result is the longest prefix that fits (126 bytes), never a partial euro
    // sign.
    let long = String(repeating: "€", count: 50)  // 150 bytes
    XCTAssertEqual(long.utf8.count, 150)
    let clamped = DeviceInfo.clampedUTF8(long)
    XCTAssertLessThanOrEqual(clamped.utf8.count, 128)
    XCTAssertEqual(clamped.utf8.count, 126)
    XCTAssertEqual(clamped, String(repeating: "€", count: 42))
    XCTAssertTrue(long.hasPrefix(clamped))
    XCTAssertFalse(String(decoding: clamped.utf8, as: UTF8.self).unicodeScalars.contains("\u{FFFD}"))
  }

  func test_SB59_fourByteEmojiAreKeptWhole() {
    // Thirty-two four-byte emoji fit in the 128-byte budget.
    let long = String(repeating: "\u{1F600}", count: 40)  // 160 bytes
    XCTAssertEqual(long.utf8.count, 160)
    let clamped = DeviceInfo.clampedUTF8(long)
    XCTAssertLessThanOrEqual(clamped.utf8.count, 128)
    XCTAssertEqual(clamped.utf8.count, 128)
    XCTAssertEqual(clamped, String(repeating: "\u{1F600}", count: 32))
    XCTAssertTrue(long.hasPrefix(clamped))
    XCTAssertFalse(clamped.unicodeScalars.contains("\u{FFFD}"))
  }

  func test_SB59_anEmojiNextToAnAsciiLetterIsCutWhereTheBytesRunOut() {
    // The mixed case, where the cap is not a multiple of the emoji width: 31
    // emojis (124 bytes) and one ASCII letter fit at 125; the 32nd emoji would
    // need byte 129. A cut that ignored the letter would keep 31 and still be
    // over budget.
    let long = String(repeating: "\u{1F600}", count: 31) + "a"
      + String(repeating: "\u{1F600}", count: 20)
    let clamped = DeviceInfo.clampedUTF8(long)
    XCTAssertEqual(clamped.utf8.count, 125)
    XCTAssertEqual(clamped, String(repeating: "\u{1F600}", count: 31) + "a")
    XCTAssertTrue(long.hasPrefix(clamped))
    XCTAssertEqual(String(decoding: clamped.utf8, as: UTF8.self), clamped)
  }

  func test_SB59_anEmojiSequenceIsKeptWholeRatherThanSplit() {
    // Preserve the entire ZWJ grapheme cluster at the truncation boundary.
    // 20 of them: 11 fit (121 bytes) and the 12th would need byte 132.
    let emojis = String(repeating: "\u{1F469}\u{200D}\u{1F4BB}", count: 20)
    XCTAssertEqual(emojis.count, 20)
    XCTAssertGreaterThan(emojis.utf8.count, DeviceInfo.maxDeviceInfoValueBytes)
    let clamped = DeviceInfo.clampedUTF8(emojis)
    XCTAssertEqual(clamped.utf8.count, 121)
    XCTAssertEqual(clamped.count, 11)
    XCTAssertEqual(clamped, String(repeating: "\u{1F469}\u{200D}\u{1F4BB}", count: 11))
  }

  func test_SB59_aGraphemeClusterWiderThanTheCapYieldsNothingRatherThanHalf() {
    // One emoji carrying 200 combining acutes: a single `Character` of 404 bytes,
    // so no prefix of it fits. Empty is the only value the cap admits.
    let wide = "\u{1F469}" + String(repeating: "\u{0301}", count: 200)
    XCTAssertEqual(wide.count, 1)
    XCTAssertEqual(wide.utf8.count, 404)
    XCTAssertEqual(DeviceInfo.clampedUTF8(wide), "")
  }

  func test_SB59_theCapIsTheContracts128Bytes() {
    // Spelled out rather than only used: the number is the contract, and a
    // change to it has to be a deliberate edit next to a test that fails.
    XCTAssertEqual(DeviceInfo.maxDeviceInfoValueBytes, 128)
    // And it is the cap on *bytes*, so a value exactly on it survives whole.
    let exactly = String(repeating: "b", count: DeviceInfo.maxDeviceInfoValueBytes)
    XCTAssertEqual(DeviceInfo.clampedUTF8(exactly), exactly)
    // One byte over does not.
    let oneOver = String(repeating: "b", count: DeviceInfo.maxDeviceInfoValueBytes + 1)
    XCTAssertEqual(DeviceInfo.clampedUTF8(oneOver).utf8.count, 128)
  }

  func test_SB59_theHelperLeavesTheEmptyStringAlone() {
    // An empty os version is a value the relay has to read as "absent" rather
    // than as a truncation.
    XCTAssertEqual(DeviceInfo.clampedUTF8(""), "")
  }

  // MARK: - Applied where DeviceInfo is built

  func test_SB59_theSystemProviderClampsTheThreeCappedFields() throws {
    // The production provider, with every platform read behind its closure, so a
    // host with a 200-byte bundle id does not need to exist to prove the rule.
    let long = String(repeating: "z", count: 200)
    let provider = SystemDeviceInfoProvider(
      installationId: { "6f1c2a9e-3b7d-4e8a-9c21-5d4b7a0e1f23" },
      osVersion: { long },
      bundleId: { long })
    let info = provider.current(sdkVersionOverride: long)

    XCTAssertEqual(info.osVersion.utf8.count, 128)
    XCTAssertEqual(info.bundleId.utf8.count, 128)
    XCTAssertEqual(info.sdkVersion.utf8.count, 128)
    // The fields the contract does *not* cap are untouched: `installation_id`
    // is a UUID validated by format, and `platform` is an enum number.
    XCTAssertEqual(info.installationId, "6f1c2a9e-3b7d-4e8a-9c21-5d4b7a0e1f23")
    XCTAssertEqual(info.platform, SocketConfiguration.platform)
  }

  func test_SB59_theStaticProviderClampsTheSameWay() throws {
    // The provider the client uses when an embedder supplies none, and the one
    // the test suite hands the client. Same rule, or the guarantee would hold
    // only on a real device.
    let provider = StaticDeviceInfoProvider(
      installationId: "6f1c2a9e-3b7d-4e8a-9c21-5d4b7a0e1f23",
      osVersion: String(repeating: "z", count: 200),
      bundleId: String(repeating: "ż", count: 100))
    let info = provider.current(sdkVersionOverride: String(repeating: "z", count: 300))

    XCTAssertEqual(info.osVersion.utf8.count, 128)
    XCTAssertEqual(info.bundleId.utf8.count, 128)
    XCTAssertEqual(info.sdkVersion.utf8.count, 128)
    // Multi-byte input still ends on a whole character on this path.
    XCTAssertFalse(info.bundleId.unicodeScalars.contains("\u{FFFD}"))
    XCTAssertEqual(info.bundleId, String(repeating: "ż", count: 64))
  }

  func test_SB59_normalDeviceValuesReachDeviceInfoUntouched() throws {
    // The clamp must be invisible on a real device: an iOS-shaped install keeps
    // the exact strings the platform reported, or the values sinch-push reads
    // back would differ from the ones the device has.
    let provider = testDeviceInfo(
      installationId: "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11",
      osVersion: "17.5.1",
      bundleId: "com.example.host")
    let info = provider.current(sdkVersionOverride: nil)
    XCTAssertEqual(info.osVersion, "17.5.1")
    XCTAssertEqual(info.bundleId, "com.example.host")
    XCTAssertEqual(info.sdkVersion, SocketConfiguration.resolveSDKVersion(nil))
  }

  // MARK: - End to end: the Hello frame, and the Subscribe's device info

  func test_SB59_theHelloFrameCarriesAtMostTheCapForEveryCappedField() throws {
    // End to end through `SocketClient`: the Hello the relay would see, not just
    // the DeviceInfo behind it. The `sdkVersion` override is the one input JS can
    // make long, so it rides along here too.
    let harness = makeHarness(
      configuration: testConfiguration(sdkVersion: String(repeating: "s", count: 300)),
      deviceInfo: testDeviceInfo(
        osVersion: String(repeating: "o", count: 200),
        bundleId: String(repeating: "ż", count: 100)))
    harness.transport.openSocket()

    let hello = try XCTUnwrap(harness.hello)
    XCTAssertEqual(hello.bundleID, String(repeating: "ż", count: 64))
    XCTAssertLessThanOrEqual(hello.bundleID.utf8.count, 128)
    XCTAssertEqual(hello.osVersion.utf8.count, 128)
    XCTAssertLessThanOrEqual(hello.sdkVersion.utf8.count, 128)
    // And the frame still decodes: a clamp that broke UTF-8 would fail here.
    XCTAssertEqual(harness.transport.sentKinds, ["hello"])
  }

  func test_SB59_theSubscribeFacingDeviceInfoCarriesTheClampedValues() throws {
    // The map `getDeviceInfo()` hands JS (SB-61), built by the same provider, so
    // `Subscribe` cannot carry what `Hello` refused to.
    let provider = StaticDeviceInfoProvider(
      installationId: "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11",
      osVersion: String(repeating: "o", count: 200),
      bundleId: String(repeating: "€", count: 50))
    let info = provider.current(sdkVersionOverride: nil).dictionary

    XCTAssertEqual(try XCTUnwrap(info["osVersion"]).utf8.count, 128)
    XCTAssertEqual(try XCTUnwrap(info["bundleId"]).utf8.count, 126)
    XCTAssertLessThanOrEqual(try XCTUnwrap(info["sdkVersion"]).utf8.count, 128)
    XCTAssertEqual(info["sdkVersion"], SocketConfiguration.defaultSDKVersion)
    XCTAssertEqual(info["installationId"], "0b9c1f0e-6f3a-4b8e-9d57-2f6f6c1a7e11")
    XCTAssertEqual(info["platform"], "ios")
  }
}