import UIKit

final class ImageMessageCell: ImageBaseCell, MessageStatusDelegate  {
    
    static let cellId = "imageMessageCell"
    var message: Message?
    var localizationConfig: SinchSDKConfig.LocalizationConfig?
    // MARK: - Methods
    
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
        statusView.delegate = self

        imageView.addSubview(dateLabel)
        
        setupConstraints()
    }
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? ChatFlowLayoutAttributes {
            
            dateLabel.messageLabelFont = attributes.dateLabelFont
            dateLabel.textInsets = attributes.dateLabelTextInsets
            dateLabel.frame =  attributes.dateLabelFrame
            imageView.frame = attributes.mediaFrame
        }
    }
       
    override func configure(with message: Message, at indexPath: IndexPath, and messagesCollectionView: MessageCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        self.message = message
        self.localizationConfig =  messagesCollectionView.localizationConfig
        setupContainerView(messagesCollectionView, message)
        setupPlaceholderView(messagesCollectionView, message)
        setupImageView(message: message, localizationConfig: messagesCollectionView.localizationConfig)

        dateLabel.configure {
            
            if let message = message.body as? MessageMedia,
               let dateInSeconds = message.sendDate {
                dateLabel.text =  Date(timeIntervalSince1970: TimeInterval(dateInSeconds)).getFormattedTime()
            }
        }
        
        setupDateLabel(messagesCollectionView)
        
        if let dateFont = dateLabel.messageLabelFont {
            dateLabel.font = dateFont
            
        }
    }
    
    private func setupContainerView(_ messagesCollectionView: MessageCollectionView, _ message: Message) {
        delegate = messagesCollectionView.touchDelegate
        
        if message.isFromCurrentUser() {
            messageContainerView.backgroundColor = messagesCollectionView.uiConfig.outgoingMessageBackgroundColor
            statusView.isHidden = false
            statusView.setupStatusView(message.status, in: messagesCollectionView)
        } else {
            statusView.isHidden = true
            messageContainerView.backgroundColor = messagesCollectionView.uiConfig.incomingMessageBackgroundColor
            avatarView.updateWithModel(message, uiConfig: messagesCollectionView.uiConfig)
        }
    }
    
    /// Handle tap gesture on contentView and its subviews.
    override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: imageView)
        
        guard imageView.frame.contains(touchLocation) else {
            delegate?.didTapOutsideOfContent(in: self)
            return
        }
        if !activityIndicator.isAnimating {
            if let error = error, let localizationConfiguration = localizationConfig, let message = message, error {

                setupImageView(message: message, localizationConfig: localizationConfiguration)
                
            } else {
                
                if let message = message?.body as? MessageMedia, let url = URL(string: message.url) {
                    delegate?.didTapMedia(with: url)
                }
                
            }
        }
    }
    func retryTapped() {
        if let message = message {
            delegate?.didTapOnResend(message: message, in: self)
        }
    }
}
