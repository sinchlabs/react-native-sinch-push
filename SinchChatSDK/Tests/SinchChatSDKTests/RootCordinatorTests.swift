//
//  RootCordinatorTests.swift
//  
//
//  Created by MacBookPro on 6.4.23..
//

import XCTest
@testable import SinchChatSDK
import GRPCCore

final class MockAuthDataSource: AuthDataSource, @unchecked Sendable {
    var currentAuthorization: AuthModel?

    var isLoggedIn: Bool = false

    var identityHashValue: String?

    var currentConfigID: String = ""

    var generateTokenCompletion: Result<AuthModel, AuthRepositoryError> = .success((AuthModel(accessToken: "",sinchIdentity: .anonymous, clientID: "", projectID: "", configID: "", region: .EU1)))
    var isTokenDeleted = false

    func generateToken(config: SinchSDKConfig.AppConfig, identity: SinchSDKIdentity) async throws -> AuthModel {
        isLoggedIn = true
        switch generateTokenCompletion {
        case .success(let token): return token
        case .failure(let error): throw error
        }
    }

    func generateToken(config: SinchSDKConfig.AppConfig, identity: SinchSDKIdentity, completion: @escaping @Sendable (Result<AuthModel, AuthRepositoryError>) -> Void) {
        isLoggedIn = true
        completion(generateTokenCompletion)
    }

    func currentAccessToken() throws -> String {
        "token"
    }

    func deleteToken() {
        isLoggedIn = true
    }
}

final class RootCordinatorTests: XCTestCase {
    var rootCordinator: RootCoordinator!
    
    override func setUpWithError() throws {
        rootCordinator = DefaultRootCoordinator(messageDataSource: MessageDataSourceStub(), authDataSource: MockAuthDataSource(), pushPermissionHandler: PushNotificationHandlerStub())
    }

    func testCreatingOfChatViewController() {
        let viewController =  rootCordinator.getRootViewController(uiConfig: .defaultValue, localizationConfig: .defaultValue, sendDocumentAsText: false)
        XCTAssertNotNil(viewController)

    }
    func testCreatingOfMediaViewController() {
        let url = URL(string: "https://www.google.com")!
        let viewController =  rootCordinator.getMediaViewerController(uiConfig: .defaultValue, localizationConfig: .defaultValue, url: url)
        XCTAssertNotNil(viewController)

    }
    func testCreatingOfLocationViewController() {
        let viewController =  rootCordinator.getLocationViewController(uiConfig: .defaultValue, localizationConfig: .defaultValue)
        XCTAssertNotNil(viewController)

    }
}
