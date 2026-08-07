import UIKit

class EventMessageCell: MessageContentCell {
    
    static let cellId = "eventMessageCell"
    
    /// The label used to display the message's text.
    var messageLabel = MessageLabel()
    
    // MARK: - Methods
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {

        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? ChatFlowLayoutAttributes {
            messageLabel.textInsets = attributes.messageLabelTextInsets
            messageLabel.messageLabelFont = attributes.messageLabelFont
            messageLabel.frame =  attributes.messageLabelFrame
            
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        messageLabel.attributedText = nil
        messageLabel.text = nil
        
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        statusView.isHidden = true
        messageContainerView.addSubview(messageLabel)
    }
    
    func setupContainerView(_ messagesCollectionView: MessageCollectionView, _ message: Message) {
        delegate = messagesCollectionView.touchDelegate

        messageContainerView.backgroundColor = messagesCollectionView.uiConfig.systemEventBackgroundColor
        messageLabel.textColor = messagesCollectionView.uiConfig.systemEventTextColor
        
    }
    
    override func configure(with message: Message, at indexPath: IndexPath, and messagesCollectionView: MessageCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        
        if let message = message.body as? MessageEvent {
            messageLabel.text = message.text
            
        }
        
        if let font = messageLabel.messageLabelFont {
            messageLabel.font = font
        }
        
        setupContainerView(messagesCollectionView, message)
    }
    
    /// Handle tap gesture on contentView and its subviews.
    override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self)
        
        if !messageContainerView.frame.contains(touchLocation) {

            delegate?.didTapOutsideOfContent(in: self)
        }
    }
}
