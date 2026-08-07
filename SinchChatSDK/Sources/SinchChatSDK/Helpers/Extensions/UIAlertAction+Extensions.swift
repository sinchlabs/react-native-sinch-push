import UIKit

extension UIAlertAction {
    func setupActionWithImage(_ image: UIImage?, textColor: UIColor?) {
        self.setValue(image?.withRenderingMode(.alwaysOriginal), forKey: "image")
        self.setValue(CATextLayerAlignmentMode.left, forKey: "titleTextAlignment")
        self.setValue(textColor, forKey:"titleTextColor")
    }
}
