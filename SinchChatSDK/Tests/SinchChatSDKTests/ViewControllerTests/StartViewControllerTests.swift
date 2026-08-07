import XCTest
@testable import SinchChatSDK

final class StartViewModelStub: StartViewModel, @unchecked Sendable {
    var sendDocumentAsText: Bool = false
    
    var isStartedFromInbox: Bool = false
    
    
    var delegate: StartViewModelDelegate?
    
    func setInternetConnectionState(_ state: InternetConnectionState) {
        
    }
    
    func sendMedia(_ media: MediaType, completion: @escaping (Result<Message, Error>) -> Void) {
        completion(.success(Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195))))
    }
    
    func sendMessage(_ message: MessageType, completion: @escaping (Result<Message?, Error>) -> Void) {
        completion(.success(Message(entryId: "1", owner: .outgoing, body: MessageText(text: "Test 1", sendDate: 1637058195))))
        
    }
    
    func loadHistory() {
        
    }
    
    func onLoad() {
        
    }
    
    func onDisappear() {
        
    }
    
    func onWillEnterForeground() {
        
    }
    
    func onDidEnterBackground() {
        
    }
    
    func onInternetLost() {
        
    }
    
    func onInternetOn() {
        
    }
    
    func closeChannel() {
        
    }
    func getChatOptions() -> SinchChatOptions {
        return SinchChatOptions()
    }
    
    func processNewMessages(_ message: Message) -> [Message] {
        
        return []
    }
    
    func sendEvent(_ event: EventType) {
        
    }
    
    func subscriptionError() {
        
    }
}
final class StartViewControllerTests: XCTestCase {

    var startViewModel: StartViewModelStub!
    
    override func setUp() {
        super.setUp()
        startViewModel = StartViewModelStub()

    }
    func makeSUT() -> StartViewController {
        let startViewController = StartViewController(viewModel: startViewModel, view: .init(uiConfiguration: .defaultValue, localizationConfiguration:  .defaultValue))
        return startViewController
    }
    func testInit() {
        let sut = makeSUT()

        XCTAssertNotNil(sut.mainView)
        XCTAssertNotNil(sut.mainView.collectionView)
        XCTAssertNotNil(sut.refreshControl)
        XCTAssertNotNil(sut.viewModel)
        XCTAssertNotNil(sut.imagePickerHelper)
        XCTAssertNotNil(sut.player)
        XCTAssertNotNil(sut.audioSessionController)
        
    }
    
    func testViewDidLoadUISetUp() throws {
      
        let sut = makeSUT()
        sut.viewDidLoad()
        
        XCTAssertEqual(sut.navigationItem.title, sut.mainView.localizationConfiguration.navigationBarText)
     
    }

    func testViewWillAppearUISetUp() throws {
        let sut = makeSUT()

        sut.viewWillAppear(true)
        let unwrappedForegroundColor = try XCTUnwrap(sut.navigationItem.standardAppearance?.titleTextAttributes[NSAttributedString.Key.foregroundColor])
        let unwrappedFont = try XCTUnwrap(sut.navigationItem.standardAppearance?.titleTextAttributes[NSAttributedString.Key.font]  as? UIFont)
        let unwrappedBackgroundColor = try XCTUnwrap(sut.navigationItem.standardAppearance?.backgroundColor)
        
        XCTAssertEqual(unwrappedForegroundColor as! UIColor, sut.mainView.uiConfig.navigationBarTitleColor)
        XCTAssertEqual(unwrappedFont, UIFont.boldSystemFont(ofSize: 16))
        XCTAssertEqual(unwrappedBackgroundColor, sut.mainView.uiConfig.navigationBarColor)

    }
    func testViewWillDisappearAppearUISetUp() {
        let sut = makeSUT()
        sut.viewWillDisappear(true)
        XCTAssertTrue(sut.isMessagesControllerBeingDismissed)
       
    }
    func testViewDidDisappearAppearUISetUp() {
        let sut = makeSUT()
        sut.viewDidDisappear(true)
        XCTAssertFalse(sut.isMessagesControllerBeingDismissed)
       
    }
   
}
