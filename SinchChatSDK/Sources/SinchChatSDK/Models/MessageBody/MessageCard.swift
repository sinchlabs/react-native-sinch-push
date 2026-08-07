import Foundation

struct MessageCard: MessageBody, MessageWithURL, MessageWithChoices, MessageWithText {
    
    var title: String
    var description: String
    var choices: [ChoiceMessageType]
    var url: String
    var sendDate: Int64?
    var isExpanded: Bool = false

    func getText() -> String {
        return description
    }
    func getReadMore(maxCount: Int, textToAdd: String ) -> String {
        
        if description.count > maxCount && !isExpanded {
           
            return description.prefix(maxCount) + "... " + "\(textToAdd)"
            
        }
        return description
    }
}
