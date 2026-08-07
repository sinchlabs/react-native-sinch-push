import Foundation

public enum EventType: Codable, Sendable {
    
    case joined(Agent)
    case left(Agent)
    case composeStarted
    case composeEnd
    
    case fallbackMessage(payload: String)
    
    case customText(text: String)
    
    var convertToSinchEvent: Sinch_Chat_Sdk_V1alpha2_SendRequest? {
        var request = Sinch_Chat_Sdk_V1alpha2_SendRequest()
        var eventMessage = Sinch_Conversationapi_Type_ContactEvent()
        
        switch self {
        case .composeStarted:
            eventMessage.event = .composingEvent(Sinch_Conversationapi_Type_ComposingEvent())
        
        case .composeEnd:
            
            eventMessage.event = .composingEndEvent(Sinch_Conversationapi_Type_ComposingEndEvent())
        default:
            
            return nil

    }
        request.event = eventMessage
        return request
       
    }
}

public struct MessageEvent: MessageBody {
    
    public var type: EventType
    public var sendDate: Int64?
    public var isExpanded: Bool = false

    public var text: String? {
        let message: String?
        
        switch type {
          
            // TODO : - Add Localization
        case .joined(let agent):
        message  = (agent.type == 1 ? "\(agent.name)" : "Chatbot" )
                    + " joined the conversation"

        case .left(let agent):
            
        message = (agent.type == 1 ? "\(agent.name)" : "Chatbot")
        + " left the conversation"
        case .composeStarted:
            message = ""
        case .composeEnd:
            message = ""
            
        case .fallbackMessage:
            message = ""
            
        case let .customText(text):
            message = text
        }
        return message
    }
}

public struct Agent: Codable, Sendable {
    
    public var name: String
    public var type: Int
    public var pictureUrl: String?
    
}
