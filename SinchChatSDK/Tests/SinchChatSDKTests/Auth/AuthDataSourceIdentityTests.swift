import XCTest
@testable import SinchChatSDK

final class AuthDataSourceIdentityTests: XCTestCase {

    func test_resolvedCredentials_selfSignedWithAppSecret_computesHMAC() throws {
        let identity = SinchSDKIdentity.selfSignedWithAppSecret(
            userId: "user-1",
            appSecret: "secret"
        )

        let (userId, hash) = try DefaultAuthDataSource.resolvedCredentials(for: identity)

        XCTAssertEqual(userId, "user-1")
        XCTAssertEqual(
            hash,
            try HMACSigner.sha512Hex(message: "user-1", key: "secret")
        )
    }

    func test_resolvedCredentials_selfSignedWithAppSecret_emptyAppSecret_throws() {
        let identity = SinchSDKIdentity.selfSignedWithAppSecret(
            userId: "user-1",
            appSecret: ""
        )

        XCTAssertThrowsError(try DefaultAuthDataSource.resolvedCredentials(for: identity)) { error in
            XCTAssertEqual(error as? CryptoError, .emptyInput)
        }
    }

    func test_resolvedCredentials_selfSigned_passesThroughHash() throws {
        let identity = SinchSDKIdentity.selfSigned(userId: "user-1", secret: "precomputed-hash")

        let (userId, hash) = try DefaultAuthDataSource.resolvedCredentials(for: identity)

        XCTAssertEqual(userId, "user-1")
        XCTAssertEqual(hash, "precomputed-hash")
    }

    func test_resolvedCredentials_anonymous_throws() {
        XCTAssertThrowsError(
            try DefaultAuthDataSource.resolvedCredentials(for: .anonymous)
        )
    }

    func test_generateToken_persistsHash_onlyNotRawAppSecret() async throws {
        let storage = InMemoryAuthStorage()
        let repository = RecordingAuthRepository()

        let dataSource = DefaultAuthDataSource(
            authRepository: repository,
            authStorage: storage
        )

        let config = SinchSDKConfig.AppConfig(
            clientID: "c",
            projectID: "p",
            configID: "cfg",
            region: .EU1
        )

        _ = try await dataSource.generateToken(
            config: config,
            identity: .selfSignedWithAppSecret(userId: "user-1", appSecret: "raw-app-secret")
        )

        let stored = try XCTUnwrap(storage.lastSaved)
        if case let .selfSigned(userId, secret) = stored.sinchIdentity {
            XCTAssertEqual(userId, "user-1")
            XCTAssertEqual(secret, try HMACSigner.sha512Hex(message: "user-1", key: "raw-app-secret"))
            XCTAssertFalse(secret.contains("raw-app-secret"))
        } else {
            XCTFail("Expected .selfSigned persistence, got \(stored.sinchIdentity)")
        }
    }

    /// Regression: `.anonymous` must not be routed through `resolvedCredentials`
    /// (which throws) — it should resolve to the anonymous token flow directly.
    func test_generateToken_anonymous_doesNotResolveCredentials() async throws {
        let storage = InMemoryAuthStorage()
        let repository = RecordingAuthRepository()

        let dataSource = DefaultAuthDataSource(
            authRepository: repository,
            authStorage: storage
        )

        let config = SinchSDKConfig.AppConfig(
            clientID: "c",
            projectID: "p",
            configID: "cfg",
            region: .EU1
        )

        let token = try await dataSource.generateToken(
            config: config,
            identity: .anonymous
        )

        XCTAssertEqual(token.accessToken, "anonymous-token")
        XCTAssertNil(repository.lastSignedRequest)
        XCTAssertEqual(storage.lastSaved?.sinchIdentity, .anonymous)
    }

    func test_storageKey_selfSignedWithAppSecret_normalizes() throws {
        let identity = SinchSDKIdentity.selfSignedWithAppSecret(userId: "user-1", appSecret: "secret")
        let key = DefaultAuthDataSource.storageKey(for: identity)

        if case let .selfSigned(userId, secret) = key {
            XCTAssertEqual(userId, "user-1")
            XCTAssertEqual(secret, try HMACSigner.sha512Hex(message: "user-1", key: "secret"))
        } else {
            XCTFail("Expected normalized .selfSigned key, got \(key)")
        }
    }

    func test_storageKey_anonymous_passesThrough() {
        XCTAssertEqual(DefaultAuthDataSource.storageKey(for: .anonymous), .anonymous)
    }
}

// MARK: - Test doubles

private final class InMemoryAuthStorage: AuthStorage, @unchecked Sendable {
    var lastSaved: AuthModel?

    func read() -> AuthModel? { lastSaved }
    func save(_ token: AuthModel) { lastSaved = token }
    func deleteToken() { lastSaved = nil }
}

private final class RecordingAuthRepository: AuthRepository, @unchecked Sendable {
    var configID: String { "cfg" }
    var lastSignedRequest: (userId: String, secret: String)?

    func createAnonymouseToken() async throws -> AuthModel {
        AuthModel(
            accessToken: "anonymous-token",
            sinchIdentity: .anonymous,
            clientID: "c",
            projectID: "p",
            configID: "cfg",
            region: .EU1
        )
    }

    func createSignedToken(userId: String, secret: String) async throws -> AuthModel {
        lastSignedRequest = (userId, secret)
        return AuthModel(
            accessToken: "signed-token",
            sinchIdentity: .selfSigned(userId: userId, secret: secret),
            clientID: "c",
            projectID: "p",
            configID: "cfg",
            region: .EU1
        )
    }

    func createAnonymouseToken(completion: @escaping @Sendable (Result<AuthModel, AuthRepositoryError>) -> Void) {
        Task {
            do {
                let token = try await createAnonymouseToken()
                completion(.success(token))
            } catch {
                completion(.failure(.unknown(error)))
            }
        }
    }

    func createSignedToken(userId: String, secret: String,
                           completion: @escaping @Sendable (Result<AuthModel, AuthRepositoryError>) -> Void) {
        Task {
            do {
                let token = try await createSignedToken(userId: userId, secret: secret)
                completion(.success(token))
            } catch {
                completion(.failure(.unknown(error)))
            }
        }
    }
}