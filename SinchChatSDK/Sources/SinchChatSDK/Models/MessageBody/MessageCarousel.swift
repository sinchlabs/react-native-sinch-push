import Foundation

struct MessageCarousel: MessageBody, MessageWithChoices {
    
    var cards: [MessageCard]
    var choices: [ChoiceMessageType]
    var sendDate: Int64?
    var isExpanded: Bool = false
    var currentCard = 0

}
