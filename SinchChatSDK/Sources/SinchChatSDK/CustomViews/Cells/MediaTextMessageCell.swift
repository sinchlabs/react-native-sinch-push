import UIKit

final class MediaTextMessageCell: ImageBaseCell, MessageStatusDelegate {
    
    static let cellId = "mediaTextMessageCell"
    
    var messageLabel = MessageLabel()
    var message: Message?
    var localizationConfig: SinchSDKConfig.LocalizationConfig?

    // MARK: - Methods
    
    /// Responsible for setting up the constraints of the cell's subviews.
    func setupConstraints() {
        NSLayoutConstraint.activate([
         
            imageView.topAnchor.constraint(equalTo: messageContainerView.topAnchor, constant: 0),
            imageView.leftAnchor.constraint(equalTo: messageContainerView.leftAnchor, constant: 0),
            imageView.rightAnchor.constraint(equalTo: messageContainerView.rightAnchor, constant: 0),
            imageView.heightAnchor.constraint(equalToConstant: 187),

            placeholderImageView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            placeholderImageView.widthAnchor.constraint(equalToConstant: 123.29),
            placeholderImageView.heightAnchor.constraint(equalToConstant: 79.13),
            placeholderImageView.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 31),
            placeholderLabel.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
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
        messageContainerView.addSubview(messageLabel)
        messageContainerView.addSubview(dateLabel)
        statusView.delegate = self

        setupConstraints()
    }
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? ChatFlowLayoutAttributes {
            messageLabel.textInsets = attributes.messageLabelTextInsets
            messageLabel.messageLabelFont = attributes.messageLabelFont
            dateLabel.messageLabelFont = attributes.dateLabelFont
            dateLabel.textInsets = attributes.dateLabelTextInsets
            messageLabel.frame =  attributes.messageLabelFrame
            dateLabel.frame =  attributes.dateLabelFrame
        }
    }
       
    override func configure(with message: Message, at indexPath: IndexPath, and messagesCollectionView: MessageCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        self.message = message
        self.localizationConfig =  messagesCollectionView.localizationConfig

        setupPlaceholderView(messagesCollectionView, message)
        
        setupImageView(message: message, localizationConfig: messagesCollectionView.localizationConfig)

        setupMessageLabel(messageLabel, message, messagesCollectionView)

            
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
      
            setupContainerView(messagesCollectionView, message)
        }
    private func setupContainerView(_ messagesCollectionView: MessageCollectionView, _ message: Message) {
        delegate = messagesCollectionView.touchDelegate

        if message.isFromCurrentUser() {
            messageContainerView.backgroundColor = messagesCollectionView.uiConfig.outgoingMessageBackgroundColor
            statusView.isHidden = false
            statusView.setupStatusView(message.status, in: messagesCollectionView)
            messageLabel.textColor = messagesCollectionView.uiConfig.outgoingMessageTextColor
        } else {
            messageContainerView.backgroundColor = messagesCollectionView.uiConfig.incomingMessageBackgroundColor
            statusView.isHidden = true
            messageLabel.textColor = messagesCollectionView.uiConfig.incomingMessageTextColor
            avatarView.updateWithModel(message, uiConfig: messagesCollectionView.uiConfig)
        }
        dateLabel.textColor = messagesCollectionView.uiConfig.dateMessageLabelTextColor
    }
    
    /// Handle tap gesture on contentView and its subviews.
    override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self.contentView)

        if imageView.convert(imageView.frame, to: self.contentView).contains(touchLocation) {
            if !activityIndicator.isAnimating {
                if  let error = error, let localizationConfiguration = localizationConfig, let message = message, error {
                    
                    setupImageView(message: message, localizationConfig: localizationConfiguration)
                                    
                } else {
                    if let message = message?.body as? MessageMediaText, let url = URL(string: message.url) {
                        delegate?.didTapMedia(with: url)
                    }
                }
            }
        } else if messageContainerView.frame.contains(touchLocation) {
            debugPrint("user tap text")
        } else {
            delegate?.didTapOutsideOfContent(in: self)

        }
    }
    func retryTapped() {
        if let message = message {
            delegate?.didTapOnResend(message: message, in: self)
        }
    }
}
