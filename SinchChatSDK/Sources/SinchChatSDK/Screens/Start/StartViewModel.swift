// swiftlint:disable file_length type_body_length
import Foundation
import UIKit

// #region agent log
private enum AgentDebugLog {
    nonisolated(unsafe) static let logPath = "/Users/emems/swift/sinch/ios-test-app/.cursor/debug-3c9ae7.log"
    nonisolated(unsafe) static var lastTimestamp: UInt64 = 0

    static func write(_ payload: [String: Any]) {
        var line = "{"
        var first = true
        for (k, v) in payload {
            if !first { line += "," }
            first = false
            let json: String
            if let s = v as? String {
                json = "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
            } else if let b = v as? Bool {
                json = b ? "true" : "false"
            } else if let n = v as? NSNumber {
                json = n.stringValue
            } else {
                json = "\"\(v)\""
            }
            line += "\"\(k)\":\(json)"
        }
        line += "}\n"

        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: logPath)
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
// #endregion agent log

@MainActor
protocol StartViewModel: MessageDataSourceDelegate {
    var delegate: StartViewModelDelegate? { get }
    var isStartedFromInbox: Bool { get set }
    var sendDocumentAsText: Bool { get }

    func setInternetConnectionState(_ state: InternetConnectionState)
    func sendMedia(_ media: MediaType, completion: @escaping @Sendable (Result<Message, Error>) -> Void)
    func sendMessage(_ message: MessageType, completion: @escaping @Sendable (Result<Message?, Error>) -> Void)
    func loadHistory()
    func onLoad()
    func onDisappear()
    func onWillEnterForeground()
    func onDidEnterBackground()
    func onInternetLost()
    func onInternetOn()
    func closeChannel()
    func processNewMessages(_ message: Message) -> [Message]
    func sendEvent(_ event: EventType )
    func getChatOptions() -> SinchChatOptions

}

@MainActor
protocol StartViewModelDelegate: AnyObject {
    func didReceiveMessages(_ message: [Message])
    func didReceiveHistoryFirstMessages(_ messages: [Message])
    func didReceiveHistoryMessages(_ messages: [Message])
    func errorLoadingMoreHistory(error: MessageDataSourceError)
    func errorSendingMessage(error: MessageDataSourceError)
    func didChangeInternetState(_ state: InternetConnectionState)
    func setVisibleRefreshActivityIndicator(_ isVisible: Bool)
    func setVisibleTypingIndicator(_ isVisible: Bool, animated: Bool)

    /// Notify the view that an outgoing message with `tempId` has been
    /// resolved to the server-assigned `entryId` (and a new status).
    /// The view should replace the cell with `tempId` in place rather
    /// than appending a duplicate.
    func didResolveOutgoingMessage(tempId: String, resolved: Message)

    /// Notify the view that an outgoing message with `tempId` failed to
    /// send. The view should update the optimistic cell's status to
    /// `.notSent` rather than inserting a new cell.
    func didFailToSend(tempId: String, status: MessageStatus)
}

@MainActor
final class DefaultStartViewModel: StartViewModel {
    
    private var dataSource: MessageDataSource
    private let notificationPermission: PushNofiticationPermissionHandler
    
    weak var delegate: StartViewModelDelegate?
    var messagesArrays: [[Message]] = []
    var isMessageSent = false
    var isEventSent = false
    var isTypingIndicatorVisible = false
    var isStartedFromInbox = false
    var sendDocumentAsText = false

    var error: Error?
    var state: InternetConnectionState = .notDetermined {
        willSet {
            if state != newValue {

                delegate?.didChangeInternetState(newValue)

            }
        }
    }
    var timeOfLastReceivedMessage: Date?
    nonisolated(unsafe) var timer: Timer?

    /// Counter used to generate stable temp ids for outgoing messages. Reset
    /// whenever the chat session is reset (idle / internet on).
    private var tempIdCounter: Int = 0

    /// Pending outgoing optimistic inserts, keyed by a content fingerprint
    /// (text/url/coordinates). Used to dedup the gRPC echo that the server
    /// streams back after we send. We cannot key by server `entryId` because
    /// the echo often arrives BEFORE the `sendMessage` RPC returns the
    /// server-assigned id — confirmed by runtime logs in this debug session.
    /// We also keep the server id mapping as a fallback for the rare case
    /// where the success callback fires before any echo.
    private var pendingOutgoingByFingerprint: [String: String] = [:]
    private var pendingOutgoingByServerId: [String: String] = [:]

