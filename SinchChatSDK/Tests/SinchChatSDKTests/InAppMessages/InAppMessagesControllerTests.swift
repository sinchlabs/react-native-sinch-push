//
//  InAppMessagesControllerTests.swift
//  
//
//  Created by MacBookPro on 11.4.23..
//

import XCTest
@testable import SinchChatSDK

final class InAppMessagesControllerTests: XCTestCase {

    var inAppController: DefaultInAppMessageController!
    
    override func setUpWithError() throws {
        
        inAppController = .init(pushNotificationHandler: PushNotificationHandlerStub())
        
    }
    func testFailureShowInAppMessage() {
        
        var isShowned = inAppController.showInAppMessage(messagePayload: [:])
  
        XCTAssertFalse(isShowned)
        XCTAssertEqual(inAppController.queue.count, 0)

    }
    func testShowInAppMessage() {
        
//        var isShowned = inAppController.showInAppMessage(messagePayload: [:])
//
//        XCTAssertFalse(isShowned)
//        XCTAssertEqual(inAppController.queue.count, 1)

    }
    func testCloseInAppMessage() {
        var message = Message(entryId: "1",
                              owner: .incoming(nil),
                              body: MessageText(text: "test", sendDate: Int64(Date().timeIntervalSince1970)))
        inAppController.queue = [message]
        inAppController.closeMessage(message)
        
        XCTAssertEqual(inAppController.queue.count, 0)

    }
//    func closeMessage(_ message: Message) {
//
//        DispatchQueue.main.asyncAfter(deadline: .now() + presentNewInAppMessageAfterInSec) {  [weak self] in
//
//            guard let self = self else { return }
//
//            guard let nextMessage = self.queue.first else { return }
//
//            self.presentInAppMessage(nextMessage)
//
//        }
//    }
    
    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

}
