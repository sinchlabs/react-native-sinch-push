import UIKit

class ChoicesMessageCell: MessageContentCell {
    
    static let cellId = "choicesMessageCell"
        
    var messageLabel = MessageLabel()
    var dateLabel = MessageLabel()
    var buttons: [TitleButton] = []
    var message: Message?
    var buttonsFrame: [CGRect] = []
    // MARK: - Methods
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? ChatFlowLayoutAttributes {
            messageLabel.textInsets = attributes.messageLabelTextInsets
            messageLabel.messageLabelFont = attributes.messageLabelFont
            dateLabel.messageLabelFont = attributes.dateLabelFont
            dateLabel.textInsets = attributes.dateLabelTextInsets
            messageLabel.frame =  attributes.messageLabelFrame
            dateLabel.frame =  attributes.dateLabelFrame
            if buttons.count == attributes.buttonsFrame.count {
                for index in 0..<attributes.buttonsFrame.count {
                    buttons[index].frame = attributes.buttonsFrame[index]
                }
            }
            buttonsFrame = attributes.buttonsFrame
            
        }
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        dateLabel.text = nil
        messageLabel.text = nil
        avatarView.imageView.image = nil
        for button in buttons {
            button.removeFromSuperview()
        }
        buttons.removeAll()
        
    }
    
    // MARK: - Methods
    
    override func setupSubviews() {
        super.setupSubviews()
        statusView.isHidden = true

        messageContainerView.addSubview(messageLabel)
        messageContainerView.addSubview(dateLabel)
    }
    
    override func configure(with message: Message, at indexPath: IndexPath, and messagesCollectionView: MessageCollectionView) {
        self.message = message
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
      
        setupContainerView(messagesCollectionView, message)
        
        setupMessageLabel(messageLabel, message, messagesCollectionView)
        
        if let message = message.body as? MessageChoices {
                setupButtons( choices: message.choices, messagesCollectionView: messagesCollectionView)
        }
        
        dateLabel.configure {
            
            if let dateInSeconds = message.body.sendDate {
                
                dateLabel.text =  Date(timeIntervalSince1970: TimeInterval(dateInSeconds)).getFormattedTime()
            }
        }
        
        if let font = messageLabel.messageLabelFont {
            messageLabel.font = font
        }
        if let dateFont = dateLabel.messageLabelFont {
            dateLabel.font = dateFont
        }
    }
    private func setupButtons(choices: [ChoiceMessageType], messagesCollectionView: MessageCollectionView) {
        for index in 0..<choices.count {
                    
            let button = TitleButton(frame: buttonsFrame[index], with: messagesCollectionView.uiConfig)
            button.titleLabel?.font = messagesCollectionView.uiConfig.buttonTitleFont
            button.setTitleColor( messagesCollectionView.uiConfig.buttonTitleColor, for: .normal)
            button.setTitleColor( messagesCollectionView.uiConfig.tappedButtonTitleColor, for: .selected)
            button.backgroundColor = messagesCollectionView.uiConfig.buttonBackgroundColor
            
            switch choices[index] {
            case .textMessage(let message):
                button.setTitle(message.text, for: .normal)

            case .urlMessage(let message):
                button.setTitle(message.text, for: .normal)

            case .callMessage(let message):
                button.setTitle(message.text, for: .normal)

            case .locationMessage(let message):
                button.setTitle(message.label, for: .normal)

            }
            button.tag = index
            button.addTarget(self, action: #selector(choiceButtonTapped(_ :)), for: .touchUpInside)

            buttons.append(button)
            messageContainerView.addSubview(button)

        }
    }
    
    private func setupContainerView(_ messagesCollectionView: MessageCollectionView, _ message: Message) {
        delegate = messagesCollectionView.touchDelegate
        
        if message.isFromCurrentUser() {
            messageContainerView.backgroundColor = messagesCollectionView.uiConfig.outgoingMessageBackgroundColor
            messageLabel.textColor = messagesCollectionView.uiConfig.outgoingMessageTextColor
        } else {
            messageContainerView.backgroundColor = messagesCollectionView.uiConfig.incomingMessageBackgroundColor
            messageLabel.textColor = messagesCollectionView.uiConfig.incomingMessageTextColor
            avatarView.updateWithModel(message, uiConfig: messagesCollectionView.uiConfig)
        }
        dateLabel.textColor = messagesCollectionView.uiConfig.dateMessageLabelTextColor
    }
    
    /// Handle tap gesture on contentView and its subviews.
    override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self.contentView)
        
            if messageContainerView.frame.contains(touchLocation) {
                messageLabel.handleGesture(convert(touchLocation, to: messageLabel))
            } else {
                delegate?.didTapOutsideOfContent(in: self)
            }
    }
    
    @objc func choiceButtonTapped(_ sender: AnyObject) {
        debugPrint("button tapped")

        if let button = sender as? TitleButton, let body = message?.body as? MessageChoices {
            button.changeButtonAppearanceInChat()
            let tag = button.tag
            let choices = body.choices
            delegate?.didTapOnChoice(choices[tag], in: self)
            
        }
    }
}
