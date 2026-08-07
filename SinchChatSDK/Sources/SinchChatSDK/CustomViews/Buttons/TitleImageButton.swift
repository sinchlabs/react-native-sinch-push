import UIKit

class TitleImageButton: UIButton {

    // MARK: - Initialization
    
    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor.white
        layer.cornerRadius = 10
        layer.masksToBounds = true
        setInsets(forContentPadding: UIEdgeInsets(top: 0.0, left: 4.0, bottom: 0.0, right: 4.0),
                  imageTitlePadding: 10)
    }
}