    private func nextTempId() -> String {
        tempIdCounter += 1
        return "tmp-\(tempIdCounter)"
    }

    private func clearOutgoingMappings() {
        pendingOutgoingByFingerprint.removeAll()
        pendingOutgoingByServerId.removeAll()
    }

    /// Build a content fingerprint for an outgoing message. We match on
    /// this when an outgoing message arrives via the subscription stream so
    /// the swap works regardless of whether the server has already returned
    /// the entryId to us.
    private func outgoingFingerprint(for message: Message) -> String? {
        switch message.body {
        case let text as MessageText:
            return "text:\(text.text):\(text.sendDate ?? 0)"
        case let media as MessageMedia:
            return "media:\(media.url):\(media.sendDate ?? 0)"
        case let location as MessageLocation:
            return "loc:\(location.latitude):\(location.longitude):\(location.sendDate ?? 0)"
        default:
            return nil
        }
    }
    
    init(
        messageDataSource: MessageDataSource,
        notificationPermission: PushNofiticationPermissionHandler,
        sendDocumentAsText: Bool = false
    ) {
        self.dataSource = messageDataSource

        self.sendDocumentAsText = sendDocumentAsText
        self.notificationPermission = notificationPermission
    }
    
    deinit {
        timer?.invalidate()
        timer = nil
    }
    // MARK: - Private methods
    
    private func createArrayWithDateMessage(_ arraysOfMessages: [[Message]]) -> [Message] {
        var allMessagesArray : [Message] = []
        for array in arraysOfMessages {
            
            if let date = array.first?.body.sendDate {
                allMessagesArray.append(Message(entryId: "-1", owner: .system, body: MessageDate(sendDate: date)))
            }
            allMessagesArray.append(contentsOf: array)
        }
        return allMessagesArray
    }
    
    private func askForNotifications() {
        notificationPermission.checkIfPermissionIsGranted { [weak self] status in
            switch status {
            case .granted: break
            case .denied:
                self?.notificationPermission.askForPermissions(completion: nil)
            case .notDetermined:
                self?.notificationPermission.askForPermissions(completion: nil)
            }
        }
    }
    func closeChannel() {
        dataSource.closeChannel()
    }
    
    private func setIdleState() {
        dataSource.cancelSubscription()

        messagesArrays = []
        clearOutgoingMappings()
        self.delegate?.didReceiveHistoryFirstMessages([])

        error = nil
        isMessageSent = false
        SinchChatSDK.shared._chat.state = .idle
    }
    
    private func setRunningState() {
        
        SinchChatSDK.shared._chat.state = .running
        loadHistory()
        subscribeForMessages()
        
    }
    
    // MARK: - Public methods
    
    func getChatOptions() -> SinchChatOptions {
        return .init(
            topicID: dataSource.topicModel?.topicID,
            metadata: dataSource.metadata,
            shouldInitializeConversation: dataSource.shouldInitializeConversation
        )
    }
    
    func setInternetConnectionState(_ state: InternetConnectionState) {
        self.state = state
    }
    
    func processHistoryMessages(_ messages: [Message], callback: @escaping @MainActor @Sendable ([Message]) -> Void) {
        
        Task(priority: .userInitiated) {
            
            var array: [[Message]] = []
            for notProcessedMessage in messages.reversed() {

                // History pagination can re-deliver an outgoing message we
                // already inserted optimistically. If the entryId matches a
                // pending optimistic send or the content fingerprint does,
                // drop it here so we don't render a duplicate cell.
                if case .outgoing = notProcessedMessage.owner {
                    if pendingOutgoingByServerId[notProcessedMessage.entryId] != nil {
                        continue
                    }
                    if let fingerprint = outgoingFingerprint(for: notProcessedMessage),
                       pendingOutgoingByFingerprint[fingerprint] != nil {
                        continue
                    }
                }

                guard let message = await processPluginMessageAsync(notProcessedMessage) else {
                    continue
                }
                if let msgEvent = message.body as? MessageEvent,
                   msgEvent.text?.isEmpty ?? true {
                    continue
                }
                
                if messagesArrays.isEmpty {
                    messagesArrays.append([message])
                    array.append([message])
                } else {
                    
                    if let messageFromHistory = messagesArrays.first?.first,
                       let dateFromHistory = messageFromHistory.body.sendDate,
                       let date = message.body.sendDate {
                        
                        if dateFromHistory.isSameDay(date) {
                            messagesArrays[0].insert(message, at: 0)
                            if array.isEmpty {
                                array.append([message])
                            } else {
                                array[0].insert(message, at: 0)
                                
                            }
                            
                        } else {
                            messagesArrays.insert([message], at: 0)
                            
                            if array.isEmpty {
                                array.append([message])
                            } else {
                                array.insert([message], at: 0)
                                
                            }
                        }
                    } else {
                        messagesArrays.insert([message], at: 0)
                        
                        if array.isEmpty {
                            array.append([message])
                        } else {
                            array.insert([message], at: 0)
                            
                        }
                    }
                }
                
            }
            callback(createArrayWithDateMessage(array))
        }
    }
    
