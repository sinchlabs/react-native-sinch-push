#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// SwiftUI wrapper around the SDK inbox view controller.
public struct SinchInboxView: UIViewControllerRepresentable {

    private let uiConfig: SinchSDKConfig.UIConfig?
    private let localizationConfig: SinchSDKConfig.LocalizationConfig?
    private let options: GetChatViewControllerOptions?
    private let onError: ((Error) -> Void)?

    public init(
        uiConfig: SinchSDKConfig.UIConfig? = nil,
        localizationConfig: SinchSDKConfig.LocalizationConfig? = nil,
        options: GetChatViewControllerOptions? = nil,
        onError: ((Error) -> Void)? = nil
    ) {
        self.uiConfig = uiConfig
        self.localizationConfig = localizationConfig
        self.options = options
        self.onError = onError
    }

    public func makeUIViewController(context: Context) -> UINavigationController {
        do {
            let viewController = try SinchChatSDK.shared.chat.inbox.getInboxViewController(
                uiConfig: uiConfig,
                localizationConfig: localizationConfig,
                options: options
            )
            return UINavigationController(rootViewController: viewController)
        } catch {
            onError?(error)
            return UINavigationController(rootViewController: UIViewController())
        }
    }

    public func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

#endif
