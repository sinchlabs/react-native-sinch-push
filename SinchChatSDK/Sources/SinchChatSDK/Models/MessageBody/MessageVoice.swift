import UIKit

public struct MessageVoice: MessageBody, MessageWithURL {
    public var url: String
    public var sendDate: Int64?
    public var isExpanded: Bool = false

    public  init(url: String, sendDate: Int64?, placeholderImage: UIImage?) {
        self.url = url
        self.sendDate = sendDate
    }
}