    func processNewMessages(_ message: Message) -> [Message] {

        if let msgEvent = message.body as? MessageEvent,
           msgEvent.text?.isEmpty ?? true {
            return []
        }

        // #region agent log
        let ownerString: String
        switch message.owner {
        case .outgoing: ownerString = "outgoing"
        case .incoming(let agent): ownerString = "incoming(\(agent?.name ?? "nil"))"
        case .system: ownerString = "system"
        }
        AgentDebugLog.write([
            "id": "process_new_\(message.entryId)_\(Int(Date().timeIntervalSince1970 * 1000))",
            "hypothesisId": "H1",
            "location": "StartViewModel.swift:processNewMessages",
            "message": "processNewMessages called",
            "data": [
                "entryId": message.entryId,
                "owner": ownerString,
                "status": message.status.rawValue,
                "bodyType": String(describing: type(of: message.body)),
                "existingCount": messagesArrays.flatMap { $0 }.count
            ]
        ])
        // #endregion agent log

        let startCount = messagesArrays.count
        
        if messagesArrays.isEmpty {
            messagesArrays.append([message])
        } else {
            
            if let messageFromHistory = messagesArrays.last?.last,
               let dateFromHistory = messageFromHistory.body.sendDate,
               let date =  message.body.sendDate {
                
                if dateFromHistory.isSameDay(date) {
                    messagesArrays[messagesArrays.count - 1].append(message)
                    
                } else {
                    messagesArrays.append([message])
                }
            }
        }
        let endCount = messagesArrays.count
        
        if startCount == endCount {
            return [message]
        } else {
            return createArrayWithDateMessage([[message]])
        }
    }

