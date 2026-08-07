import UIKit

/// A subclass of `MessageContentCell` used to display text messages.
final class TextMessageCell: MessageContentCell {
    static let cellId = "textMessageCell"
    
    /// The label used to display the message's text.
    var messageLabel = MessageLabel()
    var dateLabel = MessageLabel()

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
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        messageLabel.attributedText = nil
        messageLabel.text = nil
        dateLabel.text = nil
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        
        messageContainerView.addSubview(messageLabel)
        messageContainerView.addSubview(dateLabel)
    }
    private func setupContainerView(_ messagesCollectionView: MessageCollectionView, _ message: Message) {
        delegate = messagesCollectionView.touchDelegate

        if message.isFromCurrentUser() {
            
            messageContainerView.backgroundColor = messagesCollectionView.uiConfig.outgoingMessageBackgroundColor
            statusView.isHidden = false
            statusView.setupStatusView(message.status, in: messagesCollectionView)
            messageLabel.textColor = messagesCollectionView.uiConfig.outgoingMessageTextColor
        } else {
            statusView.isHidden = true
            messageContainerView.backgroundColor = messagesCollectionView.uiConfig.incomingMessageBackgroundColor
            messageLabel.textColor = messagesCollectionView.uiConfig.incomingMessageTextColor
            avatarView.updateWithModel(message, uiConfig: messagesCollectionView.uiConfig)
        }
        dateLabel.textColor = messagesCollectionView.uiConfig.dateMessageLabelTextColor
    }
   
    override func configure(with message: Message, at indexPath: IndexPath, and messagesCollectionView: MessageCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
       
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
    
    /// Handle tap gesture on contentView and its subviews.
    override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self)
        
        if messageContainerView.frame.contains(touchLocation) {
            messageLabel.handleGesture(convert(touchLocation, to: messageContainerView))
        } else {
            delegate?.didTapOutsideOfContent(in: self)
        }
    }
}
