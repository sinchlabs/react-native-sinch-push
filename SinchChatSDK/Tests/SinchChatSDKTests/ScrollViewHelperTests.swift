import XCTest
@testable import SinchChatSDK

final class ScrollViewHelperTests: XCTestCase {

    func testGetZeroTargetContentOffset() throws {
        
        let offset = ScrollViewHelper.getTargetContentOffset(scrollView: UIScrollView(),
                                                             velocity: CGPoint(x: 0, y: 0), pageWidth: 300.0)
        XCTAssertTrue(offset == 0)
        
    }
    func testGetNegativeXTargetContentOffset() throws {
        let scrollView = UIScrollView()
        scrollView.contentSize = .init(width: 900.00, height: 500)
        scrollView.contentOffset = CGPoint(x: 800, y: 0)
        let offset = ScrollViewHelper.getTargetContentOffset(scrollView: scrollView,
                                                             velocity: CGPoint(x: -5, y: 0), pageWidth: 300.0)
        XCTAssertTrue(offset == 300)
       
    }
    func testGetPositiveXTargetContentOffset() throws {
        
        let offset = ScrollViewHelper.getTargetContentOffset(scrollView: UIScrollView(),
                                                             velocity: CGPoint(x: 310, y: 0), pageWidth: 300.0)
        XCTAssertTrue(offset == 0)
       
    }
    
    func testCurrentPage() throws {
        let scrollView = UIScrollView()
        
        scrollView.contentOffset = CGPoint(x: 300, y: 0)
        let page = ScrollViewHelper.getCurrentPage(scrollView:scrollView, pageWidth: 300.0)
        XCTAssertTrue(page == 1)
       
    }
}
