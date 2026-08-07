import UIKit

final class DateMessageCell: EventMessageCell {
    
    static let dateCellId = "dateMessageCell"
    
    override func setupContainerView(_ messagesCollectionView: MessageCollectionView, _ message: Message) {
        delegate = messagesCollectionView.touchDelegate

        messageContainerView.backgroundColor = messagesCollectionView.uiConfig.systemDateBackgroundColor
        messageLabel.textColor = messagesCollectionView.uiConfig.systemDateTextColor
        
    }
    
    override func configure(with message: Message, at indexPath: IndexPath, and messagesCollectionView: MessageCollectionView) {
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        
        if let body = message.body as? MessageDate,
            let dateInSeconds = body.sendDate {

            messageLabel.text = Date(timeIntervalSince1970: TimeInterval(dateInSeconds)).getFormattedDate(localizationConfiguration: messagesCollectionView.localizationConfig)
        }
        
        if let font = messageLabel.messageLabelFont {
            messageLabel.font = font
        }
        
        setupContainerView(messagesCollectionView, message)
    }
}
