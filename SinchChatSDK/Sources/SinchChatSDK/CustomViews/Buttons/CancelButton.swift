import UIKit

class CancelButton: UIButton {

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
        setupBorderedStyle(textColor: .black, borderColor: .black)
        
    }
    func setupBorderedStyle(textColor: UIColor, borderColor: UIColor) {
        
        backgroundColor = .clear
        layer.cornerRadius = 10
        layer.borderColor = borderColor.cgColor
        setTitleColor(textColor, for: .normal)
        layer.borderWidth = 1.0
        layer.masksToBounds = true
        titleEdgeInsets = UIEdgeInsets(top: 0.0, left: 8.0, bottom: 0.0, right: 8.0)

    }
    
    func setupPlainStyle(backgroundColor: UIColor, textColor: UIColor) {
        self.backgroundColor = backgroundColor
        layer.cornerRadius = 10
        setTitleColor(textColor, for: .normal)
        layer.borderWidth = 0.0
        layer.masksToBounds = true
        titleEdgeInsets = UIEdgeInsets(top: 0.0, left: 8.0, bottom: 0.0, right: 8.0)    }
}
