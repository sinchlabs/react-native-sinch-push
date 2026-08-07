import Foundation
import UIKit
import GRPCCore
import Swift

public enum MessageError: Error {
    case notSupported
}
public enum MessageStatus: Int, Codable {
    case notSent
    case sending
    case sent
    case delivered
    case seen
    
    func localizedDescription(localizedConfig: SinchSDKConfig.LocalizationConfig) -> String {
        switch self {
        case .notSent:
            return localizedConfig.notSentStatus
        case .sending:
            return localizedConfig.sendingStatus
        case .sent:
            return localizedConfig.sentStatus
        case .delivered:
            return localizedConfig.deliveredStatus
        case .seen:
            return localizedConfig.seenStatus
            
        }
    }
    
    func localizedImage(uiConfig: SinchSDKConfig.UIConfig) -> UIImage? {
        switch self {
        case .notSent:
            return nil
        case .sending:
            return nil
        case .sent:
            return uiConfig.sentStatusImage
        case .delivered:
            return uiConfig.deliveredStatusImage
        case .seen:
            return uiConfig.seenStatusImage
            
        }
    }
}

public struct Message: Encodable, @unchecked Sendable {
    public var entryId : String
    public let owner: Owner
    public var body: MessageBody
    public var status: MessageStatus
    
    enum CodingKeys: String, CodingKey {
        case entryId
        case owner
        case body
        case status
    }
    
    public func encode(to encoder: Encoder) throws {
        var cod = encoder.container(keyedBy: CodingKeys.self)
        try cod.encode(owner, forKey: .owner)
        
        if let textMessage = body as? MessageText {
            try cod.encode(textMessage, forKey: .body)
        } else if let messageImage = body as? MessageMedia {
            try cod.encode(messageImage, forKey: .body)
        } else if let messageEvent = body as? MessageEvent {
            try cod.encode(messageEvent, forKey: .body)
        }
    }
    
    public init(entryId: String, owner: Owner, body: MessageBody, status: MessageStatus = .sent) {
        self.entryId = entryId
        self.owner = owner
        self.body = body
        self.status = status
    }

    /// Returns a copy of this message with the given body. Used by the
    /// migrated streaming/subscription code paths.
    public func with(body newBody: MessageBody) -> Message {
        Message(entryId: entryId, owner: owner, body: newBody, status: status)
    }

    func isFromCurrentUser() -> Bool {
        switch owner {
            
        case .outgoing:
            return true
        case .incoming(_):
            return false
        case .system:
            return false
        }
    }
}

extension Message: Decodable {
    public init(from decoder: Swift.Decoder) throws {
        let dec = try decoder.container(keyedBy: CodingKeys.self)
        owner = try dec.decode(Owner.self, forKey: .owner)
        entryId = try dec.decode(String.self, forKey: .entryId)
        status = try dec.decode(MessageStatus.self, forKey: .status)
        if case .system = owner {
            if let messageEvent = try? dec.decode(MessageEvent.self, forKey: .body) {
                body = messageEvent
            } else {
                throw MessageError.notSupported
            }
        } else {
            if let textMessage = try? dec.decode(MessageText.self, forKey: .body) {
                body = textMessage
            } else if let messageImage = try? dec.decode(MessageMedia.self, forKey: .body) {
                body = messageImage
            } else {
                throw MessageError.notSupported
            }
        }
    }
}
extension Message {
    var convertToSinchMessage: Sinch_Chat_Sdk_V1alpha2_SendRequest? {
        var request = Sinch_Chat_Sdk_V1alpha2_SendRequest()
        var contactMessage = Sinch_Conversationapi_Type_ContactMessage()
        
        switch body {
        case let text as MessageText:
            var messageText = Sinch_Conversationapi_Type_TextMessage()
            messageText.text = text.text
            contactMessage.message = .textMessage(messageText)
            
        default:
            return nil
        }
        request.message = contactMessage
        return request
    }
    var convertToText: String? {
        
        var text: String?
        
        switch body {
            
        case let message as MessageText:
            
            text = message.text
            
        case _ as MessageMedia:
            text = "You've got a media message"
            
        case _ as MessageLocation:
            
            text = "You've got a location message"
            
        case _ as MessageChoices:
            
            text = "You've got a choice message"
        
        case _ as MessageCard:
            
            text = "You've got a card message"
            
        case _ as MessageCarousel:
            
            text = "You've got a carousel message"

        case _ as MessageVoice:
            text = "You've got a voice message"

        default:
        
            break
        }
        
        return text
    }
}
