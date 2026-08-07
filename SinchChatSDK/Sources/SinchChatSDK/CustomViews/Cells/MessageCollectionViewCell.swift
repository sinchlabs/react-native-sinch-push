import UIKit

class MessageCollectionViewCell: UICollectionViewCell {

    // MARK: - Initializers

    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    /// Handle tap gesture on contentView and its subviews.
    func handleTapGesture(_ gesture: UIGestureRecognizer) {
        // Should be overridden
    }

}
