//  DeviceInfo.swift — what the relay is told about this install in `Hello`
//  (RN-042, SB-59, SB-60).
//
//  Fields 9–12 of `Hello` (`installation_id`, `os_version`, `bundle_id`,
//  `background_service`) plus the two it already carried that are derived from
//  the device rather than from the credential (`platform`, `sdk_version`) are
//  collected here, in one place, so that:
//
//    * every value has exactly one source (SB-59), and the Hello builder stays a
//      mapping with no policy in it;
//    * the three fields the relay caps (CONTRACT §2.6) are clamped here, at the
//      one place both `Hello` and `getDeviceInfo()` read them from;
//    * the tests can hand the client a provider whose os version, bundle id and
//      installation id are fakes, instead of reading the host's `Bundle.main`
//      (which under `swift test` is `xctest`) or its Keychain.
//
//  Pure Swift on purpose: React-free and Foundation-only. The os version comes
//  from `ProcessInfo` on every platform (no UIKit, no main-thread hop), so the
//  Hello can be built on the client's serial queue.

import Foundation

/// The device facts one `Hello` carries.
///
/// `installationId`, `platform`, `osVersion`, `sdkVersion`, `bundleId` and
/// `backgroundService` map onto `Hello` fields 9–12 plus the two the credential
/// does not supply, and onto the same facts in `Subscribe`.
struct DeviceInfo: Equatable {
  /// Nested rather than top-level, so porting the core into a host SDK cannot
  /// collide with a host type of the same name.
  typealias BackgroundServiceState = Sinch_Push_V1beta1_Resources_BackgroundServiceState

  /// Empty when the store could not produce one (SB-59): the relay treats an
  /// empty id as a legacy client, which degrades routing for this connection
  /// rather than losing it.
  var installationId: String
  var platform: Sinch_Push_Delivery_V1beta1_Ws_Platform
  var osVersion: String
  var sdkVersion: String
  var bundleId: String
  var backgroundService: BackgroundServiceState
}

extension DeviceInfo {
  /// `getDeviceInfo()` as JS reads it (SB-61): plain strings, with the
  /// platform and the background-service state by name rather than by wire
  /// number, so JS owns the mapping onto the push API's `resources` enums.
  var dictionary: [String: String] {
    return [
      "installationId": installationId,
      "platform": platform == .ios ? "ios" : "android",
      "osVersion": osVersion,
      "sdkVersion": sdkVersion,
      "bundleId": bundleId,
      "backgroundService": backgroundServiceName,
    ]
  }

  private var backgroundServiceName: String {
    switch backgroundService {
    case .disabled: return "DISABLED"
    case .enabledRunning: return "ENABLED_RUNNING"
    case .enabledNotRunning: return "ENABLED_NOT_RUNNING"
    case .relayDisabled: return "RELAY_DISABLED"
    // `.unsupported` is what iOS always reports (SB-60); anything else cannot be
    // produced by these providers and degrades to it.
    default: return "UNSUPPORTED"
    }
  }
}

extension DeviceInfo {
  // MARK: - CONTRACT §2.6 length cap

  /// The relay's cap on `os_version`, `bundle_id` and `sdk_version`, in bytes.
  ///
  /// A `Hello` whose value exceeds the cap is **rejected like any other malformed
  /// Hello** — closed with a reason, no session stored — not truncated by the
  /// relay. So the SDK has to fit inside the cap itself: over the limit is not a
  /// degraded session, it is no session at all.
  static let maxDeviceInfoValueBytes = 128

  /// ``s`` shortened to at most `maxBytes` UTF-8 bytes, dropping whole trailing
  /// `Character`s.
  ///
  /// Truncate at `Character` boundaries to preserve complete grapheme clusters
  /// within the byte budget.
  ///
  /// A scalar boundary would already keep the UTF-8 valid; the grapheme
  /// boundary is a deliberately stronger choice. Android truncates at scalar
  /// boundaries.
  ///
  /// Bytes rather than `count` because the contract says bytes: "ż" is one
  /// `Character` and two bytes, so a `Character` budget would let 128 of them
  /// through as a 256-byte field — still rejected, still no session.
  ///
  /// - Returns: `s` itself when it already fits (the common case — an OS version
  ///   and an SDK version are a handful of bytes), otherwise a prefix of it.
  static func clampedUTF8(_ s: String, maxBytes: Int = DeviceInfo.maxDeviceInfoValueBytes) -> String {
    guard s.utf8.count > maxBytes else { return s }
    var kept = ""
    kept.reserveCapacity(maxBytes)
    var used = 0
    for character in s {
      let width = character.utf8.count
      if used + width > maxBytes { break }
      kept.append(character)
      used += width
    }
    return kept
  }
}

/// Source of ``DeviceInfo``, injected into the client so a test can supply one.
protocol DeviceInfoProviding: AnyObject {
  /// The facts as they are *now* — called once per `Hello`, never cached by the
  /// client, so an installation id that was unavailable on one connect is
  /// retried on the next.
  ///
  /// - Parameter sdkVersionOverride: `SocketConfiguration.sdkVersion`, the
  ///   JS-supplied value that exists for tests (SB-19). `nil` or empty selects
  ///   the single built-in source, ``SocketConfiguration/defaultSDKVersion``.
  func current(sdkVersionOverride: String?) -> DeviceInfo
}

