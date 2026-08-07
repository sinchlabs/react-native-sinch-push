import UIKit
final class DateMessageSizeCalculator: EventMessageSizeCalculator {
    
    override init(layout: ChatFlowLayout? = nil) {
        super.init()
        
        self.layout = layout
        eventMessagePadding = UIEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)

    }
}
