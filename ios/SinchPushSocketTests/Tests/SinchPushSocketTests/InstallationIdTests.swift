//  InstallationIdTests.swift — the per-install id.
//
//  The value is trivial; the properties relay routing depends on are not: it is
//  generated *once*, it is *stable* across launches, it is *normalised* rather
//  than replaced when a host stored it in another case, and concurrent first
//  calls agree on it. Those are the rules this file pins, and they are pinned
//  through the injected backing rather than a real Keychain: `swift test` runs
//  on a host where a test binary must not write to the login Keychain, and the
//  storage call is the part that cannot fail differently there.
//
//  The Keychain service and account constants are asserted below.

import XCTest

@testable import SinchPushSocket

final class InstallationIdTests: XCTestCase {

  /// The relay's format: lowercase canonical UUID. Checked with a regex rather
  /// than by re-deriving the string, so a test cannot pass on a value produced
  /// by the same code that produced the expectation.
  private static let uuidPattern = "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

  /// A generator that counts, which is how "generated once" is observable.
  private final class CountingGenerator {
    private let lock = NSLock()
    private var count = 0

    var callCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }

    func next() -> String {
      lock.lock()
      count += 1
      lock.unlock()
      return KeychainInstallationIdStore.newIdentifier()
    }
  }

  /// A backing that can fail the way a real one can, which is the half of the
  /// contract that `InMemoryInstallationIdBacking` deliberately cannot: a slot
  /// that cannot be read (a device locked before its first unlock answers
  /// `errSecInteractionNotAllowed`) and a slot that refuses writes.
  private final class FallibleInstallationIdBacking: InstallationIdBacking {
    private let lock = NSLock()
    private var stored: String?
    private var isReadable: Bool
    private var isWritable: Bool
    private var saves = 0

    init(id: String? = nil, readable: Bool = true, writable: Bool = true) {
      self.stored = id
      self.isReadable = readable
      self.isWritable = writable
    }

    var saveCount: Int {
      lock.lock()
      defer { lock.unlock() }
      return saves
    }

    var storedId: String? {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }

    func setReadable(_ readable: Bool) {
      lock.lock()
      defer { lock.unlock() }
      isReadable = readable
    }

    func setWritable(_ writable: Bool) {
      lock.lock()
      defer { lock.unlock() }
      isWritable = writable
    }

    func loadInstallationId() -> InstallationIdLoad {
      lock.lock()
      defer { lock.unlock() }
      guard isReadable else {
        return .unavailable(reason: "the keychain returned status -25308")
      }
      guard let stored else { return .absent }
      return .found(stored)
    }

    func saveInstallationId(_ id: String) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      saves += 1
      guard isWritable else { return false }
      stored = id
      return true
    }
  }

  private func isCanonicalUUID(_ value: String) -> Bool {
    value.range(of: Self.uuidPattern, options: .regularExpression) != nil
  }

  // MARK: - Format

  func test_RN41_theGeneratedIdIsALowercaseCanonicalUUID() throws {
    let store = KeychainInstallationIdStore(
      backing: InMemoryInstallationIdBacking(), logger: SilentSocketLogger())

    let id = try store.installationId()

    XCTAssertTrue(
      isCanonicalUUID(id),
      "\(id) is not a lowercase canonical UUID (8-4-4-4-12)")
    // The relay compares this string, and `UUID.uuidString` is uppercase: the
    // lowercasing is the difference between a match and a mismatch.
    XCTAssertEqual(id, id.lowercased())
  }

  func test_RN41_aPreExistingIdIsReturnedUnchanged() throws {
    // A valid persisted ID is reused.
    let persisted = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
    let generator = CountingGenerator()
    let store = KeychainInstallationIdStore(
      backing: InMemoryInstallationIdBacking(id: persisted),
      generate: generator.next,
      logger: SilentSocketLogger())

    XCTAssertEqual(try store.installationId(), persisted)
    XCTAssertEqual(try store.installationId(), persisted)
    XCTAssertEqual(generator.callCount, 0, "a persisted id was regenerated")
  }

  func test_RN41_anEmptyStoredValueCountsAsNoValue() throws {
    // A half-written item is not an installation id. Minting a fresh one is the
    // only honest answer; returning "" would be an id the relay cannot route.
    let generator = CountingGenerator()
    let store = KeychainInstallationIdStore(
      backing: InMemoryInstallationIdBacking(id: ""),
      generate: generator.next,
      logger: SilentSocketLogger())

    XCTAssertTrue(isCanonicalUUID(try store.installationId()))
    XCTAssertEqual(generator.callCount, 1)
  }

  func test_RN41_aPersistedValueThatIsNotAUuidIsReplaced() throws {
    // Same rule as the Kotlin store's "decrypts to something unexpected": a value
    // this code did not write, or a shape the relay would reject, is treated as
    // absent rather than sent.
    for garbage in ["not-a-uuid", "3f2504e04f8941d39a0c0305e82c3301", "3f2504e0-4f89-41d3-9a0c"] {
      let generator = CountingGenerator()
      let backing = InMemoryInstallationIdBacking(id: garbage)
      let store = KeychainInstallationIdStore(
        backing: backing, generate: generator.next, logger: SilentSocketLogger())

      let id = try store.installationId()

      XCTAssertTrue(isCanonicalUUID(id), "\(garbage) was used as an installation id")
      XCTAssertEqual(generator.callCount, 1)
      XCTAssertEqual(backing.storedId, id, "the old value was not overwritten")
    }
  }

  func test_RN41_aPersistedIdInAnotherCaseIsNormalisedAndKept() throws {
    // An uppercase UUID is the *same* id — `UUID.uuidString` produces exactly
    // that, and a host that wrote the Keychain item itself would too. Replacing
    // it would rotate a working installation over a formatting difference, so it
    // is lowercased and kept.
    let persisted = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
    let generator = CountingGenerator()
    let store = KeychainInstallationIdStore(
      backing: InMemoryInstallationIdBacking(id: persisted),
      generate: generator.next,
      logger: SilentSocketLogger())

    let id = try store.installationId()

    XCTAssertEqual(id, persisted.lowercased())
    XCTAssertTrue(isCanonicalUUID(id))
    XCTAssertEqual(generator.callCount, 0, "an uppercase id was thrown away")
    XCTAssertEqual(try store.installationId(), id)
  }

  // MARK: - Generated once, stable

  func test_RN41_theIdIsGeneratedOnceAndThenReused() throws {
    let generator = CountingGenerator()
    let backing = InMemoryInstallationIdBacking()
    let store = KeychainInstallationIdStore(
      backing: backing, generate: generator.next, logger: SilentSocketLogger())

    let first = try store.installationId()
    let second = try store.installationId()

    XCTAssertEqual(first, second)
    XCTAssertEqual(generator.callCount, 1)
    // And it really is persisted rather than cached in the instance, which is
    // what makes the next test meaningful.
    XCTAssertEqual(backing.storedId, first)
  }

  func test_RN41_theIdIsStableAcrossStoreInstancesOverTheSameBacking() throws {
    // What a relaunch is: a brand-new store over storage the previous process
    // left behind. No rotation happens at any point in between.
    let backing = InMemoryInstallationIdBacking()
    let before = KeychainInstallationIdStore(backing: backing, logger: SilentSocketLogger())
    let id = try before.installationId()

    let after = KeychainInstallationIdStore(backing: backing, logger: SilentSocketLogger())
    XCTAssertEqual(try after.installationId(), id)

    // A token rotation is the other thing that must not touch it: nothing here
    // takes an identity, but the store must not be reachable from one either.
    // Asserted structurally — the value comes from storage alone.
    let third = KeychainInstallationIdStore(backing: backing, logger: SilentSocketLogger())
    XCTAssertEqual(try third.installationId(), id)
  }

  func test_RN41_concurrentFirstCallsReturnOneId() throws {
    let generator = CountingGenerator()
    let backing = InMemoryInstallationIdBacking()
    let store = KeychainInstallationIdStore(
      backing: backing, generate: generator.next, logger: SilentSocketLogger())

    // No barrier on the first call, so the threads genuinely overlap: without the
    // load-or-generate critical section two of them mint an id and the loser
    // overwrites the winner, which is two installations from one device.
    let lock = NSLock()
    var seen: [String] = []
    let failures = Counter()
    DispatchQueue.concurrentPerform(iterations: 64) { _ in
      do {
        let id = try store.installationId()
        lock.lock()
        seen.append(id)
        lock.unlock()
      } catch {
        failures.increment()
      }
    }

    XCTAssertEqual(failures.value, 0, "a concurrent call failed on a working slot")
    XCTAssertEqual(Set(seen).count, 1, "concurrent first calls disagreed: \(Set(seen))")
    XCTAssertEqual(generator.callCount, 1, "an id was generated more than once")
    XCTAssertEqual(backing.storedId, seen.first)
  }

  // MARK: - An unreadable slot is not an empty one

  func test_RN41_anUnreadableSlotReportsFailureAndTouchesNothing() throws {
    // Before the first unlock after boot the Keychain answers
    // errSecInteractionNotAllowed. There is an id in there; we simply cannot see
    // it. Minting a replacement would be the worst possible answer — a second id
    // for one install, and the real one overwritten.
    let persisted = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
    let generator = CountingGenerator()
    let backing = FallibleInstallationIdBacking(id: persisted, readable: false)
    let store = KeychainInstallationIdStore(
      backing: backing, generate: generator.next, logger: SilentSocketLogger())

    XCTAssertThrowsError(try store.installationId()) { error in
      guard case InstallationIdError.unavailable = error else {
        return XCTFail("expected an unavailable failure, got \(error)")
      }
    }
    XCTAssertEqual(generator.callCount, 0, "an id was minted while the slot was unreadable")
    XCTAssertEqual(backing.saveCount, 0, "the slot was written while it was unreadable")
    XCTAssertEqual(backing.storedId, persisted)

    // Nothing was cached, so the first call that can read returns what is really
    // there rather than this process's idea of it.
    backing.setReadable(true)
    XCTAssertEqual(try store.installationId(), persisted)
    XCTAssertEqual(generator.callCount, 0, "the unreadable read was cached")
  }

  func test_RN41_anIdThatCouldNotBePersistedIsNotHandedOut() throws {
    // A generated-but-unsaved id is the worst outcome: this process would send
    // one id and the next launch another. So the failure is reported, and
    // nothing is cached — a later successful call still persists a fresh id.
    let generator = CountingGenerator()
    let backing = FallibleInstallationIdBacking(readable: true, writable: false)
    let store = KeychainInstallationIdStore(
      backing: backing, generate: generator.next, logger: SilentSocketLogger())

    XCTAssertThrowsError(try store.installationId()) { error in
      guard case InstallationIdError.unavailable = error else {
        return XCTFail("expected an unavailable failure, got \(error)")
      }
    }
    XCTAssertEqual(generator.callCount, 1, "generation should have been attempted")
    XCTAssertNil(backing.storedId)

    // Storage works again: a second id is minted, persisted and served.
    backing.setWritable(true)
    let id = try store.installationId()

    XCTAssertTrue(isCanonicalUUID(id))
    XCTAssertEqual(backing.storedId, id)
    XCTAssertEqual(try store.installationId(), id)
    XCTAssertEqual(generator.callCount, 2, "the failed attempt was served from the cache")
  }

  // MARK: - The @objc surface

  func test_RN41_theFacadeReportsTheStoredIdWithNoClientRunning() throws {
    let backing = InMemoryInstallationIdBacking()
    let facade = SinchPushSocketFacade(
      store: FakeSocketStateStore(),
      tokenStore: InMemoryAuthTokenStore(),
      installationIdStore: KeychainInstallationIdStore(
        backing: backing, logger: SilentSocketLogger()),
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger())

    // No `start(config:)` and no socket: the id describes the install, not a
    // session, so it is available before anything connects and unchanged after.
    let before = try XCTUnwrap(facade.installationId())
    XCTAssertTrue(isCanonicalUUID(before))
    XCTAssertEqual(facade.stateDictionary()["status"] as? String, "idle")

    // A "restart" — a second facade over the same storage — keeps it.
    let relaunched = SinchPushSocketFacade(
      store: FakeSocketStateStore(),
      tokenStore: InMemoryAuthTokenStore(),
      installationIdStore: KeychainInstallationIdStore(
        backing: backing, logger: SilentSocketLogger()),
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger())
    XCTAssertEqual(relaunched.installationId(), before)
  }

  func test_RN41_theFacadeReportsNoIdRatherThanOneItInvented() {
    // `nil` is what `SinchPush.mm` turns into E_INSTALLATION_ID_UNAVAILABLE: the
    // host is told there is no id yet instead of being handed one that would be
    // a different installation tomorrow.
    let generator = CountingGenerator()
    let facade = SinchPushSocketFacade(
      store: FakeSocketStateStore(),
      tokenStore: InMemoryAuthTokenStore(),
      installationIdStore: KeychainInstallationIdStore(
        backing: FallibleInstallationIdBacking(readable: false),
        generate: generator.next,
        logger: SilentSocketLogger()),
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger())

    XCTAssertNil(facade.installationId())
    XCTAssertEqual(generator.callCount, 0)
  }

  // MARK: - The Keychain item

  func test_RN41_theKeychainItemIsTheOneTheRelayContractNames() {
    #if canImport(Security)
    // Service/account are a wire-adjacent contract: a host that has both this
    // SDK's item and its own tooling reading the Keychain has to agree on them.
    XCTAssertEqual(KeychainInstallationIdBacking.defaultService, "com.sinch.push")
    XCTAssertEqual(KeychainInstallationIdBacking.defaultAccount, "installation-id")
    #else
    XCTFail("expected the Security framework on this host")
    #endif
  }

  func test_RN41_theFacadesDefaultStoreIsTheSharedKeychainStore() {
    // One instance per process: the generate-once critical section has to cover
    // every facade, not each facade's own store.
    let facade = SinchPushSocketFacade(
      store: FakeSocketStateStore(),
      tokenStore: InMemoryAuthTokenStore(),
      presenter: FakeNotificationPresenter(),
      logger: SilentSocketLogger())
    let mirror = Mirror(reflecting: facade)
    let store = mirror.children.first { $0.label == "installationIdStore" }?.value
    XCTAssertTrue(
      (store as AnyObject?) === KeychainInstallationIdStore.shared,
      "the facade's default installation id store is not KeychainInstallationIdStore.shared")
  }

  // MARK: - Keychain status mapping

  #if canImport(Security)
  func test_RN41_classifyMapsKeychainStatusesToLoadOutcomes() throws {
    let id = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

    guard case .found(let value) = KeychainInstallationIdBacking.classify(
      status: errSecSuccess, data: Data(id.utf8))
    else { return XCTFail("success + UTF-8 should be found") }
    XCTAssertEqual(value, id)

    // Occupied but not text: reported as an unusable value (not unavailable), so
    // the store regenerates over it instead of failing forever.
    guard case .found(let corrupt) = KeychainInstallationIdBacking.classify(
      status: errSecSuccess, data: Data([0xFF, 0xFE, 0xFD]))
    else { return XCTFail("success + non-UTF-8 should be found-but-corrupt") }
    XCTAssertFalse(KeychainInstallationIdStore.isCanonicalInstallationId(corrupt))
    let backing = InMemoryInstallationIdBacking(id: corrupt)
    let store = KeychainInstallationIdStore(backing: backing, logger: SilentSocketLogger())
    XCTAssertTrue(isCanonicalUUID(try store.installationId()))

    guard case .absent = KeychainInstallationIdBacking.classify(
      status: errSecItemNotFound, data: nil)
    else { return XCTFail("errSecItemNotFound should be absent") }

    // errSecInteractionNotAllowed (-25308): locked before first unlock.
    // -34018: errSecMissingEntitlement, e.g. an unsigned test host or app.
    for status in [errSecInteractionNotAllowed, -34018] {
      guard case .unavailable = KeychainInstallationIdBacking.classify(status: status, data: nil)
      else { return XCTFail("status \(status) should be unavailable") }
    }
  }
  #endif
}

/// A thread-safe counter, for asserting inside `DispatchQueue.concurrentPerform`
/// where an `XCTAssert` would be reported against the wrong thread.
private final class Counter {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}