import UIKit

/// A subclass of `MessageCollectionViewCell` used to display text 
class MessageContentCell: MessageCollectionViewCell {

    /// The image view displaying the avatar.
    var avatarView = AvatarView()
    lazy var statusView = MessageStatusView()
    weak var delegate: MessageCellDelegate?
    /// The container used for styling and holding the message's content view.
    var messageContainerView: UIView = {
        let containerView = UIView()
        containerView.backgroundColor = .white
        containerView.clipsToBounds = true
        containerView.layer.masksToBounds = true
        return containerView
    }()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        setupSubviews()
    }

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        setupSubviews()
    }

    func setupSubviews() {
    
        contentView.addSubview(messageContainerView)
        contentView.addSubview(avatarView)
        contentView.addSubview(statusView)

    }

    override func prepareForReuse() {
        super.prepareForReuse()

    }

    // MARK: - Configuration

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        guard let attributes = layoutAttributes as? ChatFlowLayoutAttributes else { return }

        layoutMessageContainerView(with: attributes)
        layoutAvatarView(with: attributes)
        layoutStatusView(with: attributes)

    }
    func addCustomDetector(_ message: Message, _ messagesCollectionView: MessageCollectionView, _ enabledDetectors: inout [Detector]) {
        
        if !message.body.isExpanded {
            
            let patternText = messagesCollectionView.localizationConfig.collapsedTextMessageButtonTitle
            
            let pattern = patternText + "$"
            let regex = try? NSRegularExpression(pattern: pattern, options: [])
            
            if let regex = regex {
                enabledDetectors.append(.custom(regex))
            }
        }
    }
    func setupMessageLabel(_ label: MessageLabel, _ message: Message, _ messagesCollectionView: MessageCollectionView) {
        var enabledDetectors: [Detector] = [.url]
        addCustomDetector(message, messagesCollectionView, &enabledDetectors)
        
        label.configure {
            label.enabledDetectors = enabledDetectors
            for detector in enabledDetectors {
                
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key.foregroundColor: messagesCollectionView.uiConfig.messageUrlLinkTextColor,
                    NSAttributedString.Key.underlineStyle: NSUnderlineStyle.single.rawValue,
                    NSAttributedString.Key.underlineColor: messagesCollectionView.uiConfig.messageUrlLinkTextColor
                ]
                label.setAttributes(attributes, detector: detector)
            }
            
            label.message = message
            label.text = message.body.getReadMore(maxCount: messagesCollectionView.uiConfig.numberOfCharactersBeforeCollapseTextMessage,
                                                  textToAdd: messagesCollectionView.localizationConfig.collapsedTextMessageButtonTitle)
            
        }
        label.delegate = messagesCollectionView.touchDelegate
    }
    func configureContainerViewCornerRadius(message: Message) {
      
        switch message.owner {
            
        case .outgoing:
            messageContainerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner]
        case .incoming(_):
            messageContainerView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner, .layerMinXMinYCorner]
        case .system:
            messageContainerView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner, .layerMinXMinYCorner, .layerMinXMaxYCorner]

        }
                
        messageContainerView.layer.cornerRadius = 10.0
        messageContainerView.layer.masksToBounds = true
    }
    
    func configureAvatarView(message: Message, messagesCollectionView: MessageCollectionView) {
        
        switch message.owner {
            
        case .outgoing:
            avatarView.isHidden = true
        case .incoming(_):
            avatarView.isHidden = false
            avatarView.updateWithModel(message, uiConfig: messagesCollectionView.uiConfig)
        case .system:
            avatarView.isHidden = true

        }
    }
    func configureStatus(message: Message) {
      
        switch message.owner {
            
        case .outgoing:
            statusView.isHidden = false
        default:
            statusView.isHidden = true

        }
    }
    /// Used to configure the cell.
    ///
    /// - Parameters:
    ///   - message: The `MessageType` this cell displays.
    ///   - indexPath: The `IndexPath` for this cell.
    ///   - messagesCollectionView: The `MessagesCollectionView` in which this cell is contained.
    func configure(with message: Message, at indexPath: IndexPath, and messagesCollectionView: MessageCollectionView) {
        
        configureContainerViewCornerRadius(message: message)
        configureAvatarView(message: message, messagesCollectionView: messagesCollectionView)
        configureStatus(message: message)
    }

    /// Handle long press gesture, return true when gestureRecognizer's touch point in `messageContainerView`'s frame
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let touchPoint = gestureRecognizer.location(in: self)
        guard gestureRecognizer.isKind(of: UILongPressGestureRecognizer.self) else { return false }
        return messageContainerView.frame.contains(touchPoint)
    }

    /// Handle `ContentView`'s tap gesture, return false when `ContentView` doesn't needs to handle gesture
    func cellContentView(canHandle touchPoint: CGPoint) -> Bool {
        return false
    }

    // MARK: - Origin Calculations

    /// Positions the cell's `AvatarView`.
    /// - attributes: The `MessagesCollectionViewLayoutAttributes` for the cell.
     func layoutAvatarView(with attributes: ChatFlowLayoutAttributes) {
        var origin: CGPoint = .zero
        let padding = attributes.avatarLeadingTrailingPadding
        
        origin.x = padding
        origin.y = messageContainerView.frame.size.height/2 - (attributes.avatarSize.height/2)

        avatarView.frame = CGRect(origin: origin, size: attributes.avatarSize)
    }
    /// Positions the cell's `MessageContainerView`.
    /// - attributes: The `MessagesCollectionViewLayoutAttributes` for the cell.
    func layoutMessageContainerView(with attributes: ChatFlowLayoutAttributes) {
        var origin: CGPoint = .zero

        if attributes.avatarSize.height > attributes.messageContainerSize.height {
            let messageHeight = attributes.messageContainerSize.height + attributes.messageContainerPadding.top + attributes.messageContainerPadding.bottom
            origin.y = (attributes.size.height / 2) - (messageHeight / 2)
        } else {
            origin.y = attributes.messageContainerPadding.top

        }

        let avatarPadding = attributes.avatarLeadingTrailingPadding
        switch attributes.avatarPosition.horizontal {
        case .left:
            origin.x = attributes.avatarSize.width + attributes.messageContainerPadding.left + avatarPadding

        case .right:
            origin.x = attributes.frame.width - attributes.avatarSize.width - attributes.messageContainerSize.width - attributes.messageContainerPadding.right
        case .noAvatar:
            origin.x = attributes.frame.width/2 - attributes.messageContainerSize.width/2

        default:
            break
        }
            
        messageContainerView.frame = CGRect(origin: origin, size: attributes.messageContainerSize)
    }
    /// Positions the cell's `StatusView`.
    /// - attributes: The `MessagesCollectionViewLayoutAttributes` for the cell.
     func layoutStatusView(with attributes: ChatFlowLayoutAttributes) {
        
         statusView.frame = CGRect(x: messageContainerView.frame.maxX - attributes.statusViewSize.width,
                                   y: messageContainerView.frame.maxY,
                                   width: attributes.statusViewSize.width,
                                   height: attributes.statusViewSize.height)
      
    }
    
}
