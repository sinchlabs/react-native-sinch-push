import UIKit

@MainActor
class MessageSizeCalculator: ChatCellSizeCalculator {
    
    public var dateLabelFont = UIFont.preferredFont(forTextStyle: .caption2)
    public var dateLabelInsets = UIEdgeInsets(top: 5, left: 8, bottom: 8, right: 8)
    public var dateLabelTextInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    public var buttonHeight = 36.0
    public var statusLabelFont = UIFont.preferredFont(forTextStyle: .caption2)
    public var statusImageWidth = 16.0
    public var statusSpacing = 4.0
    
    init(layout: ChatFlowLayout? = nil) {
        super.init()
        
        self.layout = layout
    }
    
    public var incomingAvatarSize = CGSize(width: 30, height: 30)
    public var outgoingAvatarSize = CGSize(width: 0, height: 0)
    public var incomingAvatarPosition = AvatarPosition(horizontal: .left)
    public var outgoingAvatarPosition = AvatarPosition(horizontal: .right)
    public var avatarLeadingTrailingPadding: CGFloat = 24
    public var incomingMessagePadding = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 71)
    public var outgoingMessagePadding = UIEdgeInsets(top: 5, left: 71, bottom: 5, right: 24)
    
    open override func configure(attributes: UICollectionViewLayoutAttributes) {
        guard let attributes = attributes as? ChatFlowLayoutAttributes else { return }
        
        let dataSource = messagesLayout.chatDataSource
        let indexPath = attributes.indexPath
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        
        attributes.avatarSize = avatarSize(for: message)
        attributes.avatarLeadingTrailingPadding = avatarLeadingTrailingPadding
        attributes.avatarPosition = avatarPosition(for: message)
        attributes.messageContainerPadding = messageContainerPadding(for: message)
        attributes.messageContainerSize = messageContainerSize(for: message)
        attributes.statusViewSize = statusSize(message: message, in: messagesLayout.messagesCollectionView)
        
    }
    
    open override func sizeForItem(at indexPath: IndexPath) -> CGSize {
        let dataSource = messagesLayout.chatDataSource
        let message = dataSource.messageForItem(at: indexPath, in: messagesLayout.messagesCollectionView)
        var itemHeight = cellContentHeight(for: message, at: indexPath)
        let padding = messageContainerPadding(for: message)
        let status = statusSize(message: message, in: messagesLayout.messagesCollectionView)
        itemHeight += status.height
        itemHeight += (padding.top + padding.bottom)
        return CGSize(width: messagesLayout.itemWidth, height: itemHeight)
    }
  
    func cellContentHeight(for message: Message, at indexPath: IndexPath) -> CGFloat {
        
        let messageContainerHeight = messageContainerSize(for: message).height
        let avatarHeight = avatarSize(for: message).height
        
        let totalLabelHeight: CGFloat = messageContainerHeight
        let cellHeight = max(avatarHeight, totalLabelHeight)
        return cellHeight
    }
    func statusSize(message: Message, in messagesCollectionView: MessageCollectionView) -> CGSize {

        if message.isFromCurrentUser() {
            
            let attributedText = NSAttributedString(string: message.status.localizedDescription(localizedConfig: messagesCollectionView.localizationConfig),
                                                    attributes: [.font: statusLabelFont])
            let labelSize = labelSize(for: attributedText, considering: messageContainerMaxWidth(for: message))
            let imagesWidth = (statusImageWidth + statusSpacing)
        
            return CGSize(width:labelSize.width + imagesWidth, height: labelSize.height)
            
        } else {
            return .zero
        }
    }
    
    // MARK: - Avatar
    
    func avatarPosition(for message: Message) -> AvatarPosition {
        let dataSource = messagesLayout.chatDataSource
        let isFromCurrentSender = dataSource.isFromCurrentSender(message: message)
        var position = isFromCurrentSender ? outgoingAvatarPosition : incomingAvatarPosition
        
        switch position.horizontal {
        case .left, .right:
            break
        case .notSet:
            position.horizontal = isFromCurrentSender ? .right : .left
        case .noAvatar:
            position.horizontal = .noAvatar
        }
        return position
    }
    
    func avatarSize(for message: Message) -> CGSize {
        let dataSource = messagesLayout.chatDataSource
        let isFromCurrentSender = dataSource.isFromCurrentSender(message: message)
        return isFromCurrentSender ? outgoingAvatarSize : incomingAvatarSize
    }
    
    // MARK: - MessageContainer
    
    func messageContainerPadding(for message: Message) -> UIEdgeInsets {
        let dataSource = messagesLayout.chatDataSource
        let isFromCurrentSender = dataSource.isFromCurrentSender(message: message)
        return isFromCurrentSender ? outgoingMessagePadding : incomingMessagePadding
    }
    
    func messageContainerSize(for message: Message) -> CGSize {
        // Returns .zero by default
        return .zero
    }
    
    func messageContainerMaxWidth(for message: Message) -> CGFloat {
        let avatarWidth = avatarSize(for: message).width
        let messagePadding = messageContainerPadding(for: message)
        
        return messagesLayout.itemWidth - avatarWidth - messagePadding.left - messagePadding.right  - avatarLeadingTrailingPadding
    }
    func dateLabelSize(for message: Message) -> CGSize {
        
        let maxWidth = messageContainerMaxWidth(for: message)
        var dateLabelSize: CGSize = .zero
        
        if let dateInSeconds = message.body.sendDate {
            
            dateLabelSize = labelSize(for: NSAttributedString(string: Date(timeIntervalSince1970:
                                                                            TimeInterval(dateInSeconds)).getFormattedTime(),
                                                              attributes: [.font: dateLabelFont]), considering: maxWidth)
            dateLabelSize.width += (dateLabelTextInsets.left + dateLabelTextInsets.right)
            dateLabelSize.height += (dateLabelTextInsets.top + dateLabelTextInsets.bottom)
        }
        
        return dateLabelSize
        
    }
    
    // MARK: - Helpers
    
    var messagesLayout: ChatFlowLayout {
        guard let layout = layout as? ChatFlowLayout else {
            fatalError("Layout object is missing or is not a MessagesCollectionViewFlowLayout")
        }
        return layout
    }
    
    internal func labelSize(for attributedText: NSAttributedString, considering maxWidth: CGFloat) -> CGSize {
        let constraintBox = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        let rect = attributedText.boundingRect(with: constraintBox, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral
        
        return rect.size
    }
}

fileprivate extension UIEdgeInsets {
    init(top: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0, right: CGFloat = 0) {
        self.init(top: top, left: left, bottom: bottom, right: right)
    }
}
