//  InstallationIdStore.swift — the one value that identifies an *install*
//  rather than a user or a session (RN-041).
//
//  The relay's `Hello.installation_id` and the push API's
//  `Subscribe.installation_id` must be the same string, so the id cannot come
//  from anything that rotates: not a JWT refresh (RN-008), not an identity
//  change, not a socket restart. It is generated once, on first use, and then
//  only read.
//
//  At rest it lives in the Keychain next to the auth token rather than in
//  `UserDefaultsSocketStateStore`: a Keychain item survives an uninstall on the
//  same device, which for an installation id is harmless (same device, same
//  install intent) and is accepted deliberately — see the README. The
//  `ThisDeviceOnly` accessibility class is what stops it migrating to a
//  restored device, where a duplicate id *would* matter.
//
//  The rule that shapes this file is that **not knowing is not the same as
//  there being nothing**. A read that fails for any reason other than "no item"
//  says nothing about whether this install already has an id, so an unreadable
//  slot is surfaced to the host as `E_INSTALLATION_ID_UNAVAILABLE` rather than
//  replaced.
//
//  This file is self-contained on purpose (protocol + Keychain implementation +
//  in-memory fallback, no dependency on the facade or on the socket client),
//  because the same core is ported into the native iOS SDK, where the only thing
//  a host needs from it is `installationId()`.

import Foundation

// MARK: - Outcomes

/// What reading the persisted slot produced.
///
/// Three cases, because "absent" and "could not be read" have opposite answers.
enum InstallationIdLoad {
  /// The slot holds this id.
  case found(String)
  /// The slot is empty: first launch, or the item was deleted.
  case absent
  /// The slot could not be read — a locked Keychain before the first unlock
  /// (`errSecInteractionNotAllowed`), a device policy, a transient failure — so
  /// the id may well be there and nothing is replaced.
  case unavailable(reason: String)
}

/// The install's id could not be produced.
///
/// Thrown rather than resolved because a per-process id is a different
/// installation on every launch. `SinchPush.mm` turns this into
/// `E_INSTALLATION_ID_UNAVAILABLE` so the host can retry instead of believing
/// a new install happened.
enum InstallationIdError: Error, CustomStringConvertible {
  /// The slot could not be read, or a newly minted id could not be persisted.
  case unavailable(reason: String)

  var description: String {
    switch self {
    case .unavailable(let reason):
      return "installation id unavailable: \(reason)"
    }
  }
}

// MARK: - Seams

/// The per-install identity.
///
/// One method on purpose: an id that could be *set* is an id something can
/// rotate, and this one must never be.
protocol InstallationIdStore: AnyObject {
  /// The install's id: a lowercase canonical UUID (8-4-4-4-12). Generated and
  /// persisted on first call, and the same value on every call after that —
  /// including from concurrent first calls.
  ///
  /// - Throws: ``InstallationIdError/unavailable(reason:)`` when the slot cannot
  ///   be read or a new id cannot be persisted. If a stored id cannot be read,
  ///   throw without replacing it; if creating or persisting a new id fails,
  ///   throw without returning or caching the candidate. Retry when storage is
  ///   available.
  func installationId() throws -> String
}

/// Where the id is kept between launches.
///
/// Injected rather than hard-coded to the Keychain so the generate-once and
/// concurrency rules can be tested without one: `swift test` runs on a host
/// where a test binary has no business writing to the login Keychain.
protocol InstallationIdBacking: AnyObject {
  /// What reading the slot produced — see ``InstallationIdLoad`` for why this is
  /// not an optional string.
  func loadInstallationId() -> InstallationIdLoad

  /// Writes the id, returning whether it **reached storage**.
  ///
  /// The answer matters: an id that was generated but not persisted is not one
  /// the store may hand out, or the next launch would mint a different one and
  /// the relay would see two installations from one device.
  @discardableResult
  func saveInstallationId(_ id: String) -> Bool
}

