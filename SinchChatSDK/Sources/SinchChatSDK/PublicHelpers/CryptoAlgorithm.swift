import Foundation

/// Identifies a hash family supported by ``String/hmac(algorithm:key:)``.
///
/// Only `.SHA512` is exercised by the SDK today. Other cases remain for
/// backwards compatibility with any host app still calling the deprecated
/// extension method; they return an empty digest.
public enum CryptoAlgorithm {
    case MD5, SHA1, SHA224, SHA256, SHA384, SHA512
}