import UIKit

/// A subclass of `MessageContentCell` used to display text messages.
final class FileMessageCell: MessageContentCell {
    static let cellId = "fileMessageCell"
        
    var titleLabel = MessageLabel()
    var messageLabel = MessageLabel()
    var dateLabel = MessageLabel()
    var mediaBackgroundView: UIView = UIView()
    var message: Message?
    var imageView: UIImageView = UIImageView()
    var imageBackgroundView: UIView = UIView()

    // MARK: - Methods
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? ChatFlowLayoutAttributes {
            titleLabel.textInsets = attributes.titleLabelTextInsets
            titleLabel.messageLabelFont = attributes.titleLabelFont
            
            messageLabel.textInsets = attributes.messageLabelTextInsets
            messageLabel.messageLabelFont = attributes.messageLabelFont
            dateLabel.messageLabelFont = attributes.dateLabelFont
            dateLabel.textInsets = attributes.dateLabelTextInsets
            
            titleLabel.frame =  attributes.titleLabelFrame
            messageLabel.frame =  attributes.messageLabelFrame
            dateLabel.frame =  attributes.dateLabelFrame
            mediaBackgroundView.frame = attributes.backgroundFrame
            imageBackgroundView.frame = attributes.mediaFrame
            imageView.frame = CGRect(x: 8, y: 8, width: 24, height: 24)
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.attributedText = nil
        titleLabel.text = nil
        messageLabel.attributedText = nil
        messageLabel.text = nil
        dateLabel.text = nil
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        messageContainerView.addSubview(mediaBackgroundView)
        mediaBackgroundView.addSubview(titleLabel)
        mediaBackgroundView.addSubview(messageLabel)
        mediaBackgroundView.addSubview(imageBackgroundView)
        imageBackgroundView.addSubview(imageView)
        messageContainerView.addSubview(dateLabel)
    }
    private func setupContainerView(_ messagesCollectionView: MessageCollectionView, _ message: Message) {
        delegate = messagesCollectionView.touchDelegate

        if message.isFromCurrentUser() {

            imageBackgroundView.backgroundColor = messagesCollectionView.uiConfig.outgoingMessageBackgroundColor
            messageContainerView.backgroundColor = messagesCollectionView.uiConfig.outgoingMessageBackgroundColor
            statusView.isHidden = false
            statusView.setupStatusView(message.status, in: messagesCollectionView)
            messageLabel.textColor = messagesCollectionView.uiConfig.outgoingMessageTextColor
            titleLabel.textColor = messagesCollectionView.uiConfig.outgoingMessageTextColor

        } else {
            imageBackgroundView.backgroundColor = messagesCollectionView.uiConfig.incomingMessageBackgroundColor
            statusView.isHidden = true
            messageContainerView.backgroundColor = messagesCollectionView.uiConfig.incomingMessageBackgroundColor
            messageLabel.textColor = messagesCollectionView.uiConfig.incomingMessageTextColor
            titleLabel.textColor = messagesCollectionView.uiConfig.incomingMessageTextColor

            avatarView.updateWithModel(message, uiConfig: messagesCollectionView.uiConfig)
        }
        imageBackgroundView.layer.cornerRadius = imageBackgroundView.frame.height/2
        imageBackgroundView.layer.masksToBounds = true
        dateLabel.textColor = messagesCollectionView.uiConfig.dateMessageLabelTextColor
        mediaBackgroundView.backgroundColor = messagesCollectionView.uiConfig.viewMediaBackgroundColor
        mediaBackgroundView.layer.cornerRadius = 4.0
        mediaBackgroundView.layer.masksToBounds = true
        
        imageView.image = messagesCollectionView.uiConfig.fileMessageIcon
    }
   
    override func configure(with message: Message, at indexPath: IndexPath, and messagesCollectionView: MessageCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        self.message = message
        
        
       titleLabel.configure {
    
            if let message = message.body as? MessageMedia, let url = URL(string: message.url) {
                let text = url.lastPathComponent
                               
                titleLabel.text =  text
                titleLabel.lineBreakMode = .byTruncatingMiddle
                guard let regex = try? NSRegularExpression(pattern: text, options: []) else {return}
                let enabledDetectors: [Detector] = [.custom(regex)]
                                        
                    titleLabel.enabledDetectors = enabledDetectors
                    for detector in enabledDetectors {
                        
                        let attributes: [NSAttributedString.Key: Any] = [
                            NSAttributedString.Key.foregroundColor: messagesCollectionView.uiConfig.messageUrlLinkTextColor,
                            NSAttributedString.Key.underlineStyle: NSUnderlineStyle.single.rawValue,
                            NSAttributedString.Key.underlineColor: messagesCollectionView.uiConfig.messageUrlLinkTextColor
                        ]
                        titleLabel.setAttributes(attributes, detector: detector)
                    }
                }
           }
        
        messageLabel.configure {
    
            if let message = message.body as? MessageMedia, let _ = URL(string: message.url) {
                var text = "   "
                if case let .file(type) = message.type, let type = type?.rawValue {
                    text = type
                }
                if let size = message.size {
                    text.append("    \(size)")
                }
                
                messageLabel.text =  text
            }
        }
        dateLabel.configure {
    
            if let dateInSeconds = message.body.sendDate {

                dateLabel.text =  Date(timeIntervalSince1970: TimeInterval(dateInSeconds)).getFormattedTime()
            }
        }
        if let font = titleLabel.messageLabelFont {
            titleLabel.font = font
        }
        if let font = messageLabel.messageLabelFont {
            messageLabel.font = font
        }
        if let dateFont = dateLabel.messageLabelFont {
            dateLabel.font = dateFont
        }
        setupContainerView(messagesCollectionView, message)
    }
    
    /// Handle tap gesture on contentView and its subviews.
    override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self)
        
        if messageContainerView.frame.contains(touchLocation) {

            guard let message = message?.body as?  MessageMedia else {
                return
            }
            delegate?.didTapOnFile(url: message.url, in: self)

        }
    }
}
