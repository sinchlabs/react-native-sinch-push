import UIKit

class EventMessageSizeCalculator: MessageSizeCalculator {
    
    public var messageLabelInsets = UIEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
    public var messageLabelFont = UIFont.preferredFont(forTextStyle: .caption2)
    public var eventMessagePadding = UIEdgeInsets(top: 15, left: 24, bottom: 20, right: 24)
    
    override func messageContainerPadding(for message: Message) -> UIEdgeInsets {
        eventMessagePadding
    }
    
    override func messageContainerSize(for message: Message) -> CGSize {
        
        messageLabelSize(for: message)
    }
    
    override func messageContainerMaxWidth(for message: Message) -> CGFloat {
        
        messagesLayout.itemWidth - eventMessagePadding.left - eventMessagePadding.right
    }
    
    func messageLabelSize(for message: Message) -> CGSize {
        let maxWidth = messageContainerMaxWidth(for: message)
        
        var messageLabelSize: CGSize = .zero
        let attributedText: NSAttributedString
        
        if let body = message.body as? MessageEvent {
          
            attributedText = NSAttributedString(string: body.text ?? "", attributes: [.font: messageLabelFont])
            messageLabelSize = labelSize(for: attributedText, considering: maxWidth)
            
        } else if let body = message.body as? MessageDate, let dateInSeconds = body.sendDate {
                                          
            attributedText = NSAttributedString(string: Date(timeIntervalSince1970:
                                                            TimeInterval(dateInSeconds)).getFormattedDate(localizationConfiguration:
                                                                                                            messagesLayout.messagesCollectionView.localizationConfig),
                                                attributes: [.font: messageLabelFont])
            messageLabelSize = labelSize(for: attributedText, considering: maxWidth)
            
        } else {
            fatalError("messageContainerSize received unhandled MessageDataType: \(message.body)")
        }
        messageLabelSize.height += (messageLabelInsets.top + messageLabelInsets.bottom)
        messageLabelSize.width += (messageLabelInsets.right + messageLabelInsets.left)
        
        return messageLabelSize
    }
    
    override func avatarPosition(for message: Message) -> AvatarPosition {
        
        AvatarPosition(horizontal: .noAvatar)
    }
    
    override func avatarSize(for message: Message) -> CGSize {
        .zero
    }
    
    override func configure(attributes: UICollectionViewLayoutAttributes) {
        super.configure(attributes: attributes)
        guard let attributes = attributes as? ChatFlowLayoutAttributes else { return }
        
        let dataSource = messagesLayout.chatDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        
        let messageLabelSize = messageLabelSize(for: message)
        let messageLabelFrame = CGRect(x: 0.0,
                                       y: 0.0,
                                       width: messageLabelSize.width,
                                       height: messageLabelSize.height)
        
        attributes.messageLabelTextInsets = messageLabelInsets
        attributes.messageContainerPadding = eventMessagePadding
        attributes.messageLabelFrame = messageLabelFrame
        attributes.messageLabelFont = messageLabelFont
        
    }
}
