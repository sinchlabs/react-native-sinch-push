import Foundation

public struct MessageText: MessageBody, MessageWithText {
    public var text: String
    public var sendDate: Int64?
    public var isExpanded: Bool = false

    public func getText() -> String {
        return text
    }
    
    public func getReadMore(maxCount: Int, textToAdd: String ) -> String {
        
        if text.count > maxCount && !isExpanded {
           
            return text.prefix(maxCount) + "... " + "\(textToAdd)"
            
        }
        
        return text
      
    }
}
