import XCTest
@testable import SinchChatSDK

final class KeychainAuthStorageTests: XCTestCase {

    private let testService = "com.sinch.chatsdk.tests.auth"
    private var storage: KeychainAuthStorage!

    override func setUp() {
        super.setUp()
        storage = KeychainAuthStorage(
            service: testService,
            account: "test-account"
        )
        storage.deleteToken()
    }

    override func tearDown() {
        storage?.deleteToken()
        storage = nil
        super.tearDown()
    }

    func test_saveThenRead_roundTripsToken() {
        let token = AuthModel(
            accessToken: "abc",
            sinchIdentity: .selfSigned(userId: "u", secret: "h"),
            clientID: "c",
            projectID: "p",
            configID: "cfg",
            region: .EU1
        )

        storage.save(token)

        let read = storage.read()
        XCTAssertEqual(read, token)
    }

    func test_read_empty_returnsNil() {
        XCTAssertNil(storage.read())
    }

    func test_deleteToken_removesPersistedEntry() {
        let token = AuthModel(
            accessToken: "abc",
            sinchIdentity: .anonymous,
            clientID: "c",
            projectID: "p",
            configID: "cfg",
            region: .EU1
        )
        storage.save(token)
        XCTAssertNotNil(storage.read())

        storage.deleteToken()

        XCTAssertNil(storage.read())
    }

    func test_accountKey_includesAllConfigFields() {
        let key = KeychainAuthStorage.accountKey(
            for: SinchSDKConfig.AppConfig(
                clientID: "client",
                projectID: "project",
                configID: "config",
                region: .EU1
            )
        )

        XCTAssertEqual(key, "client.project.config.EU1")
    }
}

final class AuthStorageMigratorTests: XCTestCase {

    private let testService = "com.sinch.chatsdk.tests.migrator"
    private let legacyKey = "sinch_sdk_accessToken"
    private var keychainStorage: KeychainAuthStorage!
    private var userDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "com.sinch.chatsdk.tests.migrator.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        keychainStorage = KeychainAuthStorage(
            service: testService,
            account: "migrator-test"
        )
        keychainStorage.deleteToken()
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        keychainStorage?.deleteToken()
        userDefaults?.removePersistentDomain(forName: suiteName)
        keychainStorage = nil
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_migratesLegacyUserDefaultsToken() {
        let token = AuthModel(
            accessToken: "legacy-token",
            sinchIdentity: .selfSigned(userId: "u", secret: "h"),
            clientID: "c",
            projectID: "p",
            configID: "cfg",
            region: .EU1
        )
        let data = try! JSONEncoder().encode(token)
        userDefaults.set(data, forKey: legacyKey)

        _ = AuthStorageMigrator(
            keychainStorage: keychainStorage,
            userDefaults: userDefaults
        )

        XCTAssertEqual(keychainStorage.read(), token)
        XCTAssertNil(userDefaults.data(forKey: legacyKey))
    }

    func test_noMigration_whenKeychainAlreadyPopulated() {
        let existing = AuthModel(
            accessToken: "existing",
            sinchIdentity: .anonymous,
            clientID: "c",
            projectID: "p",
            configID: "cfg",
            region: .EU1
        )
        keychainStorage.save(existing)

        let legacyToken = AuthModel(
            accessToken: "legacy",
            sinchIdentity: .anonymous,
            clientID: "c2",
            projectID: "p2",
            configID: "cfg2",
            region: .US1
        )
        let data = try! JSONEncoder().encode(legacyToken)
        userDefaults.set(data, forKey: legacyKey)

        _ = AuthStorageMigrator(
            keychainStorage: keychainStorage,
            userDefaults: userDefaults
        )

        // Legacy key untouched because Keychain already had data.
        XCTAssertEqual(keychainStorage.read(), existing)
        XCTAssertNotNil(userDefaults.data(forKey: legacyKey))
    }

    func test_noMigration_whenLegacyKeyAbsent() {
        _ = AuthStorageMigrator(
            keychainStorage: keychainStorage,
            userDefaults: userDefaults
        )

        XCTAssertNil(keychainStorage.read())
    }

    func test_migrator_isIdempotent() {
        let token = AuthModel(
            accessToken: "legacy-token",
            sinchIdentity: .selfSigned(userId: "u", secret: "h"),
            clientID: "c",
            projectID: "p",
            configID: "cfg",
            region: .EU1
        )
        let data = try! JSONEncoder().encode(token)
        userDefaults.set(data, forKey: legacyKey)

        _ = AuthStorageMigrator(
            keychainStorage: keychainStorage,
            userDefaults: userDefaults
        )

        XCTAssertNil(userDefaults.data(forKey: legacyKey))

        // Running the migrator a second time is a no-op.
        _ = AuthStorageMigrator(
            keychainStorage: keychainStorage,
            userDefaults: userDefaults
        )

        XCTAssertEqual(keychainStorage.read(), token)
    }
}