import UIKit

final class TypingIndicatorCell: MessageCollectionViewCell {
    
    // MARK: - Subviews
    static let cellId = "typingIndicatorCell"

    public var insets = UIEdgeInsets(top: 15, left: 0, bottom: 0, right: 0)
    
    public let typingView = TypingView()
    
    // MARK: - Initialization
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupSubviews()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupSubviews()
    }
    
    public func setupSubviews() {
        addSubview(typingView)
    }
    
    public override func prepareForReuse() {
        super.prepareForReuse()
        if typingView.isAnimating {
            typingView.stopAnimating()
        }
    }
    
    // MARK: - Layout
    
    public override func layoutSubviews() {
        super.layoutSubviews()
        typingView.frame = bounds.inset(by: insets)
    }
    func configure(with messagesCollectionView: MessageCollectionView) {
        typingView.contentView.backgroundColor = messagesCollectionView.uiConfig.incomingMessageBackgroundColor
    }
}
