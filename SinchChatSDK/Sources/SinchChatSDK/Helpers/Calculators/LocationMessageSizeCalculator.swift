import UIKit

class LocationMessageSizeCalculator: MessageSizeCalculator {
    
    public var messageLabelInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    public var messageLabelFont = UIFont.preferredFont(forTextStyle: .body)
    public var buttonInsets = UIEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
    public var mapHeight = 187.0
    public var maxWidth = 300.0
    
    override init(layout: ChatFlowLayout? = nil) {
        super.init(layout: layout)
        dateLabelInsets = UIEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        dateLabelTextInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
    override func messageContainerMaxWidth(for message: Message) -> CGFloat {
        let maxCalculatedWidth = super.messageContainerMaxWidth(for: message)
         
        return  min(maxCalculatedWidth, maxWidth)
    }
    
    func messageLabelSize(for message: Message) -> CGSize {
        let maxWidth = messageContainerMaxWidth(for: message)

        var messageLabelSize: CGSize = .zero
        let attributedText: NSAttributedString
        let text: String = message.body.getReadMore(maxCount: messagesLayout.messagesCollectionView.uiConfig.numberOfCharactersBeforeCollapseTextMessage,
                                          textToAdd: messagesLayout.messagesCollectionView.localizationConfig.collapsedTextMessageButtonTitle)
        
        if text.isEmpty {
            messageLabelSize = .zero
        } else {
            attributedText = NSAttributedString(string: text, attributes: [.font: messageLabelFont])
        messageLabelSize = labelSize(for: attributedText, considering: maxWidth - messageLabelInsets.right - messageLabelInsets.left)
        }
        
        messageLabelSize.height += (messageLabelInsets.top + messageLabelInsets.bottom)
        messageLabelSize.width += (messageLabelInsets.right + messageLabelInsets.left)
        return messageLabelSize
    }
        
    override func messageContainerSize(for message: Message) -> CGSize {
        
        var messageContainerSize: CGSize = .zero
        let dateLabelSize = dateLabelSize(for: message)
        let messageLabelSize: CGSize = messageLabelSize(for: message)
                
        messageContainerSize.height = mapHeight + messageLabelSize.height + buttonHeight + buttonInsets.bottom + dateLabelSize.height + dateLabelInsets.top + dateLabelInsets.bottom
        
        messageContainerSize.width = messageContainerMaxWidth(for: message)

        return messageContainerSize
    }
    
    open override func configure(attributes: UICollectionViewLayoutAttributes) {
        super.configure(attributes: attributes)
        guard let attributes = attributes as? ChatFlowLayoutAttributes else { return }
        
        let dataSource = messagesLayout.chatDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        
        let isFromCurrentSender = dataSource.isFromCurrentSender(message: message)
        let xCord: CGFloat
        let messageLabelSize = messageLabelSize(for: message)
        if UIView.userInterfaceLayoutDirection(
          for: messagesLayout.messagesCollectionView.semanticContentAttribute) == .rightToLeft {

            xCord =  attributes.messageContainerSize.width - messageLabelSize.width
        } else {
            xCord = isFromCurrentSender ? attributes.messageContainerSize.width - messageLabelSize.width : 0
        }
        
        let mapFrame = CGRect(x: 0,
                              y: 0,
                              width: attributes.messageContainerSize.width,
                              height: mapHeight)
        
        let messageLabelFrame =  CGRect(x:  xCord,
                                        y: mapFrame.maxY,
                                        width: messageLabelSize.width,
                                        height: messageLabelSize.height)
        let buttonFrame = CGRect(x: buttonInsets.left,
                                 y: messageLabelFrame.maxY,
                                 width: attributes.messageContainerSize.width - buttonInsets.left - buttonInsets.right,
                                 height: buttonHeight)
        
        let dateLabelSize = dateLabelSize(for: message)
        let dateLabelFrame = CGRect(x: attributes.messageContainerSize.width - dateLabelSize.width - dateLabelInsets.right,
                                    y:  attributes.messageContainerSize.height - dateLabelSize.height - dateLabelInsets.bottom,
                                    width: dateLabelSize.width,
                                    height: dateLabelSize.height)
                
        attributes.mapFrame = mapFrame
        attributes.buttonsFrame = [buttonFrame]
        attributes.messageLabelTextInsets = messageLabelInsets
        attributes.messageLabelFrame = messageLabelFrame
        attributes.messageLabelFont = messageLabelFont
        attributes.dateLabelInsets = dateLabelInsets
        attributes.dateLabelTextInsets = dateLabelTextInsets
        attributes.dateLabelFont = dateLabelFont
        attributes.dateLabelFrame = dateLabelFrame
        
    }
}
