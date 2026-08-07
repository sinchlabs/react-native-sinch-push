import UIKit

final class CardMessageCell: ImageBaseCell {
    
    static let cellId = "cardMessageCell"
    
    var messageLabel = MessageLabel()
    var titleLabel = MessageLabel()
    var message: Message?
    var buttons: [TitleButton] = []
    var buttonsFrame: [CGRect] = []
    var localizationConfig: SinchSDKConfig.LocalizationConfig?

    // MARK: - Methods
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? ChatFlowLayoutAttributes {
            messageLabel.textInsets = attributes.messageLabelTextInsets
            messageLabel.messageLabelFont = attributes.messageLabelFont
            messageLabel.frame =  attributes.messageLabelFrame

            dateLabel.messageLabelFont = attributes.dateLabelFont
            dateLabel.textInsets = attributes.dateLabelTextInsets
            dateLabel.frame =  attributes.dateLabelFrame
            imageView.frame = attributes.mediaFrame
            titleLabel.textInsets = attributes.titleLabelTextInsets
            titleLabel.messageLabelFont = attributes.titleLabelFont
            titleLabel.frame =  attributes.titleLabelFrame
            
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
        titleLabel.text = nil
        avatarView.imageView.image = nil
        for button in buttons {
            button.removeFromSuperview()
        }
        buttons.removeAll()
    }
    
    /// Responsible for setting up the constraints of the cell's subviews.
    func setupConstraints() {
        NSLayoutConstraint.activate([
            placeholderImageView.widthAnchor.constraint(equalToConstant: 123.29),
            placeholderImageView.heightAnchor.constraint(equalToConstant: 79.13),
            placeholderImageView.topAnchor.constraint(equalTo: messageContainerView.topAnchor, constant: 31),
            placeholderImageView.centerXAnchor.constraint(equalTo: messageContainerView.centerXAnchor),
            placeholderLabel.centerXAnchor.constraint(equalTo: messageContainerView.centerXAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor, constant: 20),
            placeholderLabel.trailingAnchor.constraint(equalTo: messageContainerView.trailingAnchor, constant: -20),
            placeholderLabel.topAnchor.constraint(equalTo: placeholderImageView.bottomAnchor, constant: 13),
            placeholderLabel.heightAnchor.constraint(equalToConstant: 30.0),
            
            errorImageView.widthAnchor.constraint(equalToConstant: 20.0),
            errorImageView.heightAnchor.constraint(equalToConstant: 20.0),
            errorImageView.leadingAnchor.constraint(equalTo: messageContainerView.leadingAnchor, constant: 10),
            errorImageView.topAnchor.constraint(equalTo: messageContainerView.topAnchor, constant: 10),
            activityIndicator.centerXAnchor.constraint(equalTo: errorImageView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: errorImageView.centerYAnchor)
            
        ])
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        messageContainerView.addSubview(placeholderImageView)
        messageContainerView.addSubview(placeholderLabel)
        messageContainerView.addSubview(errorImageView)
        messageContainerView.addSubview(imageView)
        messageContainerView.addSubview(activityIndicator)
        messageContainerView.addSubview(titleLabel)
        messageContainerView.addSubview(messageLabel)
        messageContainerView.addSubview(dateLabel)
        statusView.isHidden = true

        setupConstraints()
    }
    
    override func configure(with message: Message, at indexPath: IndexPath, and messagesCollectionView: MessageCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        self.localizationConfig =  messagesCollectionView.localizationConfig
        self.message = message

        setupContainerView(messagesCollectionView, message)
        setupPlaceholderView(messagesCollectionView, message)
        setupImageView(message: message, localizationConfig: messagesCollectionView.localizationConfig)
    
        if let message = message.body as? MessageCard {
            titleLabel.text = message.title
        }
        
        setupMessageLabel(messageLabel, message, messagesCollectionView)

        if let message = message.body as? MessageCard {
            setupButtons( choices: message.choices, messagesCollectionView: messagesCollectionView)
        }
        
        dateLabel.configure {
            
            if let dateInSeconds = message.body.sendDate {
                
                dateLabel.text =  Date(timeIntervalSince1970: TimeInterval(dateInSeconds)).getFormattedTime()
            }
        }
        
        if let titleFont = titleLabel.messageLabelFont {
            titleLabel.font = titleFont
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

        if !messageContainerView.frame.contains(touchLocation) {
            delegate?.didTapOutsideOfContent(in: self)
        } else if imageView.convert(imageView.frame, to: self.contentView).contains(touchLocation) {
            if !activityIndicator.isAnimating {
                if  let error = error, let localizationConfiguration = localizationConfig, let message = message, error {
            
                    setupImageView(message: message, localizationConfig:  localizationConfiguration)
                    
                } else {
                    if let message = message?.body as? MessageCard, let url = URL(string: message.url) {
                        delegate?.didTapMedia(with: url)
                    }
                }
            }
        } else if messageContainerView.frame.contains(touchLocation) {
            
            messageLabel.handleGesture(convert(touchLocation, to: messageLabel))
            debugPrint("user tap text")
        } else {
            delegate?.didTapOutsideOfContent(in: self)

        }
    }
    
    @objc func choiceButtonTapped(_ sender: AnyObject) {
        debugPrint("button tapped")
        if let button = sender as? TitleButton, let body = message?.body as? MessageCard {
            button.changeButtonAppearanceInChat()
            let tag = button.tag
            let choices = body.choices
            delegate?.didTapOnChoice(choices[tag], in: self)
            
        }
    }
}
