import XCTest
@testable import SinchChatSDK

final class PushNotificationHandlerStub: PushNotificationHandler, @unchecked Sendable {

    var pushRepository: PushRepository?
    var authDataSource: AuthDataSource?
    var apiClient: APIClient?
    var permissionsStatus: SinchSDKNotificationStatus = .granted
    var unsubscribeCompletion: Result<Void, Error> = .success(())
    private var pushServices: [PushNotificationAddresseeName: PushNotificationAddressee] = [:]
    var isNotificationHandled: Bool = true
    
    var options: UNNotificationPresentationOptions?
    func sendDeviceToken(token: Data) {
        
    }
    
    func unsubscribe(_ completion: @escaping (Result<Void, Error>) -> Void) {
        completion(unsubscribeCompletion)
    }
    
    func handleNotification(payload: [AnyHashable : Any]) -> IsHandled {
        isNotificationHandled
    }
    
    func handleWillPresentNotification(_ payload: [AnyHashable : Any]) -> UNNotificationPresentationOptions? {
        options
    }
    
    func registerAddressee(_ service: PushNotificationAddressee) {
        pushServices[service.id] = service
    }
    
    func removeAddressee(_ service: PushNotificationAddressee) {
        pushServices[service.id] = nil
    }
    func getAddressee(id: PushNotificationAddresseeName) -> PushNotificationAddressee? {
        return pushServices[id]
        
    }
    func askForPermissions(completion: ((SinchSDKNotificationStatus) -> Void)?) {
        completion?(permissionsStatus)
    }
    
    func checkIfPermissionIsGranted(completion: @escaping (SinchSDKNotificationStatus) -> Void) {
        completion(permissionsStatus)
    }
}

final class MessageDataSourceStub: MessageDataSource, @unchecked Sendable {
    var topicModel: TopicModel?

    var metadata: SinchMetadataArray = []

    var shouldInitializeConversation: Bool = true

    weak var delegate: MessageDataSourceDelegate?

    private var nextPageToken: String?
    private var subscription: Bool?
    var messageCompletion: ((Result<[Message], MessageDataSourceError>) -> Void)?
    var sendMessageCompletion: Result<String, MessageDataSourceError> = .success(("1"))
    var sendEventCompletion: Result<Void, MessageDataSourceError> = .success(())
    var sendMetadataCompletion: Result<Void, MessageDataSourceError> = .success(())
    var getMessageHistoryCompletion: Result<[Message], MessageDataSourceError> = .success( [Message( entryId: "1", owner: .outgoing, body: MessageText(text: "Test", sendDate: 1637058195))])

    var subscribeMessageCompletion: Result<Message, MessageDataSourceError>  = .success( Message( entryId: "1", owner: .outgoing, body: MessageText(text: "Test", sendDate: 1637058195)))
    var sendMediaCompletion: Result<String, MessageDataSourceError> = .success(("https://res.cloudinary.com/apideck/image/upload/v1573959824/catalog/sinch/icon128x128.png"))
    var firstPage: Bool = true
    var pageSize: Int32 = 10
    var historyArray: [Message] = []

    // MARK: - Async stubs (default to throwing; tests should use the
    // completion handler entry points to retain their existing assertions).
    func uploadMedia(_ media: MediaType) async throws -> String { "" }
    func uploadMediaViaStream(_ media: MediaType) async throws -> String { "" }
    func sendMessage(_ message: MessageType) async throws -> String { "" }
    func sendEvent(_ event: EventType) async throws { }
    func subscribeForMessages() -> AsyncThrowingStream<Message, Error> {
        AsyncThrowingStream { continuation in continuation.finish() }
    }
    func getMessageHistory() async throws -> [Message] { [] }
    func sendConversationMetadata(_ metadata: SinchMetadataArray) throws { }

    func isSubscribed() -> Bool {
        subscription ?? false
    }

    func cancelCalls() {

    }
    func isFirstPage() -> Bool {
        firstPage
    }

