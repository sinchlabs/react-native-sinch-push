import UIKit

final class ImageMessageSizeCalculator: MessageSizeCalculator {
    public var mediaHeight = 187.0
    public var maxWidth = 300.0

    override init(layout: ChatFlowLayout? = nil) {
        super.init(layout: layout)
        dateLabelInsets = UIEdgeInsets(top: 0, left: 0, bottom: 8, right: 8)
        dateLabelTextInsets = UIEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)
    }
    
    override func messageContainerSize(for message: Message) -> CGSize {
        let maxWidth = min(messageContainerMaxWidth(for: message), maxWidth)
       
        return CGSize(width: maxWidth, height:
                        mediaHeight)
    
    }
    
    override func configure(attributes: UICollectionViewLayoutAttributes) {
        super.configure(attributes: attributes)
        guard let attributes = attributes as? ChatFlowLayoutAttributes else { return }
        
        let dataSource = messagesLayout.chatDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        
        let mediaFrame =  CGRect(x: 0,
                                 y: 0,
                                 width: attributes.messageContainerSize.width,
                                 height: mediaHeight)
        
        let dateLabelSize = dateLabelSize(for: message)
        let dateLabelFrame = CGRect(x: attributes.messageContainerSize.width - dateLabelSize.width - dateLabelInsets.right,
                                    y: attributes.messageContainerSize.height - dateLabelSize.height - dateLabelInsets.bottom,
                                    width: dateLabelSize.width,
                                    height: dateLabelSize.height)
        attributes.mediaFrame = mediaFrame
        attributes.dateLabelInsets = dateLabelInsets
        attributes.dateLabelTextInsets = dateLabelTextInsets
        attributes.dateLabelFont = dateLabelFont
        attributes.dateLabelFrame = dateLabelFrame
        
    }
}
