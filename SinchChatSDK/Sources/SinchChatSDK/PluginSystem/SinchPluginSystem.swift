import UIKit
import Combine

public protocol SinchPlugin: Sendable {
    func initialize(methods: SinchPluginAvailablePluginMethods)
}

public protocol SinchPluginAvailablePluginMethods: AnyObject, Sendable {
    var eventListenerSubject: PassthroughSubject<SinchPluginEvent, Never> { get }
    
    var customMessageTypeHandlers: [(_ model: Message) -> Message?] { get set }
    var customMessageTypeHandlersAsync: [(_ model: Message, _ callback: @escaping (Message?) -> Void) -> Void] { get set }
    
    var additionalMetadata: SinchMetadataArray { get set }
    
    func getAuthorizationToken() -> AuthModel?
    
    func sendMessage(_ message: MessageType, authModel: AuthModel?, chatOptions: SinchChatOptions?, completion: @escaping @Sendable (Result<String, Error>) -> Void)
    
    func presentViewController(_ viewController: UIViewController, _ animated: Bool, completion: (@Sendable () -> Void)?)
    
    func startChatWithCurrentConfig()
}

public protocol SinchPluginListener {
    func cancel()
}
public protocol ChatViewProtocol: UIViewController {
    func didChangeErrorState(_ state: ChatErrorState)
}
public enum SinchPluginEvent {
    case didSetIdentity(AuthModel)
    case didStartChat(chatViewController: ChatViewProtocol, chatOptions: SinchChatOptions)
    case didCloseChat
    case didRemoveIdentity
    case didChangeInternetState(isOn: Bool)

}
public enum ChatErrorState {

    case none
    case isInternetOff
    case isInternetOn
    case agentNotInChat
    case agentInChat

}

public struct SinchChatOptions: Codable, Equatable {
    public var topicID: String?
    public var metadata: SinchMetadataArray?
    public var shouldInitializeConversation: Bool?
    public var sendDocumentAsText: Bool?
    
    public static func == (lhs: SinchChatOptions, rhs: SinchChatOptions) -> Bool {
        lhs.topicID == rhs.topicID &&
        lhs.metadata == rhs.metadata &&
        lhs.shouldInitializeConversation == rhs.shouldInitializeConversation &&
        lhs.sendDocumentAsText == rhs.sendDocumentAsText
    }
}
