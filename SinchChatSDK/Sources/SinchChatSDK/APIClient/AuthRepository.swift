import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

enum AuthRepositoryError: Error, Sendable {
    case unknown(any Error)
    // Cannot create api client, report it to us, thank you!
    case internalError(tracingID: String)
    case cannotEstablishConnection
}

public typealias AccessToken = String

public struct AuthModel: Codable, Equatable, Sendable {
    public let accessToken: AccessToken
    public let sinchIdentity: SinchSDKIdentity
    public let clientID: String
    public let projectID: String
    public let configID: String
    public let region: Region

    public var identityHash: String? {
        guard let data = try? JSONEncoder().encode(self) else {
            return nil
        }
        return data.base64EncodedString()
    }

    public func getUserID() -> String? {
        do {
            let payload = try JWTDecoder.decode(jwtToken: accessToken)
            return payload["uuid"] as? String

        } catch {
            return nil

        }
    }

    public static func == (lhs: AuthModel, rhs: AuthModel) -> Bool {
        lhs.accessToken == rhs.accessToken &&
        lhs.identityHash == rhs.identityHash &&
        compareWithoutAccessToken(lhs: lhs, rhs: rhs)
    }

    public static func compareWithoutAccessToken(lhs: AuthModel, rhs: AuthModel) -> Bool {
        return lhs.clientID == rhs.clientID &&
        lhs.configID == rhs.configID &&
        lhs.projectID == rhs.projectID &&
        lhs.region == rhs.region &&
        lhs.getUserID() == rhs.getUserID()
    }
}

protocol AuthRepository: Sendable {
    var configID: String { get }

    /// Async token issuance. Preferred for new code paths.
    func createAnonymouseToken() async throws -> AuthModel
    func createSignedToken(userId: String, secret: String) async throws -> AuthModel

    /// Backwards-compatible completion-handler entry points. Implemented in
    /// terms of the async methods above.
    func createAnonymouseToken(completion: @escaping @Sendable (Result<AuthModel, AuthRepositoryError>) -> Void)
    func createSignedToken(userId: String, secret: String,
                           completion: @escaping @Sendable (Result<AuthModel, AuthRepositoryError>) -> Void)
}

final class DefaultAuthRepository: AuthRepository, @unchecked Sendable {
    private let config: SinchSDKConfig.AppConfig
    private let client: Default2APIClient

    var configID: String {
        config.configID
    }

    init(config: SinchSDKConfig.AppConfig, client: Default2APIClient) {
        self.config = config
        self.client = client
    }

    deinit {}
    
    let callOptions: GRPCCore.CallOptions = {
        var options = GRPCCore.CallOptions.standardCallOptions
        options.timeout = .seconds(5)
        return options
    }()

    // MARK: - Async API

    func createAnonymouseToken() async throws -> AuthModel {
        let request = Sinch_Chat_Sdk_V1alpha2_IssueAnonymousTokenRequest.with {
            $0.clientID = config.clientID
            $0.projectID = config.projectID
        }

        do {
            let response = try await client.withClient { client in
                let sdk = Sinch_Chat_Sdk_V1alpha2_SdkService.Client(wrapping: client)
                return try await sdk.issueAnonymousToken(
                    request: SinchChatSDK.standardRequest(for: request),
                    options: callOptions
                )
            }
            return AuthModel(
                accessToken: response.accessToken,
                sinchIdentity: .anonymous,
                clientID: config.clientID,
                projectID: config.projectID,
                configID: config.configID,
                region: config.region
            )
        } catch let status as RPCError {
            throw mapStatus(status)
        } catch {
            throw AuthRepositoryError.unknown(error)
        }
    }

    func createSignedToken(userId: String, secret: String) async throws -> AuthModel {
        var request = Sinch_Chat_Sdk_V1alpha2_IssueTokenWithSignedUuidRequest.with {
            $0.clientID = config.clientID
            $0.projectID = config.projectID
            $0.uuid = userId
            $0.uuidHash = secret
        }
        

        do {
            let response = try await client.withClient { client in
                let sdk = Sinch_Chat_Sdk_V1alpha2_SdkService.Client(wrapping: client)
                return try await sdk.issueTokenWithSignedUuid(
                    request: SinchChatSDK.standardRequest(for: request),
                    options: callOptions
                )
            }
            return AuthModel(
                accessToken: response.accessToken,
                sinchIdentity: .selfSigned(userId: userId, secret: secret),
                clientID: config.clientID,
                projectID: config.projectID,
                configID: config.configID,
                region: config.region
            )
        } catch let status as RPCError {
            throw mapStatus(status)
        } catch {
            throw AuthRepositoryError.unknown(error)
        }
    }

    // MARK: - Completion-handler API (compatibility layer)

    func createAnonymouseToken(completion: @escaping @Sendable (Result<AuthModel, AuthRepositoryError>) -> Void) {
        Task { [config] in
            do {
                let token = try await createAnonymouseToken()
                completion(.success(token))
            } catch let error as AuthRepositoryError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unknown(error)))
            }
        }
    }

    func createSignedToken(userId: String, secret: String,
                           completion: @escaping @Sendable (Result<AuthModel, AuthRepositoryError>) -> Void) {
        Task { [config] in
            do {
                let token = try await createSignedToken(userId: userId, secret: secret)
                completion(.success(token))
            } catch let error as AuthRepositoryError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unknown(error)))
            }
        }
    }

    // MARK: - Private

    private func mapStatus(_ status: RPCError) -> AuthRepositoryError {
        switch status.code {
        case .deadlineExceeded:
            return .internalError(tracingID: status.message)
        case .unauthenticated, .internalError, .unknown, .dataLoss, .failedPrecondition:
            return .internalError(tracingID: status.message)
        default:
            return .unknown(status)
        }
    }
}

extension AccessToken {

    var userID: String? {
        guard let decodedJWT = try? decode(jwtToken: self) else {
            return nil
        }
        return decodedJWT["uuid"] as? String
    }

    private func decode(jwtToken jwt: String) throws -> [String: Any] {

        enum DecodeErrors: Error {
            case badToken
            case other
        }

        func base64Decode(_ base64: String) throws -> Data {
            let padded = base64.padding(toLength: ((base64.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
            guard let decoded = Data(base64Encoded: padded) else {
                throw DecodeErrors.badToken
            }
            return decoded
        }

        func decodeJWTPart(_ value: String) throws -> [String: Any] {
            let bodyData = try base64Decode(value)
            let json = try JSONSerialization.jsonObject(with: bodyData, options: [])
            guard let payload = json as? [String: Any] else {
                throw DecodeErrors.other
            }
            return payload
        }

        let segments = jwt.components(separatedBy: ".")
        if segments.count != 3 {
            return [:]
        }
        return try decodeJWTPart(segments[1])
    }

}
