import XCTest
@testable import SinchChatSDK

final class MockMediaViewerViewModel: MediaViewerViewModel {
      
    weak var delegate: MediaViewerModelDelegate?
    var url: URL
    var isClosed: Bool = false
   
    init(url: URL) {
        self.url = url
    }
    
    func setIsClosed() {
        isClosed = false
    }
   
}

final class MediaViewerViewModelTests: XCTestCase {

    var mediaModel: MockMediaViewerViewModel!
    
    override func setUp() {
        super.setUp()
        var url = URL(string: "https://testurl")!
        mediaModel = .init(url: url)
        // Put setup code here. This method is called before the invocation of each test method in the class.

    }
    func makeSUT() -> MediaViewerController {
        let mediaViewController = MediaViewerController(
            viewModel: mediaModel,
            view: .init(uiConfiguration: .defaultValue, localizationConfiguration:  .defaultValue))
        return mediaViewController
    }
    
    func testViewDidLoadUISetUp() {
        let sut = makeSUT()
        
        sut.viewDidLoad()
            
        let swipeGestureRecognizer = sut.view.gestureRecognizers?.first as? UISwipeGestureRecognizer
        XCTAssertNotNil(swipeGestureRecognizer, "Missing swipe gesture")
    }

    func testViewWillAppearUISetUp() {
        let sut = makeSUT()
        
        sut.viewWillAppear(true)
        
        XCTAssertNotNil(sut.navigationItem.leftBarButtonItem)
    }
}