    func subscribeForMessages(completion: @escaping (Result<Message, MessageDataSourceError>) -> Void) {

        subscription = true

        completion(subscribeMessageCompletion)

    }
    func sendMedia(_ media: MediaType, completion: @escaping (Result<String, MessageDataSourceError>) -> Void) {

        completion(sendMediaCompletion)

    }

    func getMessageHistory(completion: @escaping (Result<[Message], MessageDataSourceError>) -> Void) {
        completion(getMessageHistoryCompletion)

    }

    func sendMessage(_ message: MessageType, completion: @escaping (Result<String, MessageDataSourceError>) -> Void) {
        completion(sendMessageCompletion)

    }

    func uploadMedia(_ media: MediaType, completion: @escaping (Result<String, MessageDataSourceError>) -> Void) {
        completion(sendMediaCompletion)

    }

    func uploadMediaViaStream(_ media: MediaType, completion: @escaping (Result<String, MessageDataSourceError>) -> Void) {
        completion(sendMediaCompletion)

    }
    func cancelSubscription() {
        messageCompletion = nil
        subscription = nil
    }

    func closeChannel() {

    }

    func startChannel() {

    }

    func sendEvent(_ event: EventType, completion: @escaping (Result<Void, MessageDataSourceError>) -> Void) {
        completion(sendEventCompletion)
    }

    func sendConversationMetadata(_ metadata: SinchMetadataArray) -> Result<Void, MessageDataSourceError> {

        return sendMetadataCompletion
    }

}

class MessageDataTests: XCTestCase {
    
    var viewModel: DefaultStartViewModel!
    var dataSource: MessageDataSourceStub!
    let pushNotificationHandler: PushNotificationHandler = PushNotificationHandlerStub()
    
    override func setUp() {
        super.setUp()
        dataSource = MessageDataSourceStub()
        viewModel = .init(messageDataSource: dataSource, notificationPermission: pushNotificationHandler)
    }
    
    func testInitialization() {
        
        let viewModel = DefaultStartViewModel(messageDataSource: dataSource, notificationPermission: pushNotificationHandler)
        
        XCTAssertNotNil(viewModel, "The view model should not be nil.")
        
    }
    func testInternetConnectionStateSet() {
        
        viewModel.setInternetConnectionState(.isOn)
        XCTAssertEqual(viewModel.state, .isOn)
    }
    
