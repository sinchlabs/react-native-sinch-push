import UIKit

class TypeIndicatorCellSizeCalculator: ChatCellSizeCalculator {

    init(layout: ChatFlowLayout? = nil) {
        super.init()
        self.layout = layout
    }

    open override func sizeForItem(at indexPath: IndexPath) -> CGSize {
        guard let layout = layout as? ChatFlowLayout else { return .zero }
        return layout.typingIndicatorViewSize()
    }
}
