import XCTest
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCNIOTransportHTTP2Posix

@testable import SinchChatSDK

final class PushRepositoryTests: XCTestCase {

    func testSendDeviceTokenUsesInjectedPushClient() async {
        let client = RecordingPushAPIClient()
        let repository = DefaultPushRepository(
            region: .EU1,
            authDataSource: MockAuthDataSource(),
            client: client
        )

        do {
            try await repository.sendDeviceToken(token: "device-token")
            XCTFail("Expected injected client error")
        } catch PushAPIClientTestError.calledWithClient {
            XCTAssertTrue(client.didCallWithClient)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnsubscribeUsesInjectedPushClientAndPreservesSuccessSemantics() async throws {
        let client = RecordingPushAPIClient()
        let repository = DefaultPushRepository(
            region: .EU1,
            authDataSource: MockAuthDataSource(),
            client: client
        )

        try await repository.unsubscribe("device-token")

        XCTAssertTrue(client.didCallWithClient)
    }

    func testReplyToTextChoiceCompletesWithoutTransport() async throws {
        let repository = DefaultPushRepository(
            region: .EU1,
            authDataSource: MockAuthDataSource(),
            client: RecordingPushAPIClient()
        )

        try await repository.replyToMessageWithTextChoice(choice: ChoiceText(text: "Yes", postback: "yes", entryID: "entry"))
    }
}

private enum PushAPIClientTestError: Error {
    case calledWithClient
}

private final class RecordingPushAPIClient: PushAPIClient, @unchecked Sendable {
    private(set) var didCallWithClient = false

    func withClient<Result: Sendable>(
        handle: (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        didCallWithClient = true
        throw PushAPIClientTestError.calledWithClient
    }

    func closeChannel() {}
}