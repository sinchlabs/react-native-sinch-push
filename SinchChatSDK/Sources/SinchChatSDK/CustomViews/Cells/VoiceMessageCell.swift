import UIKit

@MainActor
protocol AudioDelegate : AnyObject {
    func startPlaying(model: Message)
    func stopPlaying(model: Message)

}
/// A subclass of `MessageContentCell` used to display text messages.
final class VoiceMessageCell: MessageContentCell, PlayAudioDelegate, MessageStatusDelegate {
    
    static let cellId = "voiceMessageCell"
    var message: Message?
    /// The label used to display the message's text.
    var messageLabel = MessageLabel()
    var dateLabel = MessageLabel()
    var playAudioView: PlayAudioView?
    // MARK: - Methods
    var mediaFrame = CGRect.zero
    weak var audioDelegate: AudioDelegate?
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? ChatFlowLayoutAttributes {
            messageLabel.textInsets = attributes.messageLabelTextInsets
            messageLabel.messageLabelFont = attributes.messageLabelFont
            dateLabel.messageLabelFont = attributes.dateLabelFont
            dateLabel.textInsets = attributes.dateLabelTextInsets
            messageLabel.frame =  attributes.messageLabelFrame
            dateLabel.frame =  attributes.dateLabelFrame
            mediaFrame = attributes.mediaFrame
            playAudioView?.frame = mediaFrame
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        messageLabel.attributedText = nil
        messageLabel.text = nil
        dateLabel.text = nil
        playAudioView?.clearView()
        message = nil
    }
    
    override func setupSubviews() {
        super.setupSubviews()
        statusView.delegate = self
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
    func setupAudioView(message: Message, messagesCollectionView: MessageCollectionView, isMessageThisMessageActive: Bool, player: AVPlayerWrapper) {
        
        if let message = message.body as? MessageMedia, let url = URL(string: message.url) {
        
            if playAudioView == nil {
            playAudioView = PlayAudioView(uiConfiguration: messagesCollectionView.uiConfig, localizationConfiguration: messagesCollectionView.localizationConfig, url: url)
            playAudioView?.delegate = self
                messageContainerView.addSubview(playAudioView!)

            }
            playAudioView?.frame = mediaFrame
            if isMessageThisMessageActive {
                playAudioView?.updateViewWithPlayer(player)
            } else {
                playAudioView?.clearView()

            }
        }
    }
    func configure(with message: Message, at indexPath: IndexPath, and messagesCollectionView: MessageCollectionView, player: AVPlayerWrapper, playingItem: PlayingItem?) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        self.message = message
        
        let enabledDetectors: [Detector] = [.url]

        messageLabel.configure {
            messageLabel.enabledDetectors = enabledDetectors
            for detector in enabledDetectors {
                
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key.foregroundColor: messagesCollectionView.uiConfig.messageUrlLinkTextColor,
                    NSAttributedString.Key.underlineStyle: NSUnderlineStyle.single.rawValue,
                    NSAttributedString.Key.underlineColor: messagesCollectionView.uiConfig.messageUrlLinkTextColor
                ]
                messageLabel.setAttributes(attributes, detector: detector)
            }
            
            messageLabel.text = messagesCollectionView.localizationConfig.voiceMessageTitle

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
        
        messageLabel.delegate = messagesCollectionView.touchDelegate
        setupContainerView(messagesCollectionView, message)
        var isMessageThisMessageActive: Bool
        
        if let playingItem = playingItem {
            
        switch playingItem {
            
        case .localMedia(url: _):
            isMessageThisMessageActive = false
        case .mediaMessage(message: let mediaMessage):
            isMessageThisMessageActive = mediaMessage.entryId == message.entryId
        }
        } else {
            isMessageThisMessageActive = false

        }
            
        setupAudioView(message: message,
                       messagesCollectionView: messagesCollectionView,
                       isMessageThisMessageActive: isMessageThisMessageActive,
                       player: player)
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
    func playPauseButtonAction() {
        if let message = message {
            audioDelegate?.startPlaying(model: message)
        }
    }
    func retryTapped() {
        if let message = message {
            delegate?.didTapOnResend(message: message, in: self)
        }
    }
}
