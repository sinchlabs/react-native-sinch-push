import UIKit

final class MediaTextMessageSizeCalculator: TextMessageSizeCalculator {
    public var maxWidth = 300.0
    public var mediaHeight = 187.0
    
    override func messageContainerMaxWidth(for message: Message) -> CGFloat {
        let maxCalculatedWidth = super.messageContainerMaxWidth(for: message)
         
        return  min(maxCalculatedWidth, maxWidth)
    }
    override func messageLabelSize(for message: Message) -> CGSize {
        let maxWidth = messageContainerMaxWidth(for: message)

        var messageLabelSize: CGSize = .zero
        let attributedText: NSAttributedString
        let text: String = message.body.getReadMore(maxCount: messagesLayout.messagesCollectionView.uiConfig.numberOfCharactersBeforeCollapseTextMessage,
                                                    textToAdd: messagesLayout.messagesCollectionView.localizationConfig.collapsedTextMessageButtonTitle)
        
        attributedText = NSAttributedString(string: text, attributes: [.font: messageLabelFont])
        messageLabelSize = labelSize(for: attributedText, considering: maxWidth - messageLabelInsets.right - messageLabelInsets.left)
        messageLabelSize.height += (messageLabelInsets.top + messageLabelInsets.bottom)
        messageLabelSize.width += (messageLabelInsets.right + messageLabelInsets.left)
        return messageLabelSize
    }
    
    override func messageContainerSize(for message: Message) -> CGSize {
        
        var messageContainerSize: CGSize = .zero
        let dateLabelSize = dateLabelSize(for: message)
        let messageLabelSize: CGSize = messageLabelSize(for: message)
                
        messageContainerSize.height = messageLabelSize.height + dateLabelSize.height + dateLabelInsets.top + dateLabelInsets.bottom + mediaHeight
        
        messageContainerSize.width = messageContainerMaxWidth(for: message)
        
        return messageContainerSize
    }
    
    public override func configure(attributes: UICollectionViewLayoutAttributes) {
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
        let mediaFrame =  CGRect(x:  0,
                                 y: 0,
                                 width: attributes.messageContainerSize.width,
                                 height: mediaHeight)
        
        let messageLabelFrame =  CGRect(x:  xCord,
                                        y: mediaFrame.maxY,
                                        width: messageLabelSize.width,
                                        height: messageLabelSize.height)
        
        let dateLabelSize = dateLabelSize(for: message)
        let dateLabelFrame = CGRect(x: attributes.messageContainerSize.width - dateLabelSize.width - dateLabelInsets.right,
                                    y: messageLabelFrame.origin.y + messageLabelFrame.height + dateLabelInsets.top,
                                    width: dateLabelSize.width,
                                    height: dateLabelSize.height)
        
        attributes.mediaFrame = mediaFrame
        attributes.messageLabelTextInsets = messageLabelInsets
        attributes.messageLabelFrame = messageLabelFrame
        attributes.messageLabelFont = messageLabelFont
        attributes.dateLabelInsets = dateLabelInsets
        attributes.dateLabelTextInsets = dateLabelTextInsets
        attributes.dateLabelFont = dateLabelFont
        attributes.dateLabelFrame = dateLabelFrame
    }
}
