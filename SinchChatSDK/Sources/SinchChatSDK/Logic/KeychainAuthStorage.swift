import Foundation
import Security

/// `AuthStorage` implementation backed by the iOS Keychain.
///
/// Tokens are stored as `kSecClassGenericPassword` items keyed by SDK config
/// (client + project + config + region). Items use
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so they are readable
/// for background fetches but never leave the device and never sync to iCloud.
final class KeychainAuthStorage: AuthStorage, @unchecked Sendable {

    private let service: String
    private let account: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    init(config: SinchSDKConfig.AppConfig) {
        self.service = KeychainAuthStorage.defaultService
        self.account = KeychainAuthStorage.accountKey(for: config)
    }

    /// Designated initializer used by tests so a dedicated keychain service
    /// can be supplied to avoid touching the developer's keychain.
    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    // MARK: - AuthStorage

    func read() -> AuthModel? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = readData() else { return nil }
        return try? decoder.decode(AuthModel.self, from: data)
    }

    func save(_ token: AuthModel) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? encoder.encode(token) else { return }
        writeData(data)
    }

    func deleteToken() {
        lock.lock()
        defer { lock.unlock() }
        let query = baseQuery()
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keychain primitives

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func readData() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func writeData(_ data: Data) {
        let writeAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(baseQuery() as CFDictionary, writeAttributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery.merge(writeAttributes) { _, new in new }
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    // MARK: - Helpers

    static let defaultService = "com.sinch.chatsdk.auth"

    static func accountKey(for config: SinchSDKConfig.AppConfig) -> String {
        let regionComponent: String
        switch config.region {
        case .EU1: regionComponent = "EU1"
        case .US1: regionComponent = "US1"
        case .custom(let host, _, _, _): regionComponent = "custom.\(host)"
        }
        return [config.clientID, config.projectID, config.configID, regionComponent]
            .joined(separator: ".")
    }
}