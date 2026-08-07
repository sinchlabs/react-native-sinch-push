import XCTest
import GRPCCore
import Logging

@testable import SinchChatSDK

class PushNofiticationPermissionHandlerStub : PushNofiticationPermissionHandler {
    
    var askForPermissionsCompletion: SinchSDKNotificationStatus = .granted
    
    var checkIfPermissionIsGranted: SinchSDKNotificationStatus = .granted

    
    
    func askForPermissions(completion: ((SinchSDKNotificationStatus) -> Void)?) {
        completion?(checkIfPermissionIsGranted)
    }

    func checkIfPermissionIsGranted(completion: @escaping (SinchSDKNotificationStatus) -> Void) {
        completion(checkIfPermissionIsGranted)
    }
}

final class SinchChatTests: XCTestCase {

    var sinchChat: DefaultSinchChat!
    
    override func setUpWithError() throws {
        sinchChat = DefaultSinchChat(pushPermissionHandler: PushNofiticationPermissionHandlerStub())
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    func testSetStateChannel() {
        sinchChat.state = .running
        
        XCTAssertEqual(sinchChat.getChatState(), .running)
    }
    func testSetStateChannel1() {
        sinchChat.state = .running
        
        XCTAssertEqual(sinchChat.getChatState(), .running)
    }
}