    func testOnInternetWithHistory() {
        viewModel.messagesArrays = [[Message(entryId: "33", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058095))]]
        let historyArray = [ Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195)),
                             Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058295))]
        dataSource.getMessageHistoryCompletion = .success(historyArray)
        dataSource.historyArray = historyArray
        dataSource.pageSize = 10
        dataSource.subscribeMessageCompletion = .success(Message(entryId: "3", owner: .outgoing, body: MessageText(text: "Test 3", sendDate: 1637058295)))
        
        viewModel.onInternetOn()
        
     //   XCTAssertEqual(viewModel.messagesArrays.flatMap({ $0 }).count, historyArray.count + 1)
        XCTAssertEqual(dataSource.isSubscribed(), true)
        XCTAssertEqual(SinchChatSDK.shared._chat.state, .running)
    }
    
    func testOnInternet() {
        
        let historyArray = [ Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195)),
                             Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058295))]
        dataSource.getMessageHistoryCompletion = .success(historyArray)
        
        dataSource.historyArray = historyArray
        dataSource.pageSize = 10
        dataSource.subscribeMessageCompletion = .success(Message(entryId: "3", owner: .outgoing, body: MessageText(text: "Test 3", sendDate: 1637058295)))
        
        viewModel.onInternetOn()
        
    //    XCTAssertEqual(viewModel.messagesArrays.flatMap({ $0 }).count, historyArray.count + 1)
        XCTAssertEqual(dataSource.isSubscribed(), true)
        XCTAssertEqual(SinchChatSDK.shared._chat.state, .running)
    }
    
    func testOnLoad() {
        let historyArray = [ Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195)),
                             Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058295))]
        dataSource.getMessageHistoryCompletion = .success(historyArray)

        dataSource.historyArray = historyArray
        dataSource.pageSize = 10
        dataSource.subscribeMessageCompletion = .success(Message(entryId: "3", owner: .outgoing, body: MessageText(text: "Test 3", sendDate: 1637058295)))
        
        viewModel.onLoad()
        
      //  XCTAssertEqual(viewModel.messagesArrays.flatMap({ $0 }).count, historyArray.count + 1)
        XCTAssertEqual(dataSource.isSubscribed(), true)
        XCTAssertEqual(SinchChatSDK.shared._chat.state, .running)
    }
    
    func testOnDisappear() {
        
        viewModel.onDisappear()
        XCTAssertEqual(dataSource.isSubscribed(), false)
        XCTAssertEqual(SinchChatSDK.shared._chat.state, .idle)
        XCTAssertEqual(viewModel.isMessageSent, false)
        XCTAssertNil(viewModel.error)
        XCTAssertEqual(viewModel.messagesArrays.count, 0)
        
    }
    func testOnDidEnterBackground() {
        
        viewModel.onDidEnterBackground()
        XCTAssertEqual(dataSource.isSubscribed(), false)
        XCTAssertEqual(SinchChatSDK.shared._chat.state, .idle)
        XCTAssertEqual(viewModel.isMessageSent, false)
        XCTAssertNil(viewModel.error)
        XCTAssertEqual(viewModel.messagesArrays.count, 0)
        
    }
    func testonWillEnterForeground() {
        let historyArray = [ Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195)),
                             Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058295))]
        dataSource.getMessageHistoryCompletion = .success(historyArray)
        dataSource.historyArray = historyArray
        dataSource.pageSize = 10
        dataSource.subscribeMessageCompletion = .success(Message(entryId: "3", owner: .outgoing, body: MessageText(text: "Test 3", sendDate: 1637058295)))
        
        viewModel.onWillEnterForeground()
        _ = XCTWaiter.wait(for: [expectation(description: "Wait for 0.6 seconds")], timeout:0.6)
        
    //    XCTAssertEqual(viewModel.messagesArrays.flatMap({ $0 }).count, historyArray.count + 1)
        XCTAssertEqual(dataSource.isSubscribed(), true)
        XCTAssertEqual(SinchChatSDK.shared._chat.state, .running)
        
    }

    
    func testOnInternetOn() {
        let historyArray = [ Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195)),
                             Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058295))]
        dataSource.getMessageHistoryCompletion = .success(historyArray)
        dataSource.historyArray = historyArray
        dataSource.pageSize = 10
        dataSource.subscribeMessageCompletion = .success(Message(entryId: "3", owner: .outgoing, body: MessageText(text: "Test 3", sendDate: 1637058295)))
        
        viewModel.onInternetOn()

     //   XCTAssertEqual(viewModel.messagesArrays.flatMap({ $0 }).count, historyArray.count + 1)
        XCTAssertEqual(dataSource.isSubscribed(), true)
        XCTAssertEqual(SinchChatSDK.shared._chat.state, .running)
        
    }
    
    func testOnInternetLost() {
        
        viewModel.onInternetLost()
        XCTAssertEqual(dataSource.isSubscribed(), false)
        XCTAssertEqual(SinchChatSDK.shared._chat.state, .idle)
        XCTAssertEqual(viewModel.isMessageSent, false)
        XCTAssertNil(viewModel.error)
        
    }
    func testTypingEventStartSuccess() {
        let event = Message(entryId: "1", owner: .incoming(nil), body: MessageEvent(type: .composeStarted, sendDate: 1637058195))
        dataSource.subscribeMessageCompletion = .success(event)
        viewModel.subscribeForMessages()
        _ = XCTWaiter.wait(for: [expectation(description: "Wait for 0.6 seconds")], timeout:0.6)

        XCTAssertTrue(viewModel.isTypingIndicatorVisible)
        
    }
    
    func testTypingEventEndSuccess() {
        let event = Message(entryId: "1", owner: .incoming(nil), body: MessageEvent(type: .composeEnd, sendDate: 1637058195))
        dataSource.subscribeMessageCompletion = .success(event)
        viewModel.subscribeForMessages()
        
        XCTAssertFalse(viewModel.isTypingIndicatorVisible)
        
    }
    func testMessageStreamSuccess() {
        let message = Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test", sendDate: 1637058195))
        dataSource.subscribeMessageCompletion = .success(message)
        viewModel.subscribeForMessages()
        _ = XCTWaiter.wait(for: [expectation(description: "Wait for 0.3 seconds")], timeout:0.3)

        XCTAssertEqual(viewModel.messagesArrays.count, 1)
        
    }
    func testMessageStreamSubdcriptionErrorSuccess() {
        let message = Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test", sendDate: 1637058195))
        dataSource.subscribeMessageCompletion = .success(message)
        viewModel.subscriptionError()
        _ = XCTWaiter.wait(for: [expectation(description: "Wait for 0.3 seconds")], timeout:0.3)

        XCTAssertEqual(viewModel.messagesArrays.count, 1)
        
    }
        
    func testMessageStreamError() {
        dataSource.subscribeMessageCompletion = .failure(.unknown(NSError(domain: "", code: -1, userInfo: nil)))
        viewModel.subscribeForMessages()
        XCTAssertNotNil(viewModel.error)
        
    }
    
    func testSuccessfulySendingTextMessage() {
        dataSource.sendMessageCompletion = .success(("1"))
        viewModel.sendMessage(.text("Test 1"), completion: { _ in
        
            XCTAssertTrue(self.viewModel.isMessageSent)

        })
    }
    func testFailureSendingTextMessage() {
        dataSource.sendMessageCompletion = .failure(.unknown(NSError(domain: "", code: -1, userInfo: nil)))
        viewModel.sendMessage(.text("Test 1"), completion: { _ in
            XCTAssertNotNil(self.viewModel.error)

        })
    }
    func testSuccessfulySendingLocationMessage() {
        dataSource.sendMessageCompletion = .success(("1"))
        viewModel.sendMessage(.location(latitude: 19.34, longitude: 22.33, localizationConfig: .defaultValue),
                              completion: {_ in
            XCTAssertTrue(self.viewModel.isMessageSent)
        })
    }
    
    func testStateOffWhenSendingMessage() {
        viewModel.setInternetConnectionState(.isOff)
        dataSource.sendMessageCompletion = .success(("1"))
        viewModel.sendMessage(.text("Test 2"), completion: {_ in})
        XCTAssertFalse(viewModel.isMessageSent)
        
    }
    func testSuccesfullyImageUpload() {
        dataSource.sendMessageCompletion = .success(("1"))
        dataSource.sendMediaCompletion = .success("image url")
        let image = UIImage(named: "photoIcon", in: Bundle.staticBundle, compatibleWith: nil)!
        viewModel.sendMedia(.image(image), completion: {result in
            switch result {
            case .success(let message):
                self.viewModel.sendMessage(.media(message: message ), completion: {_ in
                    XCTAssertTrue(self.viewModel.isMessageSent)

                })
                
            case .failure(let error):
                break
            }
        })
        
    }
    
    func testStateOffWhenImageUpload() {
        viewModel.setInternetConnectionState(.isOff)
        dataSource.sendMessageCompletion = .success(("1"))
        dataSource.sendMediaCompletion = .success("image url")
        let image = UIImage(named: "photoIcon", in: Bundle.staticBundle, compatibleWith: nil)!
        viewModel.sendMedia(.image(image), completion: {result in
            switch result {
            case .success(let message):
                self.viewModel.sendMessage(.media(message: message ), completion: {_ in
                    XCTAssertTrue(self.viewModel.isMessageSent)

                })
            case .failure(let error):
                break
            }
        })
                
    }
    
    func testSuccesfullyVideoUpload() {
        dataSource.sendMessageCompletion = .success(("1"))
        dataSource.sendMediaCompletion = .success("video url")
        let videoUrl = URL(string: "testurl")!
        viewModel.sendMedia(.video(videoUrl), completion: {result in
            switch result {
            case .success(let message):
                self.viewModel.sendMessage(.media(message: message ), completion: {_ in
                    XCTAssertTrue(self.viewModel.isMessageSent)

                })
            case .failure(_):
                break
            }
        })
                
    }
    func testSuccesfullyAudioUpload() {
        dataSource.sendMessageCompletion = .success(("1"))
        dataSource.sendMediaCompletion = .success("video url")
        let audioUrl = URL(string: "testurl")!
        viewModel.sendMedia(.audio(audioUrl), completion: {result in
            switch result {
            case .success(let message):
                self.viewModel.sendMessage(.media(message: message ), completion: {_ in
                    XCTAssertTrue(self.viewModel.isMessageSent)

                })
            case .failure(_):
                break
            }
        })
        

    }
    func testErrorImageUpload() {
        
        dataSource.sendMediaCompletion = .failure(.unknown(NSError(domain: "", code: -1, userInfo: nil)))
        let image = UIImage(named: "photoIcon", in: Bundle.staticBundle, compatibleWith: nil)!
        viewModel.sendMedia(.image(image), completion: {_ in})
        XCTAssertNotNil(viewModel.error)
    }
    func testSuccessfulySendingEvent() {
        
        dataSource.sendEventCompletion = .success(())
        viewModel.sendEvent(.composeStarted)
        XCTAssertTrue(viewModel.isEventSent)
        
    }
    func testErrorSendingEvent() {
        
        dataSource.sendEventCompletion = .failure(.unknown(NSError(domain: "", code: -1, userInfo: nil)))
        viewModel.sendEvent(.composeStarted)
        XCTAssertFalse(viewModel.isEventSent)
        
    }
    func testStateOffWhenSendingEvent() {
        viewModel.setInternetConnectionState(.isOff)
        dataSource.sendEventCompletion = .success(())
        viewModel.sendEvent(.composeStarted)
        XCTAssertFalse(viewModel.isMessageSent)
        
    }
    
