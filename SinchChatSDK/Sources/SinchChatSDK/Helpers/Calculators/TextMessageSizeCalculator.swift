import UIKit

class TextMessageSizeCalculator: MessageSizeCalculator {
    
    public var messageLabelInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    public var messageLabelFont = UIFont.preferredFont(forTextStyle: .body)
   
    override init(layout: ChatFlowLayout? = nil) {
        super.init(layout: layout)
        dateLabelInsets = UIEdgeInsets(top: 5, left: 8, bottom: 8, right: 8)
        dateLabelTextInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
    override func messageContainerMaxWidth(for message: Message) -> CGFloat {
        let maxWidth = super.messageContainerMaxWidth(for: message)
        let textInsets = messageLabelInsets
        return maxWidth - textInsets.left - textInsets.right
    }
    
    func messageLabelSize(for message: Message) -> CGSize {
        let maxWidth = messageContainerMaxWidth(for: message)
        
        var messageLabelSize: CGSize = .zero

        let attributedText: NSAttributedString
        let text: String = message.body.getReadMore(maxCount: messagesLayout.messagesCollectionView.uiConfig.numberOfCharactersBeforeCollapseTextMessage,
                                                    textToAdd: messagesLayout.messagesCollectionView.localizationConfig.collapsedTextMessageButtonTitle)

        attributedText = NSAttributedString(string: text, attributes: [.font: messageLabelFont])
        messageLabelSize = labelSize(for: attributedText, considering: maxWidth)

        if message.body.sendDate != nil {
            messageLabelSize.height += messageLabelInsets.top
            messageLabelInsets.bottom = 0
        } else {
            messageLabelInsets.bottom = 8
            
            messageLabelSize.height += (messageLabelInsets.top + messageLabelInsets.bottom)
        }
        
        messageLabelSize.width += (messageLabelInsets.right + messageLabelInsets.left)
        return messageLabelSize
    }
        
    override func messageContainerSize(for message: Message) -> CGSize {
        
        var messageContainerSize: CGSize = .zero
        let dateLabelSize = dateLabelSize(for: message)
        let messageLabelSize: CGSize = messageLabelSize(for: message)
        
        messageContainerSize.height = messageLabelSize.height + dateLabelSize.height + dateLabelInsets.top + dateLabelInsets.bottom
        
        messageContainerSize.width = max(messageLabelSize.width, dateLabelSize.width + dateLabelInsets.left + dateLabelInsets.right)
        
        return messageContainerSize
    }
    
    open override func configure(attributes: UICollectionViewLayoutAttributes) {
        super.configure(attributes: attributes)
        guard let attributes = attributes as? ChatFlowLayoutAttributes else { return }
        
        let dataSource = messagesLayout.chatDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        
        let messageLabelSize = messageLabelSize(for: message)
        let messageLabelFrame = CGRect(x: attributes.messageContainerSize.width - messageLabelSize.width,
                                       y: 0.0,
                                       width: messageLabelSize.width,
                                       height: messageLabelSize.height)
        
        let dateLabelSize = dateLabelSize(for: message)
        let dateLabelFrame = CGRect(x: attributes.messageContainerSize.width - dateLabelSize.width - dateLabelInsets.right,
                                    y: messageLabelFrame.height + dateLabelInsets.top,
                                    width: dateLabelSize.width,
                                    height: dateLabelSize.height)
        
        attributes.messageLabelTextInsets = messageLabelInsets
        attributes.messageLabelFrame = messageLabelFrame
        attributes.messageLabelFont = messageLabelFont
        attributes.dateLabelInsets = dateLabelInsets
        attributes.dateLabelTextInsets = dateLabelTextInsets
        attributes.dateLabelFont = dateLabelFont
        attributes.dateLabelFrame = dateLabelFrame
        
    }
}
