import UIKit

@MainActor
class ChatCellSizeCalculator {

    public weak var layout: UICollectionViewFlowLayout?
    
    open func configure(attributes: UICollectionViewLayoutAttributes) {}
    
    open func sizeForItem(at indexPath: IndexPath) -> CGSize { return .zero }
    
    public init() {}

}