/// An in-memory slot: the fallback where there is no Security framework, and
/// what the tests inject as "the Keychain".
///
/// Thread-safe because it stands in for storage that is.
final class InMemoryInstallationIdBacking: InstallationIdBacking {
  private let lock = NSLock()
  private var stored: String?

  init(id: String? = nil) {
    self.stored = id
  }

  /// The slot's contents, for tests that assert what was (or was not) written.
  var storedId: String? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func loadInstallationId() -> InstallationIdLoad {
    lock.lock()
    defer { lock.unlock() }
    guard let stored else { return .absent }
    return .found(stored)
  }

  func saveInstallationId(_ id: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    stored = id
    return true
  }
}

// MARK: - The store

/// Generates the id once and then persists it, under the Keychain by default.
///
/// The invariant: one cached installation UUID, cached only once storage
/// confirms it. Load-or-generate is one critical section, so two threads
/// racing on first use cannot mint two ids for one install.
final class KeychainInstallationIdStore: InstallationIdStore {
  /// The default slot, and the shared instance every host ends up using.
  ///
  /// Shared rather than one-per-facade so the lock covers the whole process: a
  /// second store over the same Keychain item would otherwise be a second race
  /// on the same first call.
  static let shared = KeychainInstallationIdStore()

  private let backing: InstallationIdBacking
  private let generate: () -> String
  private let logger: SocketLogger

  private let lock = NSLock()
  /// Resolved id, kept after the first call: an id this cheap to cache is not
  /// worth a Keychain round trip per `Hello`. Only ever a value that is in
  /// storage — see ``generateAndPersist()``.
  private var resolved: String?

  /// - Parameters:
  ///   - backing: the slot to read and write. `nil` (the default) is the
  ///     Keychain, or an in-memory slot on a host without the Security
  ///     framework.
  ///   - generate: the id factory; the parameter exists so a test can count
  ///     generations, which is how "generated once" is asserted.
  init(
    backing: InstallationIdBacking? = nil,
    generate: @escaping () -> String = KeychainInstallationIdStore.newIdentifier,
    logger: SocketLogger = PrintSocketLogger()
  ) {
    self.backing = backing ?? KeychainInstallationIdStore.makeDefaultBacking(logger: logger)
    self.generate = generate
    self.logger = logger
  }

  /// Lowercase canonical UUID. `UUID.uuidString` is already uppercase; the
  /// relay's contract and every test in this repo compare lowercase.
  static func newIdentifier() -> String {
    UUID().uuidString.lowercased()
  }

  /// The shape the relay accepts, and the same check the Kotlin store makes.
  ///
  /// Lowercase only: the store lowercases a stored value before asking, so that
  /// an id written by a host or an older SDK in uppercase is *normalised*
  /// rather than thrown away — regenerating over it would rotate a perfectly
  /// good installation. A value that is not a canonical UUID once lowercased
  /// came from somewhere else (an older SDK, a host that wrote the item itself,
  /// a device where the item was edited), and minting a new one is the honest
  /// answer: it is what Android does with a value that decrypts to something
  /// unexpected.
  static func isCanonicalInstallationId(_ value: String) -> Bool {
    value.range(of: Self.canonicalPattern, options: .regularExpression) != nil
  }

  func installationId() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    if let resolved { return resolved }

    let persisted: String?
    switch backing.loadInstallationId() {
    case .unavailable(let reason):
      // Read before write on purpose: an unreadable slot is not an empty one,
      // so nothing is generated, saved or cached here.
      throw InstallationIdError.unavailable(reason: reason)
    case .found(let stored):
      let normalised = stored.lowercased()
      persisted = Self.isCanonicalInstallationId(normalised) ? normalised : nil
    case .absent:
      persisted = nil
    }

