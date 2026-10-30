//  KeychainAuthTokenStore.swift — the JWT, in the Keychain (SB-18).
//
//  The credential is the one value the client persists that must not end up in a
//  plist: `UserDefaultsSocketStateStore` writes plain JSON, and a JWT in
//  `UserDefaults` is readable by anything with the app container. So the token
//  has its own store and this is the only file that holds one.
//
//  The mirror-image of the Kotlin store, which writes the token into plain
//  `SharedPreferences` and is recorded as a deviation in
//  docs/socket-behaviour-spec.md §8.

import Foundation

#if canImport(Security)
import Security

/// Keychain-backed storage for the auth token.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the deliberate choice
/// rather than `WhenUnlocked`: the socket is foreground-only (SB-56) and APNs is
/// the background channel, so there is no legitimate background wake that needs
/// the token, and the non-migrating, device-only class keeps a JWT out of an
/// iCloud or iTunes backup.
final class KeychainAuthTokenStore: AuthTokenStore {
  private let service: String
  private let account: String
  private let logger: SocketLogger

  init(
    service: String = "com.sinch.push.socket",
    account: String = "auth-token",
    logger: SocketLogger = PrintSocketLogger()
  ) {
    self.service = service
    self.account = account
    self.logger = logger
  }

  func loadToken() -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
      // A missing item (errSecItemNotFound) is the normal first-launch case;
      // anything else is worth a diagnostic but must not throw at the call site.
      if status != errSecItemNotFound {
        logger.log("keychain read failed with status \(status)")
      }
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  func saveToken(_ token: String) {
    let data = Data(token.utf8)
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var insert = baseQuery
      insert.merge(attributes) { _, new in new }
      let addStatus = SecItemAdd(insert as CFDictionary, nil)
      if addStatus != errSecSuccess {
        logger.log("keychain write failed with status \(addStatus)")
      }
    } else if status != errSecSuccess {
      logger.log("keychain update failed with status \(status)")
    }
  }

  func clearToken() {
    SecItemDelete(baseQuery as CFDictionary)
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

#else

// No Security framework: keep the seam, keep the behaviour, lose the at-rest
// protection rather than failing to build. Only reachable on a host that has
// neither, which for this package means a non-Apple platform.
final class SocketAuthTokenStore: AuthTokenStore {
  private let backing = InMemoryAuthTokenStore()
  func loadToken() -> String? { backing.loadToken() }
  func saveToken(_ token: String) { backing.saveToken(token) }
  func clearToken() { backing.clearToken() }
}

#endif

/// The name the facade defaults to.
#if canImport(Security)
typealias SocketAuthTokenStore = KeychainAuthTokenStore
#endif