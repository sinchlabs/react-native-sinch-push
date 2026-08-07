import XCTest
@testable import SinchChatSDK

final class HMACSignerTests: XCTestCase {

    /// RFC 4231 test case 2: key = "Jefe", data = "what do ya want for nothing?".
    /// https://datatracker.ietf.org/doc/html/rfc4231#section-4.2
    func test_sha512Hex_matchesRFC4231TestCase2() throws {
        let expected = "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea250554"
                       + "9758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"

        let actual = try HMACSigner.sha512Hex(
            message: "what do ya want for nothing?",
            key: "Jefe"
        )

        XCTAssertEqual(actual, expected)
    }

    /// RFC 4231 test case 1: 20-byte key of 0x0b, data = "Hi There".
    /// https://datatracker.ietf.org/doc/html/rfc4231#section-4.1
    func test_sha512Hex_matchesRFC4231TestCase1() throws {
        let key = String(repeating: "\u{0B}", count: 20)
        let expected = "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cde"
                       + "daa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854"

        let actual = try HMACSigner.sha512Hex(
            message: "Hi There",
            key: key
        )

        XCTAssertEqual(actual, expected)
    }

    func test_sha512Hex_isLowercaseHex() throws {
        let digest = try HMACSigner.sha512Hex(message: "user-123", key: "app-secret")

        XCTAssertEqual(digest.count, 128)
        XCTAssertTrue(digest.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(digest, digest.lowercased())
    }

    func test_sha512Hex_isDeterministic() throws {
        let first = try HMACSigner.sha512Hex(message: "u", key: "k")
        let second = try HMACSigner.sha512Hex(message: "u", key: "k")

        XCTAssertEqual(first, second)
    }

    func test_sha512Hex_emptyMessage_throws() {
        XCTAssertThrowsError(try HMACSigner.sha512Hex(message: "", key: "k")) { error in
            XCTAssertEqual(error as? CryptoError, .emptyInput)
        }
    }

    func test_sha512Hex_emptyKey_throws() {
        XCTAssertThrowsError(try HMACSigner.sha512Hex(message: "m", key: "")) { error in
            XCTAssertEqual(error as? CryptoError, .emptyInput)
        }
    }
}