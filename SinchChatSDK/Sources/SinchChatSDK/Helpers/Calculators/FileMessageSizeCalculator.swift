import UIKit

class FileMessageSizeCalculator: MessageSizeCalculator {
    
    public var messageLabelInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    public var backgroundViewInsets = UIEdgeInsets(top: 8, left: 8, bottom: 5, right: 8)
    public var mediaViewInsets = UIEdgeInsets(top: 8, left: 8, bottom: 0, right: 18)
    public var titleLabelInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    public var messageLabelFont = UIFont.preferredFont(forTextStyle: .body)
    public var titleLabelFont = UIFont.preferredFont(forTextStyle: .body)

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
    override func messageContainerSize(for message: Message) -> CGSize {
        
        var messageContainerSize: CGSize = .zero
        let dateLabelSize = dateLabelSize(for: message)
    
        messageContainerSize.height = messageLabelInsets.top + messageLabelInsets.top +
                                      titleLabelFont.lineHeight + messageLabelFont.lineHeight + messageLabelInsets.bottom +
                                      dateLabelInsets.top + dateLabelSize.height +  dateLabelInsets.bottom
        let width = messageContainerMaxWidth(for: message) > 280.0 ? CGFloat(280.0) : messageContainerMaxWidth(for: message)
        
        messageContainerSize.width = max(width, (dateLabelSize.width + dateLabelInsets.left + dateLabelInsets.right))
        
        return messageContainerSize
    }
    
    open override func configure(attributes: UICollectionViewLayoutAttributes) {
        super.configure(attributes: attributes)
        guard let attributes = attributes as? ChatFlowLayoutAttributes else { return }
        
        let dataSource = messagesLayout.chatDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        let titleHeight = titleLabelFont.lineHeight
        let messageHeight = messageLabelFont.lineHeight

        let backgroundFrame = CGRect(x: backgroundViewInsets.left,
                                     y: backgroundViewInsets.top,
                                     width:  attributes.messageContainerSize.width - backgroundViewInsets.left - backgroundViewInsets.right,
                                     height: messageLabelInsets.top + titleHeight + messageHeight + messageLabelInsets.bottom )
        
        let mediaLabelFrame = CGRect(x: mediaViewInsets.left, y: mediaViewInsets.top, width: 40, height: 40)
        
        let titleLabelFrame = CGRect(x: mediaLabelFrame.maxX + mediaViewInsets.right,
                                     y: messageLabelInsets.top,
                                     width: backgroundFrame.width - mediaLabelFrame.maxX -  mediaViewInsets.right - messageLabelInsets.right ,
                                     height: titleHeight)

        let messageLabelFrame = CGRect(x: mediaLabelFrame.maxX + mediaViewInsets.right,
                                       y: titleLabelFrame.maxY,
                                       width: backgroundFrame.width - mediaLabelFrame.maxX -  mediaViewInsets.right - messageLabelInsets.right ,
                                       height: messageHeight)
        
        let dateLabelSize = dateLabelSize(for: message)
        let dateLabelFrame = CGRect(x: attributes.messageContainerSize.width - dateLabelSize.width - dateLabelInsets.right,
                                    y: backgroundFrame.maxY + 5,
                                    width: dateLabelSize.width,
                                    height: dateLabelSize.height)
      
        attributes.mediaFrame = mediaLabelFrame
        attributes.titleLabelTextInsets = titleLabelInsets
        attributes.titleLabelFrame = titleLabelFrame
        attributes.titleLabelFont = titleLabelFont

        attributes.messageLabelTextInsets = titleLabelInsets
        attributes.messageLabelFrame = messageLabelFrame
        attributes.messageLabelFont = messageLabelFont
        attributes.dateLabelInsets = dateLabelInsets
        attributes.dateLabelTextInsets = dateLabelTextInsets
        attributes.dateLabelFont = dateLabelFont
        attributes.dateLabelFrame = dateLabelFrame
        attributes.backgroundFrame = backgroundFrame

    }
}
