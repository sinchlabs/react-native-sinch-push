import Foundation

protocol AuthStorage: Sendable {
    func read() -> AuthModel?
    func save(_ token: AuthModel)
    func deleteToken()
}

/// Legacy `UserDefaults`-backed storage kept for tests that need to
/// exercise the migration path. Production paths use ``KeychainAuthStorage``.
final class DefaultAuthStorage: AuthStorage, @unchecked Sendable {
    private let tokenKey = "sinch_sdk_accessToken"
    private let userDefaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func read() -> AuthModel? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = userDefaults.data(forKey: tokenKey) else {
            return nil
        }
        return try? decoder.decode(AuthModel.self, from: data)
    }

    func save(_ token: AuthModel) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? encoder.encode(token) else {
            return
        }
        userDefaults.set(data, forKey: tokenKey)
    }

    func deleteToken() {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.removeObject(forKey: tokenKey)
    }
}