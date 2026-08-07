import Foundation

public enum MessageType: @unchecked Sendable {
    case text(String)
    case choiceResponseMessage(postbackData: String, entryID: String)
    case media(message: Message)
    case location(latitude: Float, longitude: Float, localizationConfig: SinchSDKConfig.LocalizationConfig)
    
    // Custom message type, usually sent on conversation started.
    case fallbackMessage(String)
    
    // Generic event message type.
    case genericEvent(payload: String)
    
    internal var convertToSinchMessage: Sinch_Chat_Sdk_V1alpha2_SendRequest? {
        var request = Sinch_Chat_Sdk_V1alpha2_SendRequest()
        var contactMessage = Sinch_Conversationapi_Type_ContactMessage()
        
        switch self {
        case .text(let text):
            
            var messageText = Sinch_Conversationapi_Type_TextMessage()
            messageText.text = text
            contactMessage.message = .textMessage(messageText)
        case let .choiceResponseMessage(postbackData, entryID):
            
            var messageChoice = Sinch_Conversationapi_Type_ChoiceResponseMessage()
            messageChoice.postbackData = postbackData
            messageChoice.messageID = entryID
            contactMessage.choiceResponseMessage = messageChoice
        case .media(let message):
            
            var messageMedia = Sinch_Conversationapi_Type_MediaMessage()
            if let media = message.body as? MessageMedia {
                messageMedia.url = media.url
            }
            contactMessage.message = .mediaMessage(messageMedia)
            
        case let .location(latitude, longitude, localizationConfig):
            
            var locationMessage = Sinch_Conversationapi_Type_LocationMessage()
            locationMessage.title = localizationConfig.outgoingLocationMessageTitle
            locationMessage.label = localizationConfig.outgoingLocationMessageButtonTitle
            
            var coordinates = Sinch_Conversationapi_Type_Coordinates()
            coordinates.latitude = latitude
            coordinates.longitude = longitude
            locationMessage.coordinates = coordinates
            contactMessage.message = .locationMessage(locationMessage)
            
        case .fallbackMessage(let message):
            
            var fallbackMessage = Sinch_Conversationapi_Type_FallbackMessage()
            fallbackMessage.rawMessage = message
            
            contactMessage.fallbackMessage = fallbackMessage
            
        case .genericEvent(let payload):            
            var event = Sinch_Conversationapi_Type_FallbackMessage()
            event.rawMessage = payload
            
            contactMessage.fallbackMessage = event
        }
        
        request.message = contactMessage
        return request
       
    }
}
