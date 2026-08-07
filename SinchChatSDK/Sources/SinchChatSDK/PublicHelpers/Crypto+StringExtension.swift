import Foundation

public extension String {

    /// Returns the lowercase hex HMAC of this string using `algorithm` and `key`.
    ///
    /// - Important: This helper is retained for backwards compatibility. New
    ///   code should prefer ``SinchSDKIdentity/selfSignedWithAppSecret(userId:appSecret:)``
    ///   so the SDK computes the digest internally. Supported algorithms are
    ///   limited to those still mapped in ``CryptoAlgorithm``; calling with a
    ///   removed algorithm returns an empty string instead of crashing.
    @available(*, deprecated, message: "Use SinchSDKIdentity.selfSignedWithAppSecret — the SDK computes the HMAC internally.")
    func hmac(algorithm: CryptoAlgorithm, key: String) -> String {
        do {
            switch algorithm {
            case .SHA512:
                return try HMACSigner.sha512Hex(message: self, key: key)
            default:
                // Other algorithms were never used by the SDK; returning an
                // empty string avoids surfacing CommonCrypto APIs in the
                // public surface after the migration.
                return ""
            }
        } catch {
            return ""
        }
    }
    
    func convertToValidFileName() -> String {
   // https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-keys.html
           let invalidFileNameCharactersRegex = "[^a-zA-Z0-9_.!()*+']"
           let fullRange = startIndex..<endIndex
           let validName = replacingOccurrences(of: invalidFileNameCharactersRegex,
                                                with: "-",
                                                options: .regularExpression,
                                                range: fullRange)
           return validName
    }
   
}
