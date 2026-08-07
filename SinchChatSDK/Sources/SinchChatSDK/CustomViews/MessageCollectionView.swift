import UIKit

final class MessageCollectionView: UICollectionView {
   
    weak var chatDataSource: ChatDataSource?
    var uiConfig: SinchSDKConfig.UIConfig!
    var localizationConfig: SinchSDKConfig.LocalizationConfig!

    weak var touchDelegate: MessageCellDelegate?
    public var isTypingIndicatorHidden: Bool {
        return chatCollectionViewFlowLayout.isTypingIndicatorViewHidden
    }
    
    private var indexPathForLastItem: IndexPath? {
        let lastSection = numberOfSections - 1
        guard lastSection >= 0, numberOfItems(inSection: lastSection) > 0 else { return nil }
        return IndexPath(item: numberOfItems(inSection: lastSection) - 1, section: lastSection)
    }

    public override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)

    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(frame: .zero, collectionViewLayout: ChatFlowLayout())
    }

    convenience init(uiConfiguration: SinchSDKConfig.UIConfig, localizationConfig: SinchSDKConfig.LocalizationConfig) {
        
        self.init(frame:  .zero, collectionViewLayout: ChatFlowLayout())
        setupGestureRecognizers()
        self.uiConfig = uiConfiguration
        self.localizationConfig = localizationConfig

        backgroundColor = uiConfig.backgroundColor
    }
   
    private func setupGestureRecognizers() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapGesture(_:)))
        tapGesture.delaysTouchesBegan = true
        addGestureRecognizer(tapGesture)
    }
    
    @objc func handleTapGesture(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .ended else { return }
        
        let touchLocation = gesture.location(in: self)
        guard let indexPath = indexPathForItem(at: touchLocation) else {
               touchDelegate?.didTapOutsideOfContent()
            return
        
        }
        
        let cell = cellForItem(at: indexPath) as? MessageCollectionViewCell 
        cell?.handleTapGesture(gesture)

    }
    func scrollToLastItem(at pos: UICollectionView.ScrollPosition = .bottom, animated: Bool = true) {
        guard numberOfSections > 0 else { return }
        
        let lastSection = numberOfSections - 1
        
        let indexPath = IndexPath(row: 0, section: lastSection)
        scrollToItem(at: indexPath, at: pos, animated: animated)
    }
    public var chatCollectionViewFlowLayout: ChatFlowLayout {
        guard let layout = collectionViewLayout as? ChatFlowLayout else {
            fatalError()
        }
        return layout
    }
    func reloadDataAndKeepOffset() {
        // stop scrolling
        setContentOffset(contentOffset, animated: false)
        
        // calculate the offset and reloadData
        let beforeContentSize = contentSize
        reloadData()
        layoutIfNeeded()
        let afterContentSize = contentSize
        
        // reset the contentOffset after data is updated
        let newOffset = CGPoint(
            x: contentOffset.x + (afterContentSize.width - beforeContentSize.width),
            y: contentOffset.y + (afterContentSize.height - beforeContentSize.height))
        setContentOffset(newOffset, animated: false)
    }
    
    // MARK: - Typing Indicator API

    /// Notifies the layout that the typing indicator will change state
    ///
    /// - Parameters:
    ///   - isHidden: A Boolean value that is to be the new state of the typing indicator
    internal func setTypingIndicatorViewHidden(_ isHidden: Bool) {
        chatCollectionViewFlowLayout.isTypingIndicatorViewHidden = isHidden
    }

    /// A method that by default checks if the section is the last in the
    /// `messagesCollectionView` and that `isTypingIndicatorViewHidden`
    /// is FALSE
    ///
    /// - Parameter section
    /// - Returns: A Boolean indicating if the TypingIndicator should be presented at the given section
    public func isSectionReservedForTypingIndicator(_ section: Int) -> Bool {
        return !chatCollectionViewFlowLayout.isTypingIndicatorViewHidden && section == numberOfSections - 1
    }
}