//    func testLoadMessagesFromHistoryLessThenPageSize() {
//        
//        let historyArray = [ Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195)),
//                             Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058295)),
//                             Message(entryId: "3", owner: .system,
//                                     body: MessageEvent(type: .joined(Agent(name: "John", type: 1, pictureUrl: nil)), sendDate: 1637058345)),
//                             Message(entryId: "4", owner: .incoming(.init(name: "Sinch", type: 1)), body: MessageText(text: "Test 3", sendDate: 1637058350)),
//                             Message(entryId: "5", owner: .incoming(.init(name: "Sinch", type: 1)),
//                                     body: MessageText(text: "Test 4",
//                                                       sendDate: 1637058350))]
//        dataSource.getMessageHistoryCompletion = .success(historyArray)
//        dataSource.historyArray = historyArray
//        dataSource.pageSize = 10
//        viewModel.loadHistory()
//    //    viewModel.dataSource.getMessageHistory { [weak self] messages in
//            
//            XCTAssertEqual(viewModel.messagesArrays.flatMap({ $0 }).count, historyArray.count)
//        }
//        
//    }
//    func testLoadFirstPageFromHistory() {
//        
//        let pageSize: Int32 = 10
//        
//        let historyArray = [ Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195)),
//                             Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058295)),
//                             Message(entryId: "3", owner: .system, body: MessageEvent(type: .joined(Agent(name: "John",
//                                                                                                          type: 1,
//                                                                                                          pictureUrl: nil)),
//                                                                                      sendDate: 1637058345)),
//                             Message(entryId: "4", owner: .incoming(.init(name: "Sinch", type: 1)), body: MessageText(text: "Test 3",
//                                                                                                                      sendDate: 1637058350)),
//                             Message(entryId: "5", owner: .incoming(.init(name: "Sinch", type: 1)),
//                                     body: MessageText(text: "Test 4",
//                                                       sendDate: 1637058350)),
//                             
//                             Message(entryId: "6", owner: .outgoing, body: MessageText(text: "Test 5", sendDate: 1637058195)),
//                             Message(entryId: "7", owner: .outgoing, body: MessageText(text: "Test 6", sendDate: 1637058300)),
//                             Message(entryId: "8", owner: .outgoing, body: MessageText(text: "Test 7", sendDate: 1637058400)),
//                             Message(entryId: "9", owner: .outgoing, body: MessageText(text: "Test 8", sendDate: 1637058450)),
//                             Message(entryId: "10", owner: .outgoing, body: MessageText(text: "Test 9", sendDate: 1637058500)),
//                             Message(entryId: "11", owner: .outgoing, body: MessageText(text: "Test 10", sendDate: 1637058501)) ]
//        dataSource.getMessageHistoryCompletion = .success(historyArray.suffix(Int(pageSize)))
//        dataSource.historyArray = historyArray
//        dataSource.pageSize = pageSize
//        viewModel.loadHistory()
//        
//        XCTAssertEqual(viewModel.messagesArrays.flatMap({ $0 }).count, Int(pageSize))
//        
//    }
//    func testFailureToLoadFirstPageFromHistory() {
//
//        let pageSize: Int32 = 10
//
//        let historyArray = [ Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195)),
//                             Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058295))]
//        dataSource.getMessageHistoryCompletion = .failure(.unknown(NSError(domain: "", code: -1, userInfo: nil)))
//
//        dataSource.historyArray = historyArray
//        dataSource.pageSize = pageSize
//        viewModel.loadHistory()
//        XCTAssertNotNil(viewModel.error)
//
//    }
//    func testLoadAllHistory() {
//
//        let historyArray = [ Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195)),
//                             Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058295)),
//                             Message(entryId: "3", owner: .system,
//                                     body: MessageEvent(type: .joined(Agent(name: "John", type: 1, pictureUrl: nil)),sendDate: 1637058345)),
//                             Message(entryId: "4", owner: .incoming(.init(name: "Sinch", type: 1)),
//                                     body: MessageText(text: "Test 3", sendDate: 1637058350)),
//                             Message(entryId: "5", owner: .incoming(.init(name: "Sinch", type: 1)),
//                                     body: MessageText(text: "Test 4", sendDate: 1637058350)),
//                             Message(entryId: "6", owner: .outgoing, body: MessageText(text: "Test 5", sendDate: 1637058195)),
//                             Message(entryId: "7", owner: .outgoing, body: MessageText(text: "Test 6", sendDate: 1637058300)),
//                             Message(entryId: "8", owner: .outgoing, body: MessageText(text: "Test 7", sendDate: 1637058400)),
//                             Message(entryId: "9", owner: .outgoing, body: MessageText(text: "Test 8", sendDate: 1637058450)),
//                             Message(entryId: "10", owner: .outgoing, body: MessageText(text: "Test 9", sendDate: 1637058500)),
//                             Message(entryId: "11", owner: .outgoing, body: MessageText(text: "Test 10", sendDate: 1637058501)),
//                             Message(entryId: "12", owner: .outgoing, body: MessageText(text: "Test 11", sendDate: 1637058501))
//        ]
//
//        dataSource.historyArray = historyArray
//        dataSource.pageSize = 10
//        dataSource.getMessageHistoryCompletion = .success(Array(historyArray.prefix(Int(dataSource.pageSize))))
//
//        viewModel.loadHistory()
//        dataSource.getMessageHistoryCompletion = .success(Array(historyArray.suffix(from: 10)))
//        dataSource.firstPage = false
//        viewModel.loadHistory()
//        dataSource.getMessageHistoryCompletion = .success([])
//
//        viewModel.loadHistory()
//
//
//        XCTAssertEqual(viewModel.messagesArrays.flatMap({ $0 }).count, historyArray.count)
//
//    }
    
    func testMessageProcessingFromSameDayInHistory() {
        
        let historyArray = [ Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195)),
                             Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058295)),
                             Message(entryId: "3", owner: .system, body: MessageEvent(type: .joined(Agent(name: "John",
                                                                                                          type: 1,
                                                                                                          pictureUrl: nil)),
                                                                                      sendDate: 1637058345)),
                             Message(entryId: "4", owner: .incoming(.init(name: "Sinch", type: 1)), body: MessageText(text: "Test 3",
                                                                                                                      sendDate: 1637058350)),
                             Message(entryId: "5", owner: .incoming(.init(name: "Sinch", type: 1)),
                                     body: MessageText(text: "Test 4",
                                                       sendDate: 1637058350))]
        
        viewModel.processHistoryMessages(historyArray) { result in
           
            XCTAssertEqual(result.count, historyArray.count + 1)
            
        }
        
    }
    func testMessageProcessingFromDifferentDaysInHistory() {
        viewModel.messagesArrays = [[Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058095))]]
        let historyArray = [ Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 21", sendDate: 1637058195)),
                             Message(entryId: "3", owner: .outgoing, body: MessageText(text: "Test 23", sendDate: 1637001212))
        ]
        
        viewModel.processHistoryMessages(historyArray) { result in
           
            XCTAssertEqual(result.count, historyArray.count + 2)
            
        }
    }
    
    func testNewMessageProcessingFromSameDay() {
        
        let historyArray = [ Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195)),
                             Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058295)),
                             Message(entryId: "3", owner: .system, body: MessageEvent(type: .joined(Agent(name: "John",
                                                                                                          type: 1,
                                                                                                          pictureUrl: nil)),
                                                                                      sendDate: 1637058345)),
                             Message(entryId: "4", owner: .incoming(.init(name: "Sinch", type: 1)), body: MessageText(text: "Test 3",
                                                                                                                      sendDate: 1637058350)),
                             Message(entryId: "5", owner: .incoming(.init(name: "Sinch", type: 1)),
                                     body: MessageText(text: "Test 4",
                                                       sendDate: 1637058350))]
        
        viewModel.processHistoryMessages(historyArray) {_ in
            
            let newMessagesArray = self.viewModel.processNewMessages( Message(entryId: "6", owner: .incoming(.init(name: "Sinch", type: 1)),
                                                                         body: MessageText(text: "New Message",
                                                                                           sendDate: 1637058351)))

            XCTAssertEqual(newMessagesArray.count, 1)
        }
        
       
    }
    
    func testNewMessageProcessingFromNewDay() {
        
        let historyArray = [ Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195)),
                             Message(entryId: "2", owner: .outgoing, body: MessageText(text: "Test 2", sendDate: 1637058295)),
                             Message(entryId: "3", owner: .system, body: MessageEvent(type: .joined(Agent(name: "John",
                                                                                                          type: 1,
                                                                                                          pictureUrl: nil)),
                                                                                      sendDate: 1637058345)),
                             Message(entryId: "4", owner: .incoming(.init(name: "Sinch", type: 1)), body: MessageText(text: "Test 3",
                                                                                                                      sendDate: 1637058350)),
                             Message(entryId: "5", owner: .incoming(.init(name: "Sinch", type: 1)),
                                     body: MessageText(text: "Test 4",
                                                       sendDate: 1637058350))]
        
        viewModel.processHistoryMessages(historyArray) { _ in
            
            let newMessagesArray = self.viewModel.processNewMessages( Message(entryId: "6", owner: .outgoing, body: MessageText(text: "Message from different day", sendDate: 1638068295)))
            XCTAssertEqual(newMessagesArray.count, 2)
        }
       
    }
}