    /// Inspects an incoming stream message to see if it is the server echo
    /// of a message we optimistically inserted with a temp id. If it is,
    /// we update the optimistic cell in place (server entryId, status
    /// `.sent`) and tell the delegate to reload that section so the UI
    /// flips from `.sending` to `.sent`. Returns `nil` to suppress the
    /// stream message from being inserted as a duplicate.
    ///
    /// For any non-outgoing or unknown message we return the message
    /// unchanged so existing handlers can process it normally.
    private func resolveOutgoingEcho(_ message: Message) -> Message? {
        guard case .outgoing = message.owner else {
            // #region agent log
            AgentDebugLog.write([
                "id": "resolve_skip_non_outgoing_\(message.entryId)",
                "hypothesisId": "H6",
                "location": "StartViewModel.swift:resolveOutgoingEcho",
                "message": "Skipping resolve because owner is not outgoing",
                "data": ["entryId": message.entryId]
            ])
            // #endregion agent log
            return message
        }

        // Try server id lookup first (cheap, O(1)), then fall back to
        // content fingerprint lookup which handles the race where the echo
        // arrives before the sendMessage RPC completes.
        var tempId: String? = pendingOutgoingByServerId[message.entryId]
        var matchKind = "serverId"

        if tempId == nil, let fingerprint = outgoingFingerprint(for: message) {
            tempId = pendingOutgoingByFingerprint[fingerprint]
            matchKind = "fingerprint"
        }

        guard let resolvedTempId = tempId else {
            // #region agent log
            AgentDebugLog.write([
                "id": "resolve_no_match_\(message.entryId)",
                "hypothesisId": "H1",
                "location": "StartViewModel.swift:resolveOutgoingEcho",
                "message": "Outgoing echo with NO matching tempId",
                "data": [
                    "entryId": message.entryId,
                    "byFingerprintSize": pendingOutgoingByFingerprint.count,
                    "byServerIdSize": pendingOutgoingByServerId.count
                ]
            ])
            // #endregion agent log
            return message
        }

        // #region agent log
        AgentDebugLog.write([
            "id": "resolve_swap_\(message.entryId)",
            "hypothesisId": "H1",
            "location": "StartViewModel.swift:resolveOutgoingEcho",
            "message": "Outgoing echo MATCHED optimistic",
            "data": [
                "serverEntryId": message.entryId,
                "tempId": resolvedTempId,
                "matchKind": matchKind
            ]
        ])
        // #endregion agent log

        let serverEntryId = message.entryId
        var resolved = message
        resolved.status = .sent

        // Replace the optimistic cell in place inside `messagesArrays`.
        for (sectionIndex, section) in messagesArrays.enumerated() {
            for (itemIndex, existing) in section.enumerated() where existing.entryId == resolvedTempId {
                messagesArrays[sectionIndex][itemIndex] = resolved
                break
            }
        }

        // Clean up whichever mappings pointed at this optimistic.
        pendingOutgoingByServerId.removeValue(forKey: serverEntryId)
        if let fingerprint = outgoingFingerprint(for: resolved) {
            pendingOutgoingByFingerprint.removeValue(forKey: fingerprint)
        }

        // Ask the view controller to swap the optimistic cell in place.
        delegate?.didResolveOutgoingMessage(tempId: resolvedTempId, resolved: resolved)
        return nil
    }

    /// Mark the optimistic outgoing message (identified by its temp id) as
    /// failed inside `messagesArrays`. Safe to call when the temp id is no
    /// longer present (already replaced or removed).
    private func markOptimisticAsFailed(tempId: String) {
        pendingOutgoingByServerId = pendingOutgoingByServerId.filter { $0.value != tempId }
        pendingOutgoingByFingerprint = pendingOutgoingByFingerprint.filter { $0.value != tempId }
        for (sectionIndex, section) in messagesArrays.enumerated() {
            for (itemIndex, existing) in section.enumerated() where existing.entryId == tempId {
                messagesArrays[sectionIndex][itemIndex].status = .notSent
                return
            }
        }
    }
    
    func onLoad() {
        
        dataSource.cancelCalls()
        setRunningState()
        
    }
    
    func onDisappear() {
        setIdleState()
    }
    
    func onInternetOn() {
        if !messagesArrays.isEmpty {
            messagesArrays = []
            self.delegate?.didReceiveHistoryFirstMessages([])
        }
        clearOutgoingMappings()

        dataSource.cancelCalls()
        setRunningState()

    }

    func onInternetLost() {
        dataSource.cancelSubscription()
        clearOutgoingMappings()
        error = nil
        isMessageSent = false
        SinchChatSDK.shared._chat.state = .idle
    }
    
