//  RelaySwitch.swift — the relay off switch (RN-048, SB-66).
//
//  "Is the relay on for this install?" is a fact native code has to answer
//  without JS: `getDeviceInfo()` for a `Subscribe`, a `Hello` and `start` all
//  have to agree with it, so the value is persisted here rather than carried in
//  the JS config. Pure Swift and Foundation-only, like the rest of the core: a
//  host SDK that embeds the core supplies its own store, or uses the
//  `UserDefaults` one.

import Foundation

/// Where the switch lives. A protocol so tests (and a host SDK) can swap the
/// storage; the rules (a refused start, `RELAY_DISABLED`) sit above it.
protocol RelaySwitchStore: AnyObject {
  /// Whether the relay may run at all. `false` unless something turned it on.
  var isEnabled: Bool { get }

  /// Persists the switch; visible to every later read.
  func setEnabled(_ enabled: Bool)
}

/// The production store: `UserDefaults`, key ``key``, default `false`.
///
/// Plain defaults rather than the Keychain: the value is a policy, not a
/// secret, and a missing key must read as "never switched on": the relay is an
/// explicit opt-in.
final class UserDefaultsRelaySwitchStore: RelaySwitchStore {
  /// One key, shared with the Android preference name's meaning (SB-66).
  static let key = "com.sinch.push.relay.enabled"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var isEnabled: Bool {
    // An absent key is `false`: the relay stays off until an integrator opts in,
    // which is what `bool(forKey:)` answers for it.
    defaults.bool(forKey: Self.key)
  }

  func setEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: Self.key)
  }
}

/// A store with no persistence: the default for a provider or client built
/// without one (tests, an embedder that never turns the relay on).
final class InMemoryRelaySwitchStore: RelaySwitchStore {
  private let lock = NSLock()
  private var enabled: Bool

  init(enabled: Bool = false) {
    self.enabled = enabled
  }

  var isEnabled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return enabled
  }

  func setEnabled(_ enabled: Bool) {
    lock.lock()
    self.enabled = enabled
    lock.unlock()
  }
}

/// `start` refused because the relay is off (SB-66). The bridge maps it to
/// `E_RELAY_DISABLED`, the code JS already produces for an unavailable relay.
enum SocketStartError: Error, CustomNSError, LocalizedError {
  case relayDisabled

  /// Both read by `SinchPush.mm` as a domain/code pair.
  static var errorDomain: String { "SinchPushSocketErrorDomain" }
  static let relayDisabledCode = 1

  var errorCode: Int { Self.relayDisabledCode }

  var errorDescription: String? {
    "the relay is turned off in the SDK; pass socket.enabled: true to initialize (or call setRelayEnabled(true))"
  }
}
