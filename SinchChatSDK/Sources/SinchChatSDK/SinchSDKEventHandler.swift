import UIKit

extension SinchChatSDK: SinchPluginAvailablePluginMethods {
    
    public func getAuthorizationToken() -> AuthModel? {
        _chat.authDataSource?.currentAuthorization
    }
    
    // If AuthModel is nil then we will use current AuthModel.
    public func sendMessage(_ message: MessageType, authModel: AuthModel?, chatOptions: SinchChatOptions?, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
                
        guard let client = apiClient ?? Default2APIClient(region: config?.region ?? .EU1),
              let authDataSource = authDataSource else {
            completion(.failure(SinchChatSDKError.unavailable))
            return
        }
        
        var topicModel: TopicModel?
        if let topicID = chatOptions?.topicID {
            topicModel = TopicModel(topicID: topicID)
        }
        
        let messageDataSource = DefaultMessageDataSource(
            apiClient: client,
            authDataSource: authDataSource,
            topicModel: topicModel,
            metadata: chatOptions?.metadata ?? [],
            shouldInitializeConversation: chatOptions?.shouldInitializeConversation ?? false,
            sendDocumentAsText: chatOptions?.sendDocumentAsText ?? false
        )
        
        messageDataSource.sendMessage(message) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let payload):
                completion(.success(payload))
            }
        }
    }
    
    public func presentViewController(_ viewController: UIViewController, _ animated: Bool, completion: (@Sendable () -> Void)?) {
        getTopViewController()?.present(viewController, animated: true, completion: {
            completion?()
        })
    }
    
    public func startChatWithCurrentConfig() {
        guard config != nil,
              let chatVC = try? _chat.getChatViewController() else {
            return
        }
        
        let navigationController = UINavigationController(rootViewController: chatVC)
        
        getTopViewController()?.present(navigationController, animated: true)
    }
    
    private func getTopViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.windows.filter {$0.isKeyWindow}.first

        if var topController = keyWindow?.rootViewController {
            while let presentedViewController = topController.presentedViewController {
                topController = presentedViewController
            }

            return topController
        }
        return nil
    }
}