/// The production provider, with every platform read behind a closure.
///
/// Closures rather than a protocol per value: there are three one-line reads,
/// and a test replaces each with a literal.
final class SystemDeviceInfoProvider: DeviceInfoProviding {
  private let installationId: () throws -> String
  private let osVersion: () -> String
  private let bundleId: () -> String
  private let logger: SocketLogger
  private let relaySwitch: RelaySwitchStore

  /// - Parameters:
  ///   - installationId: the installation-id store's `installationId()`. A throw is
  ///     logged and becomes an empty id (SB-59); it never fails the connection.
  ///   - osVersion: defaults to ``systemOSVersion()``.
  ///   - bundleId: defaults to `Bundle.main.bundleIdentifier`.
  ///   - relaySwitch: the relay off switch (SB-66). The default is an
  ///     in-memory "off" (the relay is opt-in), for a provider built without one.
  init(
    installationId: @escaping () throws -> String,
    osVersion: @escaping () -> String = SystemDeviceInfoProvider.systemOSVersion,
    bundleId: @escaping () -> String = { Bundle.main.bundleIdentifier ?? "" },
    logger: SocketLogger = SilentSocketLogger(),
    relaySwitch: RelaySwitchStore = InMemoryRelaySwitchStore()
  ) {
    self.installationId = installationId
    self.osVersion = osVersion
    self.bundleId = bundleId
    self.logger = logger
    self.relaySwitch = relaySwitch
  }

  func current(sdkVersionOverride: String?) -> DeviceInfo {
    let id: String
    do {
      id = try installationId()
    } catch {
      // SB-59: not knowing the id must not cost the connection. The relay reads
      // an empty `installation_id` as a legacy client, and the next Hello asks
      // the store again, so a Keychain that was locked at boot recovers on the
      // first reconnect after it opens.
      logger.log("installation id unavailable, sending Hello without it: \(error)")
      id = ""
    }
    return DeviceInfo(
      installationId: id,
      platform: SocketConfiguration.platform,
      // SB-59: the three capped fields (CONTRACT §2.6) are clamped where the
      // DeviceInfo is built, so `Hello` and `getDeviceInfo()` are both covered.
      // `installation_id` is a UUID validated by format and `platform` an enum
      // number, so neither can exceed the cap.
      osVersion: DeviceInfo.clampedUTF8(osVersion()),
      sdkVersion: DeviceInfo.clampedUTF8(
        SocketConfiguration.resolveSDKVersion(sdkVersionOverride)),
      bundleId: DeviceInfo.clampedUTF8(bundleId()),
      // SB-60: iOS has no background socket, so this is a constant rather than
      // something read from configuration - except that the relay off switch
      // overrides it (SB-66): off is `RELAY_DISABLED` wherever the value is read.
      backgroundService: relaySwitch.isEnabled ? .unsupported : .relayDisabled)
  }

  // MARK: - OS version (SB-59)

  /// The running OS version, ``formatOSVersion(_:)`` over
  /// `ProcessInfo.operatingSystemVersion` on every platform.
  ///
  /// `ProcessInfo` is thread-safe, so unlike `UIDevice.current.systemVersion`
  /// (main-actor isolated) it can be read on the client's serial queue; the
  /// rule below makes it print the same string `UIDevice` does.
  static func systemOSVersion() -> String {
    return formatOSVersion(ProcessInfo.processInfo.operatingSystemVersion)
  }

  /// `major.minor`, plus `.patch` only when it is non-zero — the shape
  /// `UIDevice.systemVersion` has ("17.5", "17.5.1"), so the two sources agree.
  static func formatOSVersion(_ version: OperatingSystemVersion) -> String {
    var text = "\(version.majorVersion).\(version.minorVersion)"
    if version.patchVersion != 0 { text += ".\(version.patchVersion)" }
    return text
  }
}

/// A provider that returns a fixed value — the core's default for a client built
/// without one (tests, and any embedder that does not care about routing), so the
/// default never reads a Keychain.
final class StaticDeviceInfoProvider: DeviceInfoProviding {
  var installationId: String
  var osVersion: String
  var bundleId: String

  init(installationId: String = "", osVersion: String = "", bundleId: String = "") {
    self.installationId = installationId
    self.osVersion = osVersion
    self.bundleId = bundleId
  }

  func current(sdkVersionOverride: String?) -> DeviceInfo {
    return DeviceInfo(
      installationId: installationId,
      platform: SocketConfiguration.platform,
      // SB-59 / CONTRACT §2.6: same clamp as the system provider above, so the
      // guarantee does not hold only on a real device.
      osVersion: DeviceInfo.clampedUTF8(osVersion),
      sdkVersion: DeviceInfo.clampedUTF8(
        SocketConfiguration.resolveSDKVersion(sdkVersionOverride)),
      bundleId: DeviceInfo.clampedUTF8(bundleId),
      backgroundService: .unsupported)
  }
}
