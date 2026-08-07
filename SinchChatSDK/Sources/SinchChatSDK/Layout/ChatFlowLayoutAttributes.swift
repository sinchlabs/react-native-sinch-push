import UIKit

struct CardAttributes: Equatable {
    var frame: CGRect = .zero
    var mediaFrame: CGRect = .zero
    var titleFrame: CGRect = .zero
    var messageFrame: CGRect = .zero
    var buttonFrames: [CGRect] = [.zero]

}

/// The layout attributes used by a `MessageCollectionViewCell` to layout its subviews.
/// 
 class ChatFlowLayoutAttributes: UICollectionViewLayoutAttributes {
    
    // MARK: - Properties
    
    public var avatarSize: CGSize = .zero
    public var avatarLeadingTrailingPadding: CGFloat = 0
    public var messageContainerSize: CGSize = .zero
    public var messageContainerPadding: UIEdgeInsets = .zero
    public var messageLabelFrame: CGRect = .zero
    public var messageLabelFont: UIFont = UIFont.preferredFont(forTextStyle: .body)
    public var messageLabelTextInsets: UIEdgeInsets = .zero
    public var titleLabelFrame: CGRect = .zero
    public var titleLabelFont: UIFont = UIFont.preferredFont(forTextStyle: .body)
    public var titleLabelTextInsets: UIEdgeInsets = .zero
    public var dateLabelFrame: CGRect = .zero
    public var dateLabelInsets: UIEdgeInsets = .zero
    public var dateLabelTextInsets: UIEdgeInsets = .zero
    public var dateLabelFont: UIFont = UIFont.preferredFont(forTextStyle: .caption2)
    public var mapFrame: CGRect = .zero
    public var buttonsFrame: [CGRect] = [.zero]
    public var buttonInsets: UIEdgeInsets = .zero
    public var mediaFrame: CGRect = .zero
    public var statusViewSize: CGSize = .zero
    public var pageControlFrame: CGRect = .zero
    public var carouselCardFrames: [CardAttributes] = []
    public var avatarPosition = AvatarPosition(horizontal: .notSet)
    public var carouselContentViewFrame: CGRect = .zero
    public var carouselCardViewFrame: CGRect = .zero
    public var carouselChoiceButtonsViewFrame: CGRect = .zero
    public var backgroundFrame: CGRect = .zero

    // MARK: - Methods
    
    override func copy(with zone: NSZone? = nil) -> Any {
        // swiftlint:disable force_cast
        let copy = super.copy(with: zone) as! ChatFlowLayoutAttributes
        copy.avatarSize = avatarSize
        copy.avatarPosition = avatarPosition
        copy.avatarLeadingTrailingPadding = avatarLeadingTrailingPadding
        copy.messageContainerSize = messageContainerSize
        copy.messageContainerPadding = messageContainerPadding
        copy.messageLabelFrame = messageLabelFrame
        copy.messageLabelFont = messageLabelFont
        copy.messageLabelTextInsets = messageLabelTextInsets
        copy.titleLabelFrame = titleLabelFrame
        copy.titleLabelFont = titleLabelFont
        copy.titleLabelTextInsets = titleLabelTextInsets
        copy.dateLabelFrame = dateLabelFrame
        copy.dateLabelTextInsets = dateLabelTextInsets
        copy.dateLabelInsets = dateLabelInsets
        copy.dateLabelFont = dateLabelFont
        copy.mapFrame = mapFrame
        copy.pageControlFrame = pageControlFrame
        copy.buttonsFrame = buttonsFrame
        copy.buttonInsets = buttonInsets
        copy.mediaFrame = mediaFrame
        copy.carouselCardFrames = carouselCardFrames
        copy.statusViewSize = statusViewSize
        copy.carouselContentViewFrame = carouselContentViewFrame
        copy.carouselCardViewFrame = carouselCardViewFrame
        copy.carouselChoiceButtonsViewFrame = carouselChoiceButtonsViewFrame
        copy.backgroundFrame = backgroundFrame

        return copy
        // swiftlint:enable force_cast
    }
    
    override func isEqual(_ object: Any?) -> Bool {
        // MARK: - LEAVE this as is
        if let attributes = object as? ChatFlowLayoutAttributes {
            return super.isEqual(object) && attributes.avatarSize == avatarSize
            && attributes.avatarLeadingTrailingPadding == avatarLeadingTrailingPadding
            && attributes.messageContainerSize == messageContainerSize
            && attributes.messageContainerPadding == messageContainerPadding
            && attributes.messageLabelFrame == messageLabelFrame
            && attributes.messageLabelFont == messageLabelFont
            && attributes.messageLabelTextInsets == messageLabelTextInsets
            && attributes.dateLabelFrame == dateLabelFrame
            && attributes.dateLabelInsets == dateLabelInsets
            && attributes.dateLabelTextInsets == dateLabelTextInsets
            && attributes.dateLabelFont == dateLabelFont
            && attributes.mapFrame == mapFrame
            && attributes.buttonsFrame == buttonsFrame
            && attributes.buttonInsets == buttonInsets
            && attributes.mediaFrame == mediaFrame
            && attributes.titleLabelFrame == titleLabelFrame
            && attributes.titleLabelFont == titleLabelFont
            && attributes.titleLabelTextInsets == titleLabelTextInsets
            && attributes.carouselCardFrames == carouselCardFrames
            && attributes.pageControlFrame == pageControlFrame
            && attributes.statusViewSize == statusViewSize
            && attributes.carouselContentViewFrame == carouselContentViewFrame
            && attributes.carouselCardViewFrame == carouselCardViewFrame
            && attributes.carouselChoiceButtonsViewFrame == carouselChoiceButtonsViewFrame
            && attributes.backgroundFrame == backgroundFrame

        } else {
            return false
        }
    }
}
