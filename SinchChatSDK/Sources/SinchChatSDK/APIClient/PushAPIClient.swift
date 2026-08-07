import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCNIOTransportHTTP2Posix

/// Abstraction over the push gRPC transport.
protocol PushAPIClient: Sendable {
    func withClient<Result: Sendable>(handle: (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> Result) async throws -> Result

    func closeChannel()
}

final class DefaultPushAPIClient: PushAPIClient, @unchecked Sendable {

    private let host: String
    private let port: Int

    init?(region: Region) {
        switch region {
        case .EU1:
            self.host = "grpc.sinch-push.prod.sinch.com"
            self.port = 443
        case .US1:
            self.host = "grpc.sinch-push.us1.prod.sinch.com"
            self.port = 443
        case .custom(_, let host, _, _):
            self.host = host
            self.port = 443
        }

        guard (try? Self.makeTransport(host: self.host, port: self.port)) != nil else {
            return nil
        }
    }

    deinit {
        closeChannel()
    }

    func closeChannel() {
        // `withGRPCClient` owns per-call client lifetimes.
    }

    func withClient<Result: Sendable>(handle: (GRPCClient<HTTP2ClientTransport.Posix>) async throws -> Result) async throws -> Result {
        let transport = try Self.makeTransport(host: host, port: port)
        return try await withGRPCClient(transport: transport, handleClient: { grpcClient in
            try await handle(grpcClient)
        })
    }

    // MARK: - Private

    private static func makeTransport(host: String, port: Int) throws -> HTTP2ClientTransport.Posix {
        let target: any ResolvableTarget = .dns(host: host, port: port)
        return try HTTP2ClientTransport.Posix(
            target: target,
            transportSecurity: .tls,
            config: .defaults
        )
    }
}
