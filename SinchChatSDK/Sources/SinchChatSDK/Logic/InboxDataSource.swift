import Foundation
import Synchronization
import GRPCCore

enum InboxDataSourceError: Error, Sendable {
    case unknown(any Error)
    case notLoggedIn
    case noMoreChannels
    case subscriptionIsAlreadyStarted
}

protocol InboxDataSourceDelegate: AnyObject, Sendable {
    func subscriptionError()
}

protocol InboxDataSource: AnyObject, Sendable {
    var delegate: InboxDataSourceDelegate? { get set }

    /// Async page fetch. Preferred for new code paths.
    func getChannels() async throws -> [Sinch_Chat_Sdk_V1alpha2_Channel]
    /// Async subscribe (server stream). Returns an `AsyncThrowingStream` that
    /// yields channels for the lifetime of the subscription.
    func subscribeForChannels() -> AsyncThrowingStream<Sinch_Chat_Sdk_V1alpha2_Channel, Error>

    /// Backwards-compatible completion-handler entry points.
    func getChannels(completion: @escaping @Sendable (Result<[Sinch_Chat_Sdk_V1alpha2_Channel], InboxDataSourceError>) -> Void)
    func subscribeForChannels(completion: @escaping @Sendable (Result<Sinch_Chat_Sdk_V1alpha2_Channel, InboxDataSourceError>) -> Void)

    func cancelSubscription()
    func closeChannel()
    func startChannel()
    func cancelCalls()
    func isSubscribed() -> Bool
    func isFirstPage() -> Bool
    func resetPagination()
}

private struct InboxState: Sendable {
    var firstPage: Bool = true
    var nextPageToken: String?
    var subscriptionTask: Task<Void, Never>?
}

final class DefaultInboxDataSource: InboxDataSource, @unchecked Sendable {

    var authDataSource: AuthDataSource
    var client: APIClient

    weak var delegate: InboxDataSourceDelegate?

    private let state = Mutex<InboxState>(InboxState())

    private let pageSize: Int32 = 10
    private let options: GetChatViewControllerOptions?

    private let jsonEncoder = JSONEncoder()

    init(apiClient: APIClient, authDataSource: AuthDataSource, options: GetChatViewControllerOptions? = nil) {
        self.client = apiClient
        self.authDataSource = authDataSource
        self.options = options
    }

    deinit {
        state.withLock { $0.subscriptionTask?.cancel() }
    }

    func closeChannel() {
        client.closeChannel()
    }

    func startChannel() {
        client.startChannel()
    }

    // MARK: - Async API

    func getChannels() async throws -> [Sinch_Chat_Sdk_V1alpha2_Channel] {
        let shouldThrow: Bool = state.withLock { state in
            if let token = state.nextPageToken, token.isEmpty {
                return true
            }
            return false
        }
        if shouldThrow {
            throw InboxDataSourceError.noMoreChannels
        }
        let token = state.withLock { $0.nextPageToken }

        var request = Sinch_Chat_Sdk_V1alpha2_GetChannelsRequest()
        request.pageSize = self.pageSize
        if let token {
            state.withLock { state in
                state.firstPage = false
            }
            request.pageToken = token
        }

        let signed: ClientRequest<Sinch_Chat_Sdk_V1alpha2_GetChannelsRequest>
        do {
            signed = try authDataSource.signedRequest(request)
        } catch {
            throw InboxDataSourceError.notLoggedIn
        }

        do {
            let response = try await client.withClient { client in
                try await Sinch_Chat_Sdk_V1alpha2_SdkService.Client(wrapping: client).getChannels(
                    request: signed,
                    options: .standardCallOptions
                )
            }
            state.withLock { $0.nextPageToken = response.nextPageToken }
            return response.channels
        } catch {
            throw InboxDataSourceError.unknown(error)
        }
    }

    func subscribeForChannels() -> AsyncThrowingStream<Sinch_Chat_Sdk_V1alpha2_Channel, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runChannelsSubscription(continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runChannelsSubscription(
        continuation: AsyncThrowingStream<Sinch_Chat_Sdk_V1alpha2_Channel, Error>.Continuation
    ) async {
        let task: Task<Void, Never>? = state.withLock { state in
            if state.subscriptionTask != nil {
                return nil
            }
            let inner = Task { [weak self] in
                guard let self else { return }
                await self.executeChannelsStream(continuation: continuation)
            }
            state.subscriptionTask = inner
            return inner
        }
        if task == nil {
            continuation.finish()
            return
        }
        await task?.value
        state.withLock { $0.subscriptionTask = nil }
    }

    private func executeChannelsStream(
        continuation: AsyncThrowingStream<Sinch_Chat_Sdk_V1alpha2_Channel, Error>.Continuation
    ) async {
        let request = Sinch_Chat_Sdk_V1alpha2_SubscribeToChannelsStreamRequest()
        let signed: ClientRequest<Sinch_Chat_Sdk_V1alpha2_SubscribeToChannelsStreamRequest>
        do {
            signed = try authDataSource.signedRequest(request)
        } catch {
            continuation.finish()
            return
        }

        do {
            try await client.withClient { client in
                try await Sinch_Chat_Sdk_V1alpha2_SdkService.Client(wrapping: client).subscribeToChannelsStream(
                    request: signed,
                    options: .standardCallOptions
                ) { stream in
                    for try await response in stream.messages {
                        if Task.isCancelled { return }
                        continuation.yield(response.channel)
                    }
                }
            }
            continuation.finish()
        } catch let status as RPCError where status.code == .unavailable {
            // Mirror the v1 UNAVAILABLE(14) handling.
            let delegate = self.delegate
            DispatchQueue.main.async {
                delegate?.subscriptionError()
            }
            continuation.finish()
        } catch {
            continuation.finish()
        }
    }

    // MARK: - Completion handler compatibility

    func getChannels(completion: @escaping @Sendable (Result<[Sinch_Chat_Sdk_V1alpha2_Channel], InboxDataSourceError>) -> Void) {
        Task { [weak self] in
            guard let self else {
                completion(.failure(.notLoggedIn))
                return
            }
            do {
                let channels = try await self.getChannels()
                completion(.success(channels))
            } catch let error as InboxDataSourceError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unknown(error)))
            }
        }
    }

    func subscribeForChannels(completion: @escaping @Sendable (Result<Sinch_Chat_Sdk_V1alpha2_Channel, InboxDataSourceError>) -> Void) {
        let alreadyStarted: Bool = state.withLock { $0.subscriptionTask != nil }
        if alreadyStarted {
            DispatchQueue.main.async {
                completion(.failure(.subscriptionIsAlreadyStarted))
            }
            return
        }

        let stream = subscribeForChannels()
        Task { [weak self] in
            do {
                for try await channel in stream {
                    await MainActor.run { completion(.success(channel)) }
                }
            } catch {
                await MainActor.run {
                    completion(.failure(.unknown(error)))
                }
            }
            _ = self // keep reference alive
        }
    }

    // MARK: - State / lifecycle

    func cancelCalls() {
        // Unary calls already complete in the async path; nothing to cancel.
    }

    func cancelSubscription() {
        let task = state.withLock { state -> Task<Void, Never>? in
            let t = state.subscriptionTask
            state.subscriptionTask = nil
            state.nextPageToken = nil
            state.firstPage = true
            return t
        }
        task?.cancel()
    }

    func isSubscribed() -> Bool {
        state.withLock { $0.subscriptionTask != nil }
    }

    func isFirstPage() -> Bool {
        state.withLock { $0.firstPage }
    }

    func resetPagination() {
        state.withLock { state in
            state.nextPageToken = nil
            state.firstPage = true
        }
    }
}
