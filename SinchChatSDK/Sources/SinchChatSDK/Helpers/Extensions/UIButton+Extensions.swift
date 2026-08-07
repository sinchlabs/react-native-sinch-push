import UIKit

extension UIButton {
    func setInsets(
        forContentPadding contentPadding: UIEdgeInsets,
        imageTitlePadding: CGFloat
    ) {
        if UIView.userInterfaceLayoutDirection(
            for: semanticContentAttribute) == .rightToLeft {
            
            setupInsetsForRightToLeftLanguages(forContentPadding: contentPadding, imageTitlePadding: imageTitlePadding)
            
        } else {
            if UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft {
                
                setupInsetsForRightToLeftLanguages(forContentPadding: contentPadding, imageTitlePadding: imageTitlePadding)
                
            } else {
                
                setupInsetsForLeftToRightLanguages(forContentPadding: contentPadding, imageTitlePadding: imageTitlePadding)
            }
        }
    }
    
    func setupInsetsForRightToLeftLanguages(forContentPadding contentPadding: UIEdgeInsets,
                                            imageTitlePadding: CGFloat) {
        
        self.contentEdgeInsets = UIEdgeInsets(
            top: contentPadding.top,
            left: contentPadding.left + imageTitlePadding,
            bottom: contentPadding.bottom,
            right: contentPadding.left
        )
        self.titleEdgeInsets = UIEdgeInsets(
            top: 0,
            left: -imageTitlePadding,
            bottom: 0,
            right: imageTitlePadding
        )
        
    }
    func setupInsetsForLeftToRightLanguages(forContentPadding contentPadding: UIEdgeInsets,
                                            imageTitlePadding: CGFloat) {
        
        self.contentEdgeInsets = UIEdgeInsets(
            top: contentPadding.top,
            left: contentPadding.left,
            bottom: contentPadding.bottom,
            right: contentPadding.right + imageTitlePadding
        )
        self.titleEdgeInsets = UIEdgeInsets(
            top: 0,
            left: imageTitlePadding,
            bottom: 0,
            right: -imageTitlePadding
        )
    }
}