    func onWillEnterForeground() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
            self.dataSource.startChannel()
            self.setRunningState()
            
        })
    }
    
    func onDidEnterBackground() {
        setIdleState()
        dataSource.closeChannel()
        
    }
    
    func shouldHandleTypingIndicator() -> Bool {
        
        if let timeOfLastReceivedMessage = timeOfLastReceivedMessage {
            let delta = Double(Date() - timeOfLastReceivedMessage)
            if delta < 1 {
                return false
            }
        }
        return true
    }
    func subscribeForMessages() {
        dataSource.subscribeForMessages { [weak self] result in

            guard let self = self else {
                return
            }

            switch result {
            case .success(let message):
                Task { @MainActor [weak self] in
                    guard let self = self else { return }

                    // #region agent log
                    let ownerString: String
                    switch message.owner {
                    case .outgoing: ownerString = "outgoing"
                    case .incoming(let agent): ownerString = "incoming(\(agent?.name ?? "nil"))"
                    case .system: ownerString = "system"
                    }
                    AgentDebugLog.write([
                        "id": "echo_received_\(message.entryId)",
                        "hypothesisId": "H1",
                        "location": "StartViewModel.swift:432",
                        "message": "Subscription echo arrived",
                        "data": [
                            "entryId": message.entryId,
                            "owner": ownerString,
                            "bodyType": String(describing: type(of: message.body)),
                            "status": message.status.rawValue,
                            "byFingerprintSize": self.pendingOutgoingByFingerprint.count,
                            "byServerIdSize": self.pendingOutgoingByServerId.count
                        ]
                    ])
                    // #endregion agent log

                    // If this is the server echo of an outgoing message we
                    // sent earlier, flip the optimistic cell from `.sending`
                    // to `.sent` in place and drop the duplicate stream
                    // delivery.
                    if let resolved = self.resolveOutgoingEcho(message) {
                        self.processPluginMessage(resolved) { processedMessageByPlugins in
                            guard let processedMessageByPlugins = processedMessageByPlugins else {
                                return
                            }

                            Task { @MainActor in
                                if let event = processedMessageByPlugins.body as? MessageEvent {

                                    switch event.type {
                                    case .composeStarted:
                                        if self.shouldHandleTypingIndicator() {
                                            self.isTypingIndicatorVisible = true
                                            self.delegate?.setVisibleTypingIndicator(self.isTypingIndicatorVisible, animated: true)
                                            DispatchQueue.main.async {

                                                self.timer?.invalidate()
                                                self.timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in

                                                    guard let self = self else { return }
                                                    Task { @MainActor in
                                                        self.isTypingIndicatorVisible = false
                                                        self.delegate?.setVisibleTypingIndicator(self.isTypingIndicatorVisible, animated: true)
                                                    }

                                                }
                                            }
                                        }
                                        return
                                    case .composeEnd:
                                        self.timer?.invalidate()
                                        self.isTypingIndicatorVisible = false
                                        self.delegate?.setVisibleTypingIndicator(self.isTypingIndicatorVisible, animated: true)

                                        return
                                    default:
                                        break
                                    }
                                }
                                let messages = self.processNewMessages(processedMessageByPlugins)
                                if !messages.isEmpty {
                                    self.timeOfLastReceivedMessage = Date()
                                    self.delegate?.didReceiveMessages(messages)
                                }
                            }
                        }
                    }
                }

            case .failure(let error):
                let nsError = error
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    Logger.verbose(nsError)
                    self.error = nsError
                }
            }
        }
    }
    
    func loadHistory() {
        error = nil

        dataSource.getMessageHistory { [weak self] messages in

            guard let self = self else {
                return
            }
            switch messages {

            case .success(let messages):
                Task { @MainActor in
                    self.processHistoryMessages(messages) { [weak self] processedMessages in
                        guard let self = self else {
                            return
                        }
                        if self.dataSource.isFirstPage() {
                            self.delegate?.didReceiveHistoryFirstMessages(processedMessages)
                        } else {
                            self.delegate?.didReceiveHistoryMessages(processedMessages)
                        }
                    }
                }
            case .failure(let error):
                let nsError = error
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    Logger.verbose(nsError)
                    self.error = nsError
                    self.delegate?.errorLoadingMoreHistory(error: nsError)
                }
            }
        }
    }
    
    func sendMessage(_ message: MessageType, completion: @escaping @Sendable (Result<Message?, Error>) -> Void) {

        isMessageSent = false

        if state == .isOff {
            self.delegate?.errorSendingMessage(error: .noInternetConnection)
            return
        }
        askForNotifications()
        error = nil

        // Allocate a stable temp id up front so retries and the optimistic
        // insert share the same id. The server-side entryId we receive back
        // from `dataSource.sendMessage` will map to this temp id, which lets
        // us collapse the gRPC echo into the optimistic cell in place.
        let tempId = nextTempId()

        processMessageBeforeSending(messagePayload: message, tempId: tempId) { [weak self] messageToSend in
            guard let self = self, let messageToSend = messageToSend else {
                completion(.success(nil))
                return
            }

            // Optimistic insert before the network call so the user sees the
            // bubble with `.sending` immediately.
            if let optimistic = self.createMessage(entryId: tempId, messageType: messageToSend) {
                let messagesToShow = self.processNewMessages(optimistic)
                self.delegate?.didReceiveMessages(messagesToShow)
                // Register the optimistic by content fingerprint so the
                // gRPC echo can find it even if it arrives before the
                // `sendMessage` RPC returns the server entryId.
                if let fingerprint = self.outgoingFingerprint(for: optimistic) {
                    self.pendingOutgoingByFingerprint[fingerprint] = tempId
                }
                // #region agent log
                AgentDebugLog.write([
                    "id": "send_optimistic_\(tempId)",
                    "hypothesisId": "H1",
                    "location": "StartViewModel.swift:548",
                    "message": "Optimistic message inserted before network send",
                    "data": [
                        "tempId": tempId,
                        "bodyType": String(describing: type(of: optimistic.body)),
                        "sendDate": optimistic.body.sendDate ?? -1,
                        "messagesArraysCount": self.messagesArrays.count,
                        "fingerprintKeys": Array(self.pendingOutgoingByFingerprint.keys)
                    ]
                ])
                // #endregion agent log
            }

            dataSource.sendMessage(messageToSend) { [weak self] result in
                guard let self = self else {
                    return
                }

                switch result {

                case .success(let entryId):
                    let id = entryId
                    // #region agent log
                    AgentDebugLog.write([
                        "id": "send_success_pre_main_\(id)",
                        "hypothesisId": "H1",
                        "location": "StartViewModel.swift:567",
                        "message": "sendMessage success callback fired (off main actor)",
                        "data": [
                            "serverEntryId": id,
                            "tempId": tempId
                        ]
                    ])
                    // #endregion agent log
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.isMessageSent = true
                        // If the echo already arrived (race), the swap has
                        // already happened and removed the fingerprint. We
                        // only need to record the server→temp mapping for
                        // future reference (e.g. delivery reports).
                        if self.pendingOutgoingByServerId[id] == nil {
                            self.pendingOutgoingByServerId[id] = tempId
                        }
                        // #region agent log
                        AgentDebugLog.write([
                            "id": "send_success_mapped_\(id)",
                            "hypothesisId": "H1",
                            "location": "StartViewModel.swift:578",
                            "message": "Recorded serverEntryId->tempId",
                            "data": [
                                "serverEntryId": id,
                                "tempId": tempId,
                                "byServerIdSize": self.pendingOutgoingByServerId.count,
                                "byFingerprintSize": self.pendingOutgoingByFingerprint.count
                            ]
                        ])
                        // #endregion agent log
                        completion(.success(nil))
                    }
                case .failure(let error):
                    let nsError = error
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        Logger.verbose(nsError)
                        self.error = nsError
                        // The optimistic insert already showed a `.sending`
                        // cell; flip it to `.notSent` in place instead of
                        // inserting a duplicate.
                        self.markOptimisticAsFailed(tempId: tempId)
                        self.delegate?.didFailToSend(tempId: tempId, status: .notSent)
                        completion(.failure(nsError))
                    }
                }
            }
        }
    }

    private func processMessageBeforeSending(messagePayload: MessageType, tempId: String,
                                             callback: @escaping (MessageType?) -> Void) {

        if case .choiceResponseMessage = messagePayload {
            callback(messagePayload)
        }


        guard let message = self.createMessage(entryId: tempId, messageType: messagePayload) else {
            callback(nil)
            return
        }

        processPluginMessage(message) { processedMessage in
            guard let processedMessage = processedMessage else {
                callback(nil)
                return
            }

            if let textMessage = processedMessage.body as? MessageText {
                callback(.text(textMessage.text))
                return
            }

            callback(messagePayload)
        }
    }
    
    func createMessage(entryId: String, messageType: MessageType) -> Message? {
        
        var messageBody: MessageBody
        let date = Int64(Date().timeIntervalSince1970)
        switch messageType {
        case .text(let text):
            messageBody = MessageText(text: text, sendDate: date)
            
        case .choiceResponseMessage(postbackData: _, entryID: _):
            return nil
            
        case .media(let message):
            
            if let messageContent = message.body as? MessageMedia {
                messageBody = messageContent
                
            } else {
                messageBody = MessageMedia(url: "", sendDate: date)
                
            }
            
        case let .location(latitude, longitude, localizationConfig):
            messageBody = MessageLocation(label: localizationConfig.outgoingLocationMessageButtonTitle,
                                          title: localizationConfig.outgoingLocationMessageTitle,
                                          latitude: Double(latitude),
                                          longitude: Double(longitude), sendDate: date)
            
        case .fallbackMessage:
            return nil
            
        case .genericEvent:
            return nil
        }
        
        return Message(entryId: entryId, owner: .outgoing, body: messageBody, status: .sending)
    }
    
    func sendEvent(_ event: EventType ) {
        
        isEventSent = false
        
        if state == .isOff {
            self.delegate?.errorSendingMessage(error: .noInternetConnection)
            return
        }
        
        dataSource.sendEvent(event) { [weak self] result in

            guard let self = self else {
                return
            }

            switch result {

            case .success():
                Task { @MainActor in
                    self.isEventSent = true
                }

            case .failure(let error):
                let nsError = error
                Task { @MainActor in
                    self.isEventSent = false
                    Logger.verbose(nsError)
                }
            }
        }
    }
    func sendMedia(_ media: MediaType, completion: @escaping @Sendable (Result<Message, Error>) -> Void) {

        if state == .isOff {
            self.delegate?.errorSendingMessage(error: .noInternetConnection)
            return
        }
        error = nil

        dataSource.uploadMedia(media) { [weak self] result in

            guard let self = self else {
                return
            }
            switch result {

            case .success(let urlString):
                let capturedURL = urlString
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if self.sendDocumentAsText {
                        completion(.success(Message(entryId: "-1", owner: .outgoing, body: MessageText(text: capturedURL), status: .sending)))
                    } else {
                        completion(.success(self.createMediaMessage(urlString: capturedURL, mediaType: media)))
                    }
                }

            case .failure(let error):
                let nsError = error
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    Logger.verbose(nsError)
                    self.error = nsError
                    completion(.failure(nsError))
                }
            }
        }
    }
    
    func createMediaMessage(urlString: String, mediaType: MediaType) -> Message {
        
        var messageBody: MessageBody
        
        switch mediaType {
        case .audio(_):
            messageBody = MessageMedia(url: urlString, sendDate: Int64(Date().timeIntervalSince1970),
                                       placeholderImage: nil, type: .audio)
        case .image(_):
            messageBody = MessageMedia(url: urlString, sendDate: Int64(Date().timeIntervalSince1970),
                                       placeholderImage: nil, type: .image)
        case .video(_):
            messageBody = MessageMedia(url: urlString, sendDate: Int64(Date().timeIntervalSince1970),
                                       placeholderImage: nil, type: .video)
            
        case .file(_, let type):
            
            if type == .gif {
                messageBody = MessageMedia(url: urlString, sendDate: Int64(Date().timeIntervalSince1970),
                                           placeholderImage: nil, type: .image)
            } else {
                messageBody = MessageMedia(url: urlString, sendDate: Int64(Date().timeIntervalSince1970),
                                           placeholderImage: nil, type: .file(type))
            }
        }
        return Message(entryId: "-1", owner: .outgoing, body: messageBody, status: .sending)
    }
    
    private func processPluginMessage(_ message: Message, callback: @escaping (Message?) -> Void) {
        Task(priority: .utility) {
            var processedMessage: Message? = message
            SinchChatSDK.shared.customMessageTypeHandlers.forEach { handler in
                if let msg = processedMessage {
                    processedMessage = handler(msg)
                }
            }
            
            if processedMessage == nil {
                callback(processedMessage)
                return
            }
            
            for handler in SinchChatSDK.shared.customMessageTypeHandlersAsync {
                if let msg = processedMessage {
                    processedMessage = await convertCallBackWithMessageToAsync(message: msg, callback: handler)
                }
            }
            
            callback(processedMessage)
        }
    }
    
    private func processPluginMessageAsync(_ message: Message) async -> Message? {
        await withCheckedContinuation { continuation in
            processPluginMessage(message) { processed in
                continuation.resume(returning: processed)
            }
        }
    }
    
    private func convertCallBackWithMessageToAsync(message: Message, callback: (Message, @escaping (Message?) -> Void) -> Void) async -> Message? {
        await withCheckedContinuation { continuation in
            callback(message) { processedMessage in
                continuation.resume(returning: processedMessage)
            }
        }
    }
}

extension DefaultStartViewModel: MessageDataSourceDelegate {

    nonisolated func subscriptionError() {
        Task { @MainActor [weak self] in
            self?.subscribeForMessages()
        }
    }
}
// swiftlint:enable file_length type_body_length
