import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

enum PushRepositoryError: Error, Sendable {
    // Report this error to us.
    case internalError
}

protocol PushRepository: Sendable {
    /// Async push registration. Preferred for new code paths.
    func sendDeviceToken(token: String) async throws
    func unsubscribe(_ currentDeviceToken: String) async throws
    func replyToMessageWithTextChoice(choice: ChoiceText) async throws

    /// Backwards-compatible completion-handler entry points.
    func sendDeviceToken(token: String,
                         completion: @escaping @Sendable (Result<Void, Error>) -> Void)
    func unsubscribe(_ currentDeviceToken: String,
                     _ completion: @escaping @Sendable (Result<Void, Error>) -> Void)
    func replyToMessageWithTextChoice(choice: ChoiceText,
                                      completion: @escaping @Sendable (Result<Void, Error>) -> Void)
}

final class DefaultPushRepository: PushRepository, @unchecked Sendable {
    private let authDataSource: AuthDataSource
    private let client: PushAPIClient?

    init(region: Region, authDataSource: AuthDataSource, client: PushAPIClient? = nil) {
        self.authDataSource = authDataSource
        self.client = client ?? DefaultPushAPIClient(region: region)
    }

    // MARK: - Async API

    func sendDeviceToken(token: String) async throws {
        guard let client else {
            throw PushRepositoryError.internalError
        }

        let request = Sinch_Push_Sdk_V1beta1_SubscribeRequest.with {
            $0.token = token
            $0.config = authDataSource.currentConfigID
        }

        do {
            let signed = try authDataSource.signedRequest(request)
            _ = try await client.withClient { client in
                try await Sinch_Push_Sdk_V1beta1_SdkService.Client(wrapping: client).subscribe(
                    request: signed,
                    options: .standardCallOptions
                )
            }
        } catch _ as AuthDataSourceError {
            throw PushRepositoryError.internalError
        } catch {
            throw error
        }
    }

    func unsubscribe(_ currentDeviceToken: String) async throws {
        guard let client else {
            throw PushRepositoryError.internalError
        }

        let request = Sinch_Push_Sdk_V1beta1_UnsubscribeRequest.with {
            $0.config = authDataSource.currentConfigID
            $0.token = currentDeviceToken
        }

        do {
            let signed = try authDataSource.signedRequest(request)
            _ = try await client.withClient { client in
                try await Sinch_Push_Sdk_V1beta1_SdkService.Client(wrapping: client).unsubscribe(
                    request: signed,
                    options: .standardCallOptions
                )
            }
        } catch _ as AuthDataSourceError {
            throw PushRepositoryError.internalError
        } catch {
            // Preserve prior semantics: log the failure but treat as success.
            Logger.verbose("Unsubscribe error: \(error.localizedDescription)")
        }
    }

    func replyToMessageWithTextChoice(choice: ChoiceText) async throws {
        // The text-choice reply RPC is not currently active in the production
        // path; the original implementation immediately returned success.
        // Kept here for protocol completeness and future wiring.
    }

    // MARK: - Completion handler compatibility

    func sendDeviceToken(token: String,
                         completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendDeviceToken(token: token)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func unsubscribe(_ currentDeviceToken: String,
                     _ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.unsubscribe(currentDeviceToken)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func replyToMessageWithTextChoice(choice: ChoiceText,
                                      completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.replyToMessageWithTextChoice(choice: choice)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
