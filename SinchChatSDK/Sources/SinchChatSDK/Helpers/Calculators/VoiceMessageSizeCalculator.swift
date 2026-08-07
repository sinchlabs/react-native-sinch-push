import UIKit

final class VoiceMessageSizeCalculator: TextMessageSizeCalculator {
    public var maxWidth = 300.0
    public var voiceViewHeight = 34.0
    
    override func messageContainerMaxWidth(for message: Message) -> CGFloat {
        let maxCalculatedWidth = super.messageContainerMaxWidth(for: message)
         
        return  min(maxCalculatedWidth, maxWidth)
    }
    override func messageLabelSize(for message: Message) -> CGSize {
        let maxWidth = messageContainerMaxWidth(for: message)

        var messageLabelSize: CGSize = .zero
        let attributedText: NSAttributedString

        var text: String = ""
        
        if let layout = layout as? ChatFlowLayout {
            text = layout.messagesCollectionView.localizationConfig.voiceMessageTitle
        }
        
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
                
        messageContainerSize.height = messageLabelSize.height + dateLabelSize.height + dateLabelInsets.top + dateLabelInsets.bottom + voiceViewHeight
        
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
        
        let messageLabelFrame =  CGRect(x:  xCord,
                                        y: 0,
                                        width: messageLabelSize.width,
                                        height: messageLabelSize.height)
        
        let mediaFrame =  CGRect(x:  8,
                                 y: messageLabelFrame.maxY,
                                 width: attributes.messageContainerSize.width - 16,
                                 height: voiceViewHeight)
        
        let dateLabelSize = dateLabelSize(for: message)
        let dateLabelFrame = CGRect(x: attributes.messageContainerSize.width - dateLabelSize.width - dateLabelInsets.right,
                                    y: mediaFrame.maxY + dateLabelInsets.top,
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
