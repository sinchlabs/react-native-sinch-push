import XCTest

@testable import SinchChatSDK

final class ApiClientTests: XCTestCase {

    var client: APIClient?

    override func tearDown() {
        super.tearDown()
        client?.closeChannel()
        client = nil
    }

    func testInititializationEU() {
        client = Default2APIClient(region: .EU1)

        XCTAssertNotNil(client)
        XCTAssertTrue(client?.isChannelStarted ?? false)

    }
    func testInititializationUS() {

        self.client = Default2APIClient(region: .US1)

        XCTAssertNotNil(client)
        XCTAssertTrue(client?.isChannelStarted ?? false)

    }
    func testInititializationCustom() {

        client = Default2APIClient(region: .custom(
            host: "sdk.sinch-chat.unauth.prod.sinch.com",
            pushAPIHost: "",
            port: nil,
            isSecure: true
        ))

        XCTAssertNotNil(client)
        XCTAssertTrue(client?.isChannelStarted ?? false)
    }

    func testStartingChannelInitialization() {
        client = Default2APIClient(region: .EU1)
        client?.closeChannel()
        client?.startChannel()

        XCTAssertNotNil(client)
        XCTAssertTrue(client?.isChannelStarted ?? false)

    }
    func testCloseChannel() {
        client = Default2APIClient(region: .EU1)
        client?.closeChannel()

        XCTAssertTrue(client?.isChannelStarted ?? false)
    }
}
