import Foundation

public struct MessageMediaText: MessageBody, MessageWithURL, MessageWithText {
    public var text: String
    public var url: String
    public var sendDate: Int64?
    public  var isExpanded: Bool = false

    public func getText() -> String {
        return text
    }
    
    public func getReadMore(maxCount: Int, textToAdd: String ) -> String {
        return text.prefix(maxCount) + "... " + "\(textToAdd)"
    }
}
