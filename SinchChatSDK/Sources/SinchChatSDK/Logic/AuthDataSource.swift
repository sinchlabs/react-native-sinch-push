import Foundation
import GRPCCore

enum AuthDataSourceError: Error {
    case notLoggedIn
}

protocol AuthDataSource: AnyObject, Sendable {
    var isLoggedIn: Bool { get }
    var identityHashValue: String? { get }
    var currentConfigID: String { get }
    var currentAuthorization: AuthModel? { get }

    /// Async token generation. Preferred for new code paths.
    func generateToken(config: SinchSDKConfig.AppConfig, identity: SinchSDKIdentity) async throws -> AuthModel

    /// Backwards-compatible completion-handler entry point.
    func generateToken(config: SinchSDKConfig.AppConfig,
                       identity: SinchSDKIdentity,
                       completion: @escaping @Sendable (Result<AuthModel, AuthRepositoryError>) -> Void)

    /// Returns the access token used to authenticate outbound RPCs.
    func currentAccessToken() throws -> String

    func deleteToken()
}

final class DefaultAuthDataSource: AuthDataSource, @unchecked Sendable {

    private let storage: AuthStorage
    private let repository: AuthRepository

    var currentConfigID: String {
        repository.configID
    }

    var isLoggedIn: Bool {
        storage.read() != nil
    }

    var identityHashValue: String? {
        storage.read()?.identityHash
    }

    var currentAuthorization: AuthModel? {
        storage.read()
    }

    init(authRepository: AuthRepository, authStorage: AuthStorage) {
        self.storage = authStorage
        self.repository = authRepository
    }

    func currentAccessToken() throws -> String {
        guard let token = storage.read() else {
            throw AuthDataSourceError.notLoggedIn
        }
        return token.accessToken
    }

    // MARK: - Async

    func generateToken(config: SinchSDKConfig.AppConfig, identity: SinchSDKIdentity) async throws -> AuthModel {
        let storageKey = Self.storageKey(for: identity)

        if let token = storage.read(),
           token.clientID == config.clientID,
           token.projectID == config.projectID,
           token.region == config.region,
           token.sinchIdentity == storageKey {
            return token
        }

        let token: AuthModel
        switch identity {
        case .anonymous:
            token = try await repository.createAnonymouseToken()
        case .selfSigned, .selfSignedWithAppSecret:
            let (userId, resolvedHash) = try Self.resolvedCredentials(for: identity)
            token = try await repository.createSignedToken(userId: userId, secret: resolvedHash)
        }
        storage.save(token)
        return token
    }

    /// Resolves any ``SinchSDKIdentity`` to a `(userId, uuidHash)` pair that
    /// can be sent to `IssueTokenWithSignedUuid`. For
    /// ``SinchSDKIdentity/selfSignedWithAppSecret(userId:appSecret:)`` the
    /// HMAC-SHA512 digest is computed in-process so the raw app secret
    /// never leaves the caller.
    static func resolvedCredentials(for identity: SinchSDKIdentity) throws -> (userId: String, uuidHash: String) {
        switch identity {
        case .anonymous:
            throw AuthDataSourceError.notLoggedIn
        case let .selfSigned(userId, secret):
            return (userId, secret)
        case let .selfSignedWithAppSecret(userId, appSecret):
            let hash = try HMACSigner.sha512Hex(message: userId, key: appSecret)
            return (userId, hash)
        }
    }

    /// Stable key used to match a persisted `AuthModel` against the requested
    /// identity. For `.selfSignedWithAppSecret` we normalize to the resolved
    /// `.selfSigned` form so either input matches the same stored entry; for
    /// `.anonymous` the identity is itself a stable key.
    static func storageKey(for identity: SinchSDKIdentity) -> SinchSDKIdentity {
        if case let .selfSignedWithAppSecret(userId, appSecret) = identity,
           let hash = try? HMACSigner.sha512Hex(message: userId, key: appSecret) {
            return .selfSigned(userId: userId, secret: hash)
        }
        return identity
    }

    // MARK: - Completion handler compatibility

    func generateToken(config: SinchSDKConfig.AppConfig,
                       identity: SinchSDKIdentity,
                       completion: @escaping @Sendable (Result<AuthModel, AuthRepositoryError>) -> Void) {
        Task { [weak self] in
            guard let self else {
                completion(.failure(.cannotEstablishConnection))
                return
            }
            do {
                let token = try await self.generateToken(config: config, identity: identity)
                completion(.success(token))
            } catch let error as AuthRepositoryError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unknown(error)))
            }
        }
    }

    func deleteToken() {
        storage.deleteToken()
    }
}
