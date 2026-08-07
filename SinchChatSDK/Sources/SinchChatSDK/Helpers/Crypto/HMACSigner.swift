import Foundation
import CryptoKit

/// Errors raised by ``HMACSigner``.
enum CryptoError: Error, Sendable, Equatable {
    /// Either the message or the key was empty. CryptoKit accepts these, but
    /// the SDK relies on a non-empty hash to send a meaningful uuid_hash to
    /// the backend, so we surface this as an explicit failure.
    case emptyInput
}

/// CryptoKit-backed HMAC primitives used by the SDK.
///
/// This replaces the previous CommonCrypto-based `String.hmac(algorithm:key:)`
/// helper. It is `Sendable` and free of pointer manipulation, making it safe
/// under Swift 6 strict concurrency.
enum HMACSigner: Sendable {

    /// Computes HMAC-SHA512 over `message` using `key` and returns the
    /// lowercase hex encoding of the digest.
    ///
    /// - Throws: ``CryptoError/emptyInput`` when either argument is empty.
    static func sha512Hex(message: String, key: String) throws -> String {
        guard !message.isEmpty, !key.isEmpty else {
            throw CryptoError.emptyInput
        }

        let keyData = SymmetricKey(data: Data(key.utf8))
        let mac = HMAC<SHA512>.authenticationCode(
            for: Data(message.utf8),
            using: keyData
        )
        return Self.hexLowercase(Data(mac))
    }

    private static func hexLowercase(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}