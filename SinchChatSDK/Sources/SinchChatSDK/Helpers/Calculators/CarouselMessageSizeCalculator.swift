import UIKit

final class CarouselMessageSizeCalculator: CardMessageSizeCalculator {
    
    public var carouselButtonInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    public var carouselChoiceButtonInsets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

    public var pageControlHeight = 8.0
    public var pageControlInsets = 8.0
    public var spacing = 10.0
    public var backgroundViewSpacing = 8.0

    override init(layout: ChatFlowLayout? = nil) {
        super.init(layout: layout)
        mediaHeight = 230.0
    }
    func titleLabelSize(for message: Message, cardMessage: MessageCard) -> CGSize {
        let maxWidth = carouselBackgroundMaxWidth(for: message)
        
        var titleLabelSize: CGSize = .zero
        let attributedText: NSAttributedString
        let text = cardMessage.title
        
        attributedText = NSAttributedString(string: text, attributes: [.font: titleLabelFont])
        titleLabelSize = labelSize(for: attributedText, considering: maxWidth - titleLabelInsets.right - titleLabelInsets.left)
        titleLabelSize.height += (titleLabelInsets.top + titleLabelInsets.bottom)
        titleLabelSize.width += (titleLabelInsets.right + titleLabelInsets.left)
        return titleLabelSize
    }
    func messageLabelSize(for message: Message, cardMessage: MessageCard) -> CGSize {
        let maxWidth = carouselBackgroundMaxWidth(for: message)
        
        var messageLabelSize: CGSize = .zero
        let attributedText: NSAttributedString
        let text: String = cardMessage.getReadMore(maxCount: messagesLayout.messagesCollectionView.uiConfig.numberOfCharactersBeforeCollapseTextMessage,
                                                   textToAdd: messagesLayout.messagesCollectionView.localizationConfig.collapsedTextMessageButtonTitle)

        attributedText = NSAttributedString(string: text, attributes: [.font: messageLabelFont])
        messageLabelSize = labelSize(for: attributedText, considering: maxWidth - messageLabelInsets.right - messageLabelInsets.left)
        messageLabelSize.height += (messageLabelInsets.top + messageLabelInsets.bottom)
        messageLabelSize.width += (messageLabelInsets.right + messageLabelInsets.left)
        return messageLabelSize
    }
    
    override func messageContainerSize(for message: Message) -> CGSize {
        return carouselBackgroundViewSize(for: message)
    }

    func carouselBackgroundMaxWidth(for message: Message) -> CGFloat {
            
            return  messageContainerMaxWidth(for: message) - 2 * backgroundViewSpacing
    }
    func carouselBackgroundViewSize(for message: Message) -> CGSize {
        
        var carouselBackgroundViewSize: CGSize = .zero
        let cardMessageContainerSize = cardMessageContainerSize(for: message)
        var numberOfCarouselChoices = 0
     
        if let carouselMessage = message.body as? MessageCarousel {
            numberOfCarouselChoices = carouselMessage.choices.count
        }
        let dateLabelSize = dateLabelSize(for: message)

        carouselBackgroundViewSize.height = backgroundViewSpacing + cardMessageContainerSize.height +
       ( numberOfCarouselChoices == 0 ? 0 : 1)  +
        carouselChoiceMessageContainerSize(for: message).height +
        backgroundViewSpacing + dateLabelSize.height + backgroundViewSpacing
        
        carouselBackgroundViewSize.width = messageContainerMaxWidth(for: message)
        
        return carouselBackgroundViewSize
    }
    
    func cardMessageContainerSize(for message: Message) -> CGSize {
        
        var cardMessageContainerSize: CGSize = .zero
       
        var maxTextHeight = 0.0
        var maxNumberOfChoices = 0
        var numberOfCards = 0
        if let carouselMessage = message.body as? MessageCarousel {
            numberOfCards = carouselMessage.cards.count
            
            for card in carouselMessage.cards {
                let messageLabelSize: CGSize = messageLabelSize(for: message, cardMessage: card)
                let titleLabelSize: CGSize = titleLabelSize(for: message, cardMessage: card)
                let textSize = titleLabelSize.height + messageLabelSize.height
                if maxTextHeight < textSize {
                    maxTextHeight = textSize
                }
                
                if maxNumberOfChoices < card.choices.count {
                    maxNumberOfChoices = card.choices.count
                }
            }
        }
        
        cardMessageContainerSize.height = mediaHeight + maxTextHeight + buttonInsets.top
        + Double(maxNumberOfChoices) * (buttonHeight + buttonInsets.bottom)
        + (numberOfCards == 1 ? 0 : (pageControlHeight + pageControlInsets + 3 * pageControlInsets ))
        
        cardMessageContainerSize.width = carouselBackgroundMaxWidth(for: message)
        
        return cardMessageContainerSize
    }
    func carouselChoiceMessageContainerSize(for message: Message) -> CGSize {
        
        var carouselChoiceMessageContainerSize: CGSize = .zero
        
        var numberOfCarouselChoices = 0
     
        if let carouselMessage = message.body as? MessageCarousel {
            numberOfCarouselChoices = carouselMessage.choices.count
        }
        if numberOfCarouselChoices == 0 {
            carouselChoiceMessageContainerSize.height = 0
        } else {
            carouselChoiceMessageContainerSize.height =  carouselChoiceButtonInsets.top +
            Double(numberOfCarouselChoices) * buttonHeight +
            Double(numberOfCarouselChoices - 1) * buttonInsets.bottom +
            carouselChoiceButtonInsets.bottom
        }
      
        carouselChoiceMessageContainerSize.width = carouselBackgroundMaxWidth(for: message)
        
        return carouselChoiceMessageContainerSize
    }
    
    private func adjustCardsHeightAndButtonsPosition(_ frames: [CardAttributes], _ maxCardHeight: Double, _ firstButtonMaxYPosition: Double) -> [CardAttributes] {
        
        var cardFrames: [CardAttributes] = []
        for cardAttribute in frames {
            var attribute = cardAttribute
            attribute.frame.size.height = maxCardHeight
            
            var buttonFrames: [CGRect] = []
            for buttonFrame in attribute.buttonFrames {
                var newButtonFrame = buttonFrame
                newButtonFrame.origin.y =  buttonFrame.origin.y + firstButtonMaxYPosition
                buttonFrames.append(newButtonFrame)
            }
            attribute.buttonFrames = buttonFrames
            cardFrames.append(attribute)
        }
        return cardFrames
    }
    
    func cardFrames(for message: Message, messageContainerSize: CGSize) -> [CardAttributes] {
        
        var frames: [CardAttributes] = []
        var cardFrames: [CardAttributes] = []
        
        var firstButtonMaxYPosition = 0.0
        var maxCardHeight = 0.0
        
        if let carouselMessage = message.body as? MessageCarousel {
            
            for (index, card) in carouselMessage.cards.enumerated() {
                var cardRect: CGRect = .zero
                let mediaFrame = CGRect(x:  0,
                                        y: 0,
                                        width: messageContainerSize.width,
                                        height: mediaHeight)
                
                let messageLabelSize: CGSize = messageLabelSize(for: message, cardMessage: card)
                let titleLabelSize: CGSize = titleLabelSize(for: message, cardMessage: card)
                let buttonYPosition = mediaFrame.size.height + titleLabelSize.height + messageLabelSize.height
                
                if firstButtonMaxYPosition < buttonYPosition {
                    firstButtonMaxYPosition = buttonYPosition
                }
                
                cardRect.origin.x = CGFloat(index) * messageContainerSize.width
                cardRect.size.height = mediaHeight + titleLabelSize.height + messageLabelSize.height + buttonInsets.top
                + Double(card.choices.count) * (buttonHeight + buttonInsets.bottom)
                cardRect.size.width = messageContainerSize.width
                
                if maxCardHeight < cardRect.size.height {
                    maxCardHeight = cardRect.size.height
                }
                
                let dataSource = messagesLayout.chatDataSource
                let isFromCurrentSender = dataSource.isFromCurrentSender(message: message)
                let xCordMessage: CGFloat
                let xCordTitle: CGFloat
                
                if UIView.userInterfaceLayoutDirection(
                    for: messagesLayout.messagesCollectionView.semanticContentAttribute) == .rightToLeft {
                    
                    xCordMessage =  messageContainerSize.width - messageLabelSize.width
                    xCordTitle =  messageContainerSize.width - titleLabelSize.width
                } else {
                    xCordMessage = isFromCurrentSender ? messageContainerSize.width - messageLabelSize.width : 0
                    xCordTitle =  isFromCurrentSender ? messageContainerSize.width - titleLabelSize.width : 0
                    
                }
                
                let titleLabelFrame =  CGRect(x:  xCordTitle,
                                              y: mediaFrame.maxY,
                                              width: titleLabelSize.width,
                                              height: titleLabelSize.height)
                let messageLabelFrame =  CGRect(x:  xCordMessage,
                                                y: titleLabelFrame.maxY,
                                                width: messageLabelSize.width,
                                                height: messageLabelSize.height)
                var buttonsFrame: [CGRect] = []
                
                for counter in 0..<card.choices.count {
                    
                    let buttonFrame = CGRect(x: buttonInsets.left,
                                             y: buttonInsets.top  + (Double(counter) * (buttonHeight + buttonInsets.bottom)),
                                             width: messageContainerSize.width - buttonInsets.left - buttonInsets.right,
                                             height: buttonHeight)
                    buttonsFrame.append(buttonFrame)
                }
                
                frames.append(CardAttributes(frame: cardRect,
                                             mediaFrame: mediaFrame,
                                             titleFrame: titleLabelFrame,
                                             messageFrame: messageLabelFrame,
                                             buttonFrames: buttonsFrame))
            }
            
            cardFrames = adjustCardsHeightAndButtonsPosition(frames, maxCardHeight, firstButtonMaxYPosition)
        }
        return cardFrames
    }
    public override func configure(attributes: UICollectionViewLayoutAttributes) {
        super.configure(attributes: attributes)
        guard let attributes = attributes as? ChatFlowLayoutAttributes else { return }
        
        let dataSource = messagesLayout.chatDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        var numberOfChoices = 0
        if let message = message.body as? MessageCarousel {
            numberOfChoices = message.choices.count
        }

        var carouselContentViewSize = carouselBackgroundViewSize(for: message)
        carouselContentViewSize.width = carouselBackgroundMaxWidth(for: message)
        
        attributes.carouselCardFrames = cardFrames(for: message, messageContainerSize: carouselContentViewSize)
        let maxCardHeight = attributes.carouselCardFrames.map { $0.frame.size.height }.max()
        
        let cardContainerSize = cardMessageContainerSize(for: message)

        attributes.carouselCardViewFrame = CGRect(x: backgroundViewSpacing, y: backgroundViewSpacing, width: cardContainerSize.width, height: cardContainerSize.height)
        let carouselChoiceButtonsViewSize = carouselChoiceMessageContainerSize(for: message)

        attributes.carouselChoiceButtonsViewFrame =  CGRect(x: backgroundViewSpacing,
                                                            y: attributes.carouselCardViewFrame.maxY + 1,
                                                            width: carouselChoiceButtonsViewSize.width,
                                                            height: carouselChoiceButtonsViewSize.height)

        var buttonsFrame: [CGRect] = []
        
        for counter in 0..<numberOfChoices {
       
            let buttonFrame = CGRect(x: carouselChoiceButtonInsets.left,
                                     y: carouselChoiceButtonInsets.top + (Double(counter) * (buttonHeight + buttonInsets.bottom)),
                                     width: carouselContentViewSize.width - carouselChoiceButtonInsets.left - carouselChoiceButtonInsets.right,
                                     height: buttonHeight)
            buttonsFrame.append(buttonFrame)
        }
        
        let dateLabelSize = dateLabelSize(for: message)
        let dateLabelFrame = CGRect(x: attributes.messageContainerSize.width - dateLabelSize.width - dateLabelInsets.right,
                                    y:  carouselContentViewSize.height - dateLabelSize.height - backgroundViewSpacing,
                                    width: dateLabelSize.width,
                                    height: dateLabelSize.height)
        
        attributes.carouselCardFrames = cardFrames(for: message, messageContainerSize: carouselContentViewSize)
        attributes.pageControlFrame = CGRect(x: 0,
                                             y: (maxCardHeight ?? 0) + pageControlInsets,
                                             width: carouselContentViewSize.width,
                                             height: pageControlHeight)

        attributes.buttonsFrame = buttonsFrame
        attributes.dateLabelInsets = dateLabelInsets
        attributes.dateLabelTextInsets = dateLabelTextInsets
        attributes.dateLabelFont = dateLabelFont
        attributes.dateLabelFrame = dateLabelFrame

        attributes.carouselContentViewFrame = CGRect(x: 0,
                                                     y: 0,
                                                     width: carouselContentViewSize.width,
                                                     height: carouselContentViewSize.height)
        
    }
}
