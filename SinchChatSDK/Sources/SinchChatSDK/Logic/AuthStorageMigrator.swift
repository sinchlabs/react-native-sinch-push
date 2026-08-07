import Foundation

/// Migrates a single legacy `UserDefaults` token into the supplied
/// ``KeychainAuthStorage`` and clears the legacy key.
///
/// The migrator runs idempotently on every `init`: if the Keychain already
/// has a token or the legacy entry is absent, it is a no-op.
struct AuthStorageMigrator {

    private static let legacyTokenKey = "sinch_sdk_accessToken"

    let keychainStorage: KeychainAuthStorage
    let userDefaults: UserDefaults
    let decoder = JSONDecoder()

    init(keychainStorage: KeychainAuthStorage,
         userDefaults: UserDefaults = .standard) {
        self.keychainStorage = keychainStorage
        self.userDefaults = userDefaults
        migrateIfNeeded()
    }

    /// Reads any existing legacy token, writes it into the Keychain, and
    /// deletes the UserDefaults entry. Safe to call multiple times.
    func migrateIfNeeded() {
        guard keychainStorage.read() == nil,
              let data = userDefaults.data(forKey: Self.legacyTokenKey),
              let token = try? decoder.decode(AuthModel.self, from: data) else {
            return
        }
        keychainStorage.save(token)
        userDefaults.removeObject(forKey: Self.legacyTokenKey)
        Logger.verbose("AuthStorageMigrator: migrated token from UserDefaults to Keychain")
    }
}