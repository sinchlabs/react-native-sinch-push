import UIKit

class CardMessageSizeCalculator: MessageSizeCalculator {
    
    public var messageLabelInsets = UIEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)
    public var messageLabelFont = UIFont.preferredFont(forTextStyle: .body)
    public var titleLabelInsets = UIEdgeInsets(top: 8, left: 8, bottom: 0, right: 8)
    public var titleLabelFont = UIFont.preferredFont(forTextStyle: .body)
    public var buttonInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    public var maxWidth = 300.0
    public var mediaHeight = 187.0

    override init(layout: ChatFlowLayout? = nil) {
        super.init(layout: layout)
        dateLabelInsets = UIEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        dateLabelTextInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        if let boldDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).withSymbolicTraits(.traitBold) {
            
            titleLabelFont = UIFont(descriptor: boldDescriptor,
                                    size: 0.0)
        }
    }
    
    override func messageContainerMaxWidth(for message: Message) -> CGFloat {
        let calculatedMaxWidth = super.messageContainerMaxWidth(for: message)
        
        return  min(calculatedMaxWidth, maxWidth)
    }
    func titleLabelSize(for message: Message) -> CGSize {
        let maxWidth = messageContainerMaxWidth(for: message)
        
        var titleLabelSize: CGSize = .zero
        let attributedText: NSAttributedString
        var text: String = ""
        
        if let body = message.body as? MessageCard {
            text = body.title
        }
        
        attributedText = NSAttributedString(string: text, attributes: [.font: titleLabelFont])
        titleLabelSize = labelSize(for: attributedText, considering: maxWidth - titleLabelInsets.right - titleLabelInsets.left)
        titleLabelSize.height += (titleLabelInsets.top + titleLabelInsets.bottom)
        titleLabelSize.width += (titleLabelInsets.right + titleLabelInsets.left)
        return titleLabelSize
    }
    func messageLabelSize(for message: Message) -> CGSize {
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
        let titleLabelSize: CGSize = titleLabelSize(for: message)
        
        var numberOfChoices = 0
        if let message = message.body as? MessageCard {
            numberOfChoices = message.choices.count
        }
        
        messageContainerSize.height = mediaHeight + titleLabelSize.height + messageLabelSize.height + buttonInsets.top
        + Double(numberOfChoices) * (buttonHeight + buttonInsets.bottom) +
        dateLabelSize.height + dateLabelInsets.top + dateLabelInsets.bottom
        
        messageContainerSize.width = messageContainerMaxWidth(for: message)
        
        return messageContainerSize
    }
    
    open override func configure(attributes: UICollectionViewLayoutAttributes) {
        super.configure(attributes: attributes)
        guard let attributes = attributes as? ChatFlowLayoutAttributes else { return }
        
        let dataSource = messagesLayout.chatDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        var numberOfChoices = 0
        if let message = message.body as? MessageCard {
            numberOfChoices = message.choices.count
        }
        
        let isFromCurrentSender = dataSource.isFromCurrentSender(message: message)
        let xCordMessage: CGFloat
        let xCordTitle: CGFloat
        
        let messageLabelSize = messageLabelSize(for: message)
        let titleLabelSize: CGSize = titleLabelSize(for: message)
        
        if UIView.userInterfaceLayoutDirection(
            for: messagesLayout.messagesCollectionView.semanticContentAttribute) == .rightToLeft {
            
            xCordMessage =  attributes.messageContainerSize.width - messageLabelSize.width
            xCordTitle =  attributes.messageContainerSize.width - titleLabelSize.width
        } else {
            xCordMessage = isFromCurrentSender ? attributes.messageContainerSize.width - messageLabelSize.width : 0
            xCordTitle =  isFromCurrentSender ? attributes.messageContainerSize.width - titleLabelSize.width : 0
            
        }
        let mediaFrame = CGRect(x:  0,
                                y: 0,
                                width: attributes.messageContainerSize.width,
                                height: mediaHeight)
        let titleLabelFrame =  CGRect(x:  xCordTitle,
                                      y: mediaFrame.maxY,
                                      width: titleLabelSize.width,
                                      height: titleLabelSize.height)
        let messageLabelFrame =  CGRect(x:  xCordMessage,
                                        y: titleLabelFrame.maxY,
                                        width: messageLabelSize.width,
                                        height: messageLabelSize.height)
        
        var buttonsFrame: [CGRect] = []
        
        for counter in 0..<numberOfChoices {
            let buttonFrame = CGRect(x: buttonInsets.left,
                                     y: messageLabelFrame.maxY + buttonInsets.top  + Double(counter) * (buttonHeight + buttonInsets.bottom),
                                     width: attributes.messageContainerSize.width - buttonInsets.left - buttonInsets.right,
                                     height: buttonHeight)
            buttonsFrame.append(buttonFrame)
        }
        
        let dateLabelSize = dateLabelSize(for: message)
        let dateLabelFrame = CGRect(x: attributes.messageContainerSize.width - dateLabelSize.width - dateLabelInsets.right,
                                    y:  attributes.messageContainerSize.height - dateLabelSize.height - dateLabelInsets.bottom,
                                    width: dateLabelSize.width,
                                    height: dateLabelSize.height)
        attributes.mediaFrame = mediaFrame
        attributes.buttonsFrame = buttonsFrame
        attributes.messageLabelTextInsets = messageLabelInsets
        attributes.messageLabelFrame = messageLabelFrame
        attributes.messageLabelFont = messageLabelFont
        attributes.titleLabelTextInsets = titleLabelInsets
        attributes.titleLabelFrame = titleLabelFrame
        attributes.titleLabelFont = titleLabelFont
        attributes.dateLabelInsets = dateLabelInsets
        attributes.dateLabelTextInsets = dateLabelTextInsets
        attributes.dateLabelFont = dateLabelFont
        attributes.dateLabelFrame = dateLabelFrame
        
    }
}
