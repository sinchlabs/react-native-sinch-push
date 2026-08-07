import UIKit

final class TransparentView: UIView {
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        prepareView()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        prepareView()
    }
    
    convenience public init() {
        self.init(frame: .zero)
        prepareView()
    }
    
    func prepareView() {
     
        backgroundColor = .black.withAlphaComponent(0.3)
    }
}
