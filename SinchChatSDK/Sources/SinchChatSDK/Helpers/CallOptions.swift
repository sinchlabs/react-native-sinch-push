import UIKit
import GRPCCore

extension CallOptions {

    /// Base "standard" call options used by all RPCs. Holds non-metadata
    /// options. Per-request metadata (e.g. auth token) is attached to the
    /// `ClientRequest` via `SinchChatSDK.standardRequest(for:token:)`.
    static var standardCallOptions: CallOptions {
        .defaults
    }
}

extension SinchChatSDK {

    /// The standard SDK metadata that should be attached to every RPC
    /// (bundle ID, app version, lang, SDK version, system info). Static
    /// for the lifetime of the process.
    static var standardMetadata: Metadata {
        var metadata = Metadata()
        metadata.addString(Bundle.main.bundleIdentifier ?? "", forKey: "bundleID")
        metadata.addString((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "",
                           forKey: "appVersion")
        metadata.addString(SinchChatSDK.shared.config?.locale.identifier ?? "", forKey: "lang")
        metadata.addString(SinchChatSDK.version, forKey: "sdkVersion")
        metadata.addString(UIDevice.current.systemName, forKey: "system")
        metadata.addString(UIDevice.current.systemVersion, forKey: "systemVersion")
        return metadata
    }

    /// Build a `ClientRequest` populated with the standard SDK metadata
    /// (bundle ID, app version, lang, SDK version, system info) and, when
    /// provided, the given auth token.
    static func standardRequest<Input: Sendable>(for message: Input, token: String? = nil) -> ClientRequest<Input> {
        var metadata = standardMetadata
        if let token {
            metadata.addString(token, forKey: "authorization")
        }
        return ClientRequest(message: message, metadata: metadata)
    }
}

extension AuthDataSource {

    /// Build a `ClientRequest` for the given input, attaching the standard
    /// SDK metadata plus the current access token (if any).
    func signedRequest<Input: Sendable>(_ input: Input) throws -> ClientRequest<Input> {
        let token = try? currentAccessToken()
        return SinchChatSDK.standardRequest(for: input, token: token)
    }
}
