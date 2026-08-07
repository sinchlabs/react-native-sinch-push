import Foundation

protocol MessageWithChoices {
    var choices: [ChoiceMessageType] { get }

}

struct MessageChoices: MessageBody, MessageWithChoices, MessageWithText {
    
    var text: String
    var choices: [ChoiceMessageType]
    var sendDate: Int64?
    var isExpanded: Bool = false

    func getText() -> String {
        return text
    }
    
    func getReadMore(maxCount: Int, textToAdd: String ) -> String {
        
        if text.count > maxCount && !isExpanded {
           
            return text.prefix(maxCount) + "... " + "\(textToAdd)"
            
        }
        
        return text
      
    }
}

enum ChoiceMessageType: Codable {
    
    case textMessage(ChoiceText)
    case urlMessage(ChoiceUrl)
    case callMessage(ChoiceCall)
    case locationMessage(ChoiceLocation)

}

struct ChoiceText: Codable {
    var text: String
    let postback: String
    let entryID: String
}

struct ChoiceUrl: Codable {
    var url: String
    var text: String
}

struct ChoiceLocation: Codable {
    var text: String
    var label: String
    var latitude: Double
    var longitude: Double

}

struct ChoiceCall: Codable {
    var text: String
    var phoneNumber: String

}
