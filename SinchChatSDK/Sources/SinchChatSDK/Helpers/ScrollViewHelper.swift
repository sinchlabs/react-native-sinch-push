import Foundation
import UIKit

final class ScrollViewHelper {
    
    static func getTargetContentOffset(scrollView: UIScrollView, velocity: CGPoint, pageWidth: CGFloat) -> CGFloat {
        let targetX: CGFloat = scrollView.contentOffset.x + velocity.x * 60.0
        
        var targetIndex = (targetX + scrollView.contentInset.left) / pageWidth
        let maxOffsetX = scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right
        let maxIndex = (maxOffsetX + scrollView.contentInset.left) / pageWidth
        if velocity.x > 0 {
            targetIndex = ceil(targetIndex)
        } else if velocity.x < 0 {
            targetIndex = floor(targetIndex)
        } else {
            let (maxFloorIndex, lastInterval) = modf(maxIndex)
            if targetIndex > maxFloorIndex {
                if targetIndex >= lastInterval / 2 + maxFloorIndex {
                    targetIndex = maxIndex
                } else {
                    targetIndex = maxFloorIndex
                }
            } else {
                targetIndex = round(targetIndex)
            }
        }
        
        if targetIndex < 0 {
            targetIndex = 0
        }
        
        var offsetX = targetIndex * pageWidth - scrollView.contentInset.left
        offsetX = min(offsetX, maxOffsetX)
        
        return offsetX
    }
    static func getCurrentPage(scrollView: UIScrollView, pageWidth: CGFloat) -> CGFloat {
        return (scrollView.contentOffset.x + scrollView.contentInset.left) / pageWidth
    }
}