    if let persisted {
      resolved = persisted
      return persisted
    }
    return try generateAndPersist()
  }

  /// Mints and persists, or throws.
  ///
  /// Cache and return the candidate only after storage confirms success.
  private func generateAndPersist() throws -> String {
    let id = generate()
    guard backing.saveInstallationId(id) else {
      logger.log("could not persist the installation id; reporting it as unavailable")
      throw InstallationIdError.unavailable(reason: "the installation id could not be persisted")
    }
    resolved = id
    return id
  }

  private static func makeDefaultBacking(logger: SocketLogger) -> InstallationIdBacking {
    #if canImport(Security)
    return KeychainInstallationIdBacking(logger: logger)
    #else
    // No Security framework (a non-Apple host running `swift test`): keep the
    // seam and the behaviour, lose the at-rest protection rather than failing
    // to build.
    return InMemoryInstallationIdBacking()
    #endif
  }

  /// Anchored, and written out rather than assembled from `UUID` so the check
  /// is the contract's shape and not this file's idea of one.
  private static let canonicalPattern =
    "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
}

// MARK: - Keychain slot

#if canImport(Security)
import Security

/// The Keychain item: service `com.sinch.push`, account `installation-id`.
///
/// The same accessibility class as the auth token
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`): the socket is
/// foreground-only, so there is no legitimate background read, and the
/// device-only, non-migrating class keeps the id off a restored device.
final class KeychainInstallationIdBacking: InstallationIdBacking {
  static let defaultService = "com.sinch.push"
  static let defaultAccount = "installation-id"

  private let service: String
  private let account: String
  private let logger: SocketLogger

  init(
    service: String = KeychainInstallationIdBacking.defaultService,
    account: String = KeychainInstallationIdBacking.defaultAccount,
    logger: SocketLogger = PrintSocketLogger()
  ) {
    self.service = service
    self.account = account
    self.logger = logger
  }

  func loadInstallationId() -> InstallationIdLoad {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    let outcome = Self.classify(status: status, data: item as? Data)
    switch outcome {
    case .unavailable:
      logger.log("installation id keychain read failed with status \(status)")
    case .found(let value) where value.isEmpty && status == errSecSuccess:
      logger.log("the installation id keychain item is not readable as text")
    default:
      break
    }
    return outcome
  }

  /// Turns a `SecItemCopyMatching` result into a load outcome. Pure, so the
  /// mapping can be tested without touching a Keychain.
  ///
  /// - `errSecSuccess` with UTF-8 data ⇒ ``InstallationIdLoad/found(_:)``.
  /// - `errSecSuccess` with missing or non-UTF-8 data ⇒ `.found("")`: the slot
  ///   is occupied but its bytes are not an id. It is deliberately *not*
  ///   `.unavailable` (a corrupt item never becomes readable, so reporting
  ///   failure would wedge the install forever); `""` is not a canonical id, so
  ///   the store treats it as corrupt, generates a replacement and overwrites it.
  /// - `errSecItemNotFound` ⇒ ``InstallationIdLoad/absent``: the only status
  ///   that means "there is no id here".
  /// - anything else — `errSecInteractionNotAllowed` before the first unlock
  ///   after boot, `errSecAuthFailed`, `errSecMissingEntitlement` (-34018), a
  ///   policy refusal — says nothing about whether this install already has an
  ///   id ⇒ ``InstallationIdLoad/unavailable(reason:)``.
  static func classify(status: OSStatus, data: Data?) -> InstallationIdLoad {
    switch status {
    case errSecSuccess:
      guard let data, let value = String(data: data, encoding: .utf8) else {
        return .found("")
      }
      return .found(value)
    case errSecItemNotFound:
      return .absent
    default:
      return .unavailable(reason: "the keychain returned status \(status)")
    }
  }

  @discardableResult
  func saveInstallationId(_ id: String) -> Bool {
    let attributes: [String: Any] = [
      kSecValueData as String: Data(id.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var insert = baseQuery
      insert.merge(attributes) { _, new in new }
      let addStatus = SecItemAdd(insert as CFDictionary, nil)
      if addStatus == errSecSuccess { return true }
      logger.log("installation id keychain write failed with status \(addStatus)")
      return false
    }
    if status != errSecSuccess {
      logger.log("installation id keychain update failed with status \(status)")
      return false
    }
    return true
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
#endif