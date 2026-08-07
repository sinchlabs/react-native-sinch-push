// swiftlint:disable file_length
import Foundation
import Synchronization
import GRPCCore

protocol MessageDataSourceDelegate: AnyObject, Sendable {
    func subscriptionError()
}

enum MessageDataSourceError: Error, Sendable {
    case unknown(any Error)
    case notLoggedIn
    case unknownTypeOfMessage
    case unknownTypeOfEvent
    case messageIDIsEmpty
    case subscriptionIsAlreadyStarted
    case noMoreMessages
    case unknownTypeOfMedia
    case noInternetConnection
}

protocol MessageDataSource: AnyObject, Sendable {
    var delegate: MessageDataSourceDelegate? { get set }

    var topicModel: TopicModel? { get }
    var metadata: SinchMetadataArray { get }
    var shouldInitializeConversation: Bool { get }

    // Async API
    func uploadMedia(_ media: MediaType) async throws -> String
    func uploadMediaViaStream(_ media: MediaType) async throws -> String
    func sendMessage(_ message: MessageType) async throws -> String
    func sendEvent(_ event: EventType) async throws
    func subscribeForMessages() -> AsyncThrowingStream<Message, Error>
    func getMessageHistory() async throws -> [Message]
    func sendConversationMetadata(_ metadata: SinchMetadataArray) throws

    // Completion-handler compatibility layer
    func uploadMedia(_ media: MediaType,
                     completion: @escaping @Sendable (Result<String, MessageDataSourceError>) -> Void)
    func uploadMediaViaStream(_ media: MediaType,
                              completion: @escaping @Sendable (Result<String, MessageDataSourceError>) -> Void)
    func sendMessage(_ message: MessageType,
                     completion: @escaping @Sendable (Result<String, MessageDataSourceError>) -> Void)
    func sendEvent(_ event: EventType,
                   completion: @escaping @Sendable (Result<Void, MessageDataSourceError>) -> Void)
    func subscribeForMessages(completion: @escaping @Sendable (Result<Message, MessageDataSourceError>) -> Void)
    func getMessageHistory(completion: @escaping @Sendable (Result<[Message], MessageDataSourceError>) -> Void)
    func sendConversationMetadata(_ metadata: SinchMetadataArray) -> Result<Void, MessageDataSourceError>

    func cancelSubscription()
    func closeChannel()
    func startChannel()
    func cancelCalls()
    func isSubscribed() -> Bool
    func isFirstPage() -> Bool
}

private struct MessageState: Sendable {
    var firstPage: Bool = true
    var nextPageToken: String?
    var wasSomeMessageSent: Bool = false
    var subscriptionTask: Task<Void, Never>?
    var historyTask: Task<Void, Never>?
}

// swiftlint:disable:next type_body_length
final class DefaultMessageDataSource: MessageDataSource, @unchecked Sendable {

    var authDataSource: AuthDataSource
    var client: APIClient

    weak var delegate: MessageDataSourceDelegate?

    private let state = Mutex<MessageState>(MessageState())

    private let pageSize: Int32 = 10
    private let sendDocumentAsText: Bool

    let topicModel: TopicModel?
    var metadata: SinchMetadataArray
    let shouldInitializeConversation: Bool

    private let jsonEncoder = JSONEncoder()

    init(apiClient: APIClient, authDataSource: AuthDataSource, topicModel: TopicModel? = nil,
         metadata: SinchMetadataArray = [], shouldInitializeConversation: Bool = false,
         sendDocumentAsText: Bool = false) {
        self.client = apiClient
        self.authDataSource = authDataSource
        self.topicModel = topicModel
        self.metadata = metadata
        self.shouldInitializeConversation = shouldInitializeConversation
        self.sendDocumentAsText = sendDocumentAsText
    }

    deinit {
        let (sub, hist) = state.withLock { ($0.subscriptionTask, $0.historyTask) }
        sub?.cancel()
        hist?.cancel()
    }

    func closeChannel() {
        client.closeChannel()
    }

    func startChannel() {
        client.startChannel()
    }

    // MARK: - Async API

    func getMessageHistory() async throws -> [Message] {
        let shouldThrow: Bool = state.withLock { $0.nextPageToken?.isEmpty == true }
        if shouldThrow {
            throw MessageDataSourceError.noMoreMessages
        }
        let token = state.withLock { $0.nextPageToken }

        var request = Sinch_Chat_Sdk_V1alpha2_GetHistoryRequest()
        request.pageSize = self.pageSize
        if let token {
            state.withLock { $0.firstPage = false }
            request.pageToken = token
        }
        if let topicModel {
            request.topicID = topicModel.topicID
        }

        let signed: ClientRequest<Sinch_Chat_Sdk_V1alpha2_GetHistoryRequest>
        do {
            signed = try authDataSource.signedRequest(request)
        } catch {
            throw MessageDataSourceError.notLoggedIn
        }

        do {
            let response = try await client.withClient(handle: { client in
                try await Sinch_Chat_Sdk_V1alpha2_SdkService.Client(wrapping: client).getHistory(
                    request: signed,
                    options: .standardCallOptions
                )
            })

            // On first entry if there is no history, send a conversation_start
            // message to bootstrap the conversation.
            let wasFirstEntry = state.withLock { state -> Bool in
                let first = state.nextPageToken == nil
                state.nextPageToken = response.nextPageToken
                return first
            }

            if shouldInitializeConversation, wasFirstEntry, response.entries.isEmpty {
                do {
                    _ = try await sendMessage(.fallbackMessage("conversation_start"))
                    debugPrint("*********SEND CONVERSATION START MESSAGE **********")
                } catch {
                    debugPrint("conversation_start failed: \(error)")
                }
            }

            return try await processEntries(response.entries)
        } catch let error as MessageDataSourceError {
            throw error
        } catch {
            throw MessageDataSourceError.unknown(error)
        }
    }

    private func processEntries(_ entries: [Sinch_Chat_Sdk_V1alpha2_Entry]) async throws -> [Message] {
        var messages: [Message] = []
        for entry in entries {
            guard let message = handleIncomingMessage(entry) else { continue }
            if let event = message.body as? MessageEvent {
                if case .composeEnd = event.type { continue }
                if case .composeStarted = event.type { continue }
            }

            if let mediaMessage = message.body as? MessageMedia {
                if let enriched = await getMediaMessageTypeFromMessage(mediaMessage) {
                    if enriched.type != .unsupported {
                        messages.append(message.with(body: enriched))
                    } else {
                        messages.append(message.with(body: MessageUnsupported(sendDate: enriched.sendDate)))
                    }
                }
            } else {
                messages.append(message)
            }
        }
        return messages
    }

    func sendMessage(_ message: MessageType) async throws -> String {
        var isConversationStarted = false
        if case let .fallbackMessage(event) = message, event == "conversation_start" {
            isConversationStarted = true
        }

        guard var request = message.convertToSinchMessage else {
            throw MessageDataSourceError.unknownTypeOfMessage
        }
        if let topicModel {
            request.topicID = topicModel.topicID
        }
        if let metadataString = getMetadataFor(isConversationStarted ? .conversationStart : .message) {
            request.metadata = metadataString
        }

        let signed: ClientRequest<Sinch_Chat_Sdk_V1alpha2_SendRequest>
        do {
            signed = try authDataSource.signedRequest(request)
        } catch {
            throw MessageDataSourceError.notLoggedIn
        }

        do {
            let response = try await client.withClient { client in
                try await Sinch_Chat_Sdk_V1alpha2_SdkService.Client(wrapping: client).send(
                    request: signed,
                    options: .standardCallOptions
                )
            }
            state.withLock { $0.wasSomeMessageSent = true }
            return response.messageID
        } catch {
            throw MessageDataSourceError.unknown(error)
        }
    }

    func sendEvent(_ event: EventType) async throws {
        guard var request = event.convertToSinchEvent else {
            throw MessageDataSourceError.unknownTypeOfEvent
        }
        if let topicModel {
            request.topicID = topicModel.topicID
        }
        if let metadataString = getMetadataFor(.metadataEvent) {
            request.metadata = metadataString
        }

        let signed: ClientRequest<Sinch_Chat_Sdk_V1alpha2_SendRequest>
        do {
            signed = try authDataSource.signedRequest(request)
        } catch {
            throw MessageDataSourceError.notLoggedIn
        }

        do {
            _ = try await client.withClient { client in
                try await Sinch_Chat_Sdk_V1alpha2_SdkService.Client(wrapping: client).send(
                    request: signed,
                    options: .standardCallOptions
                )
            }
        } catch {
            throw MessageDataSourceError.unknown(error)
        }
    }

    func uploadMediaViaStream(_ media: MediaType) async throws -> String {
        guard let request = media.convertToSinchMedia else {
            throw MessageDataSourceError.unknownTypeOfMedia
        }
        var metadata = SinchChatSDK.standardMetadata
        if let token = try? authDataSource.currentAccessToken() {
            metadata.addString(token, forKey: "authorization")
        } else {
            throw MessageDataSourceError.notLoggedIn
        }

        do {
            let response = try await client.withClient { client in
                try await Sinch_Chat_Sdk_V1alpha2_SdkService.Client(wrapping: client).uploadMediaStream(
                    metadata: metadata,
                    options: .standardCallOptions
                ) { writer in
                    try await writer.write(request)
                }
            }
            return response.url
        } catch {
            throw MessageDataSourceError.unknown(error)
        }
    }

    func uploadMedia(_ media: MediaType) async throws -> String {
        guard let request = media.convertToSinchMedia else {
            throw MessageDataSourceError.unknownTypeOfMedia
        }
        let signed: ClientRequest<Sinch_Chat_Sdk_V1alpha2_UploadMediaRequest>
        do {
            signed = try authDataSource.signedRequest(request)
        } catch {
            throw MessageDataSourceError.notLoggedIn
        }

        do {
            let response = try await client.withClient { client in
                try await Sinch_Chat_Sdk_V1alpha2_SdkService.Client(wrapping: client).uploadMedia(
                    request: signed,
                    options: .standardCallOptions
                )
            }
            return response.url
        } catch {
            throw MessageDataSourceError.unknown(error)
        }
    }

    func subscribeForMessages() -> AsyncThrowingStream<Message, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runMessagesSubscription(continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runMessagesSubscription(
        continuation: AsyncThrowingStream<Message, Error>.Continuation
    ) async {
        let inner = state.withLock { state -> Task<Void, Never>? in
            if state.subscriptionTask != nil {
                return nil
            }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.executeMessagesStream(continuation: continuation)
            }
            state.subscriptionTask = task
            return task
        }
        if inner == nil {
            continuation.finish()
            return
        }
        await inner?.value
        state.withLock { $0.subscriptionTask = nil }
    }

    private func executeMessagesStream(
        continuation: AsyncThrowingStream<Message, Error>.Continuation
    ) async {
        do {
            // Pre-flight: send a metadata event message so the server knows we
            // are starting to receive.
            if let metadata = getMetadataFor(.metadataEvent) {
                _ = try? await sendMessageWithMetadata(metadata)
            }
        }

        var request = Sinch_Chat_Sdk_V1alpha2_SubscribeToStreamRequest.with {
            if let topicModel {
                $0.topicID = topicModel.topicID
            }
        }

        let signed: ClientRequest<Sinch_Chat_Sdk_V1alpha2_SubscribeToStreamRequest>
        do {
            signed = try authDataSource.signedRequest(request)
        } catch {
            continuation.finish()
            return
        }

        do {
            try await client.withClient { client in
                try await Sinch_Chat_Sdk_V1alpha2_SdkService.Client(wrapping: client).subscribeToStream(request: signed, options: .standardCallOptions) { [weak self] stream in
                    guard let self else { return }
                    for try await response in stream.messages {
                        if Task.isCancelled { return }
                        if let message = self.handleIncomingMessageEntry(response.entry) {
                            if let mediaMessage = message.body as? MessageMedia {
                                if let enriched = await self.getMediaMessageTypeFromMessage(mediaMessage) {
                                    if enriched.type != .unsupported {
                                        continuation.yield(message.with(body: enriched))
                                    } else {
                                        continuation.yield(message.with(body: MessageUnsupported(sendDate: enriched.sendDate)))
                                    }
                                    continue
                                }
                            }
                            continuation.yield(message)
                        }
                    }
                }
            }
            continuation.finish()
        } catch let status as RPCError where status.code == .unavailable {
            let delegate = self.delegate
            DispatchQueue.main.async {
                delegate?.subscriptionError()
            }
            continuation.finish()
        } catch {
            continuation.finish()
        }
    }

    private func sendMessageWithMetadata(_ metadata: String) async throws {
        var request = Sinch_Chat_Sdk_V1alpha2_SendRequest()
        request.metadata = metadata
        let signed: ClientRequest<Sinch_Chat_Sdk_V1alpha2_SendRequest>
        do {
            signed = try authDataSource.signedRequest(request)
        } catch {
            throw MessageDataSourceError.notLoggedIn
        }
        _ = try await client.withClient { client in
            try await Sinch_Chat_Sdk_V1alpha2_SdkService.Client(wrapping: client).send(
                request: signed,
                options: .standardCallOptions
            )
        }
    }

    func sendConversationMetadata(_ metadata: SinchMetadataArray) throws {
        try _sendConversationMetadataSync(metadata)
    }

    // MARK: - Completion-handler compatibility layer

    func uploadMedia(_ media: MediaType,
                     completion: @escaping @Sendable (Result<String, MessageDataSourceError>) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.uploadMedia(media)
                completion(.success(url))
            } catch let error as MessageDataSourceError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unknown(error)))
            }
        }
    }

    func uploadMediaViaStream(_ media: MediaType,
                              completion: @escaping @Sendable (Result<String, MessageDataSourceError>) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.uploadMediaViaStream(media)
                completion(.success(url))
            } catch let error as MessageDataSourceError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unknown(error)))
            }
        }
    }

    func sendMessage(_ message: MessageType,
                     completion: @escaping @Sendable (Result<String, MessageDataSourceError>) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let id = try await self.sendMessage(message)
                completion(.success(id))
            } catch let error as MessageDataSourceError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unknown(error)))
            }
        }
    }

    func sendEvent(_ event: EventType,
                   completion: @escaping @Sendable (Result<Void, MessageDataSourceError>) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendEvent(event)
                completion(.success(()))
            } catch let error as MessageDataSourceError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unknown(error)))
            }
        }
    }

    func subscribeForMessages(completion: @escaping @Sendable (Result<Message, MessageDataSourceError>) -> Void) {
        let alreadyStarted = state.withLock { $0.subscriptionTask != nil }
        if alreadyStarted {
            completion(.failure(.subscriptionIsAlreadyStarted))
            return
        }

        let stream = subscribeForMessages()
        Task {
            do {
                for try await message in stream {
                    await MainActor.run { completion(.success(message)) }
                }
            } catch {
                await MainActor.run {
                    completion(.failure(.unknown(error)))
                }
            }
        }
    }

    func getMessageHistory(completion: @escaping @Sendable (Result<[Message], MessageDataSourceError>) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let messages = try await self.getMessageHistory()
                completion(.success(messages))
            } catch let error as MessageDataSourceError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unknown(error)))
            }
        }
    }

    func sendConversationMetadata(_ metadata: SinchMetadataArray) -> Result<Void, MessageDataSourceError> {
        do {
            try self._sendConversationMetadataSync(metadata)
            return .success(())
        } catch let error as MessageDataSourceError {
            return .failure(error)
        } catch {
            return .failure(.unknown(error))
        }
    }

    private func _sendConversationMetadataSync(_ metadata: SinchMetadataArray) throws {
        var keyValueDictionary: [String: String] = [:]
        metadata.forEach { entry in
            let data = entry.getKeyValue()
            keyValueDictionary[data.key] = data.value
        }

        let encodedData = try jsonEncoder.encode(keyValueDictionary)
        var request = Sinch_Chat_Sdk_V1alpha2_SendRequest()
        request.metadata = String(bytes: encodedData, encoding: .utf8) ?? "{}"

        let signed: ClientRequest<Sinch_Chat_Sdk_V1alpha2_SendRequest>
        do {
            signed = try authDataSource.signedRequest(request)
        } catch {
            throw MessageDataSourceError.notLoggedIn
        }

        // Fire-and-forget RPC.
        Task {
            do {
                _ = try await client.withClient { client in
                    try await Sinch_Chat_Sdk_V1alpha2_SdkService.Client(wrapping: client).send(
                        request: signed,
                        options: .standardCallOptions
                    )
                }
            } catch {
                Logger.warning("cannot set conversation metadata: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - State / lifecycle

    func cancelCalls() {
        let task = state.withLock { state -> Task<Void, Never>? in
            let t = state.historyTask
            state.historyTask = nil
            return t
        }
        task?.cancel()
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

    // MARK: - Private helpers

    private func addSize(_ response: HTTPURLResponse, mediaMessage: inout MessageMedia) {
        if let size = response.allHeaderFields["Content-Length"] as? String, let sized = Double(size) {
            let sizeInMb = sized / (1024.0 * 1024.0)
            if sizeInMb < 1 {
                let sizeInKB = sized / 1024.0
                mediaMessage.size = String(format: "%.1f KB", sizeInKB)
            } else {
                mediaMessage.size = String(format: "%.1f MB", sizeInMb)
            }
        }
    }

    /// Async media-type lookup via URLSession.
    func getMediaMessageTypeFromMessage(_ message: MessageMedia) async -> MessageMedia? {
        guard let url = URL(string: message.url) else {
            return message
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  let type = httpResponse.allHeaderFields["Content-Type"] as? String else {
                return message
            }

            var mediaMessage = message
            switch type {
            case "video/mp4", "video/mov":
                mediaMessage.type = .video
            case "audio/aac", "audio/adts", "audio/ac3", "audio/aif", "audio/aiff", "audio/aifc", "audio/caf",
                 "audio/mp4", "audio/mp3", "audio/m4a", "audio/snd", "audio/au", "audio/wav", "audio/sd2":
                mediaMessage.type = .audio
            case "image/jpg", "image/jpeg", "image/png", "image/tif", "image/tiff", "image/gif", "image/bmp",
                 "image/BMPf", "image/ico", "image/cur", "image/xbm":
                mediaMessage.type = .image
            case "application/pdf":
                mediaMessage.type = .file(.pdf)
            case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
                mediaMessage.type = .file(.docx)
            case "application/msword":
                mediaMessage.type = .file(.doc)
            case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
                mediaMessage.type = .file(.xlsx)
            case "application/vnd.ms-excel":
                mediaMessage.type = .file(.xls)
            case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
                mediaMessage.type = .file(.pptx)
            case "application/vnd.ms-powerpoint":
                mediaMessage.type = .file(.ppt)
            default:
                mediaMessage.type = .file(.unknown)
            }
            self.addSize(httpResponse, mediaMessage: &mediaMessage)
            return mediaMessage
        } catch {
            return nil
        }
    }

    static func createChoicesArray(_ choices: [Sinch_Conversationapi_Type_Choice], entryID: String) -> [ChoiceMessageType] {
        var choicesArray: [ChoiceMessageType] = []

        for choice in choices {
            guard let message = choice.choice else { break }
            switch message {
            case let .textMessage(textMessage):
                choicesArray.append(.textMessage(ChoiceText(text: textMessage.text, postback: choice.postbackData, entryID: entryID)))
            case let .urlMessage(urlMessage):
                choicesArray.append(.urlMessage(ChoiceUrl(url: urlMessage.url, text: urlMessage.title)))
            case let .callMessage(callMessage):
                choicesArray.append(.callMessage(ChoiceCall(text: callMessage.title, phoneNumber: callMessage.phoneNumber)))
            case let .locationMessage(locationMessage):
                choicesArray.append(.locationMessage(ChoiceLocation(text: locationMessage.title,
                                                                    label: locationMessage.label,
                                                                    latitude: Double(locationMessage.coordinates.latitude),
                                                                    longitude: Double(locationMessage.coordinates.longitude))))
            }
        }
        return choicesArray
    }

    private func getMetadataFor(_ reason: MessageMetadataReason) -> String? {
        switch reason {
        case .message:
            let first = !state.withLock { $0.wasSomeMessageSent }
            return getMetadataString(includingOnce: first)
        case .conversationStart, .metadataEvent, .onceMessageRequest:
            return getMetadataString(includingOnce: true)
        }
    }

    private func getMetadataString(includingOnce: Bool = false) -> String? {
        if metadata.isEmpty, SinchChatSDK.shared.additionalMetadata.isEmpty {
            return nil
        }
        var dictMetadata: [String: String] = [:]

        SinchChatSDK.shared.additionalMetadata.forEach({
            let tuple = $0.getKeyValue()
            switch tuple.mode {
            case .once:
                if includingOnce { dictMetadata[tuple.key] = tuple.value }
            case .withEachMessage:
                dictMetadata[tuple.key] = tuple.value
            }
        })

        metadata.forEach({
            let tuple = $0.getKeyValue()
            switch tuple.mode {
            case .once:
                if includingOnce { dictMetadata[tuple.key] = tuple.value }
            case .withEachMessage:
                dictMetadata[tuple.key] = tuple.value
            }
        })

        guard let encodedMetadata = try? JSONEncoder().encode(dictMetadata) else {
            return nil
        }

        return String(data: encodedMetadata, encoding: .utf8)
    }

    fileprivate func handleIncomingMessageEntry(_ entry: Sinch_Chat_Sdk_V1alpha2_Entry) -> Message? {
        handleIncomingMessage(entry)
    }
}

struct TopicModel: Sendable {
    let topicID: String
}

enum MessageMetadataReason {
    case message
    case onceMessageRequest
    case conversationStart
    case metadataEvent
}

// swiftlint:disable function_body_length cyclomatic_complexity
func handleIncomingMessage(_ entry: Sinch_Chat_Sdk_V1alpha2_Entry) -> Message? {
    // TODO: - Handle incoming messages
    //  if entry.hasDeliveryTime {

    // MARK: - Outgoing messages

    let outgoingText = entry.contactMessage.textMessage.text
    if !outgoingText.isEmpty {
        return Message(entryId: entry.entryID, owner: .outgoing, body: MessageText(text: outgoingText, sendDate: entry.deliveryTime.seconds))
    }

    let outgoingUrl = entry.contactMessage.mediaMessage.url
    if !outgoingUrl.isEmpty {

        return Message(entryId: entry.entryID, owner: .outgoing, body: MessageMedia(url: outgoingUrl, sendDate: entry.deliveryTime.seconds))
    }
    // MARK: - Incoming messages

    let incomingText = entry.appMessage.textMessage.text
    if !incomingText.isEmpty {
        if entry.appMessage.hasAgent {
            let agent = entry.appMessage.agent

            return Message(entryId: entry.entryID,
                           owner: .incoming(.init(name: agent.displayName, type: agent.type.rawValue, pictureUrl: agent.pictureURL)),
                           body: MessageText(text: incomingText, sendDate: entry.deliveryTime.seconds, isExpanded: false))
        } else {

            return Message(entryId: entry.entryID, owner: .incoming(nil),
                           body: MessageText(text: incomingText,
                                             sendDate: entry.deliveryTime.seconds))
        }
    }
    let outgoingLocationMessage = entry.contactMessage.locationMessage
    if outgoingLocationMessage.hasCoordinates {
        let messageBody = MessageLocation(label: outgoingLocationMessage.label,
                                          title: outgoingLocationMessage.title,
                                          latitude: Double(outgoingLocationMessage.coordinates.latitude),
                                          longitude: Double(outgoingLocationMessage.coordinates.longitude),
                                          sendDate: entry.deliveryTime.seconds)

        return Message(entryId: entry.entryID, owner: .outgoing, body: messageBody)
    }

    if !entry.contactMessage.fallbackMessage.rawMessage.isEmpty {
        return Message(entryId: entry.entryID, owner: .system, body: MessageEvent(type: .fallbackMessage(
            payload: entry.contactMessage.fallbackMessage.rawMessage
        )))
    }

    let incomingLocationMessage = entry.appMessage.locationMessage
    if incomingLocationMessage.hasCoordinates {
        let messageBody = MessageLocation(label: incomingLocationMessage.label,
                                          title: incomingLocationMessage.title,
                                          latitude: Double(incomingLocationMessage.coordinates.latitude),
                                          longitude: Double(incomingLocationMessage.coordinates.longitude),
                                          sendDate: entry.deliveryTime.seconds)

        if entry.appMessage.hasAgent {
            let agent = entry.appMessage.agent

            return Message(entryId: entry.entryID, owner: .incoming(.init(name: agent.displayName,
                                                                          type: agent.type.rawValue, pictureUrl: agent.pictureURL)),
                           body:  messageBody)
        } else {

            return Message(entryId: entry.entryID, owner: .incoming(nil), body: messageBody)
        }
    }

    let incomingChoiceMessage = entry.appMessage.choiceMessage
    if !incomingChoiceMessage.choices.isEmpty {
        let choices = DefaultMessageDataSource.createChoicesArray(incomingChoiceMessage.choices,
                                                                  entryID: entry.entryID)
        let messageBody = MessageChoices(text: "", choices: choices, sendDate: entry.deliveryTime.seconds)

        return Message(entryId: entry.entryID, owner: .incoming(nil), body: messageBody)
    }

    let incomingCardMessage = entry.appMessage.cardMessage

    if incomingCardMessage.hasMediaMessage {
        let choicesArray = DefaultMessageDataSource.createChoicesArray(incomingCardMessage.choices, entryID: entry.entryID)
        let messageBody = MessageCard(title: incomingCardMessage.title,
                                      description: incomingCardMessage.description_p,
                                      choices: choicesArray,
                                      url: incomingCardMessage.mediaMessage.url,
                                      sendDate: entry.deliveryTime.seconds)

        if entry.appMessage.hasAgent {
            let agent = entry.appMessage.agent
            return Message(entryId: entry.entryID, owner: .incoming(.init(name: agent.displayName, type: agent.type.rawValue, pictureUrl: agent.pictureURL)),
                           body: messageBody)
        } else {
            return Message(entryId: entry.entryID, owner: .incoming(nil), body: messageBody)
        }
    }

    let incomingCarousel = entry.appMessage.carouselMessage
    if !incomingCarousel.cards.isEmpty {
        var cards: [MessageCard] = []
        for card in incomingCarousel.cards {
            let choices = DefaultMessageDataSource.createChoicesArray(card.choices, entryID: entry.entryID)
            cards.append(MessageCard(title: card.title,
                                     description: card.description_p,
                                     choices: choices,
                                     url: card.mediaMessage.url,
                                     sendDate: entry.deliveryTime.seconds))
        }
        return Message(entryId: entry.entryID,
                       owner: .incoming(nil),
                       body: MessageCarousel(cards: cards, choices: [], sendDate: entry.deliveryTime.seconds))
    }

    // MARK: - System events

    return nil
}
