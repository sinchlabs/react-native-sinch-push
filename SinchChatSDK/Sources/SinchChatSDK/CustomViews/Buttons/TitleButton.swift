import UIKit

class TitleButton: UIButton {
    
    var uiConfig: SinchSDKConfig.UIConfig
    var buttonColorChangeInSec: Double = 0.5
    // MARK: - Initialization
    
    convenience init(frame: CGRect = .zero, with uiConfig: SinchSDKConfig.UIConfig) {
        self.init(frame: frame, uiConfig: uiConfig)
    }
    
    required init(frame:CGRect, uiConfig: SinchSDKConfig.UIConfig) {
        self.uiConfig = uiConfig
        
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder aDecoder: NSCoder) {
        uiConfig = SinchSDKConfig.UIConfig.defaultValue

        super.init(coder: aDecoder)
        setup()
    }
    
    private func setup() {
        backgroundColor = UIColor.white
        layer.cornerRadius = 10
        layer.masksToBounds = true
        titleEdgeInsets = UIEdgeInsets(top: 0.0, left: 8.0, bottom: 0.0, right: 8.0)
    }
    
    func changeButtonAppearanceInChat() {
        
            backgroundColor =  uiConfig.tappedButtonBackgroundColor
            self.isSelected = true
        DispatchQueue.main.asyncAfter(deadline: .now() + buttonColorChangeInSec ) {

            self.backgroundColor = self.uiConfig.buttonBackgroundColor
            self.isSelected = false

        }
    }
    func changeButtonAppearanceInAppMessage() {
        
            backgroundColor =  uiConfig.inAppMessageButtonTappedBackgroundColor
            self.isSelected = true
        DispatchQueue.main.asyncAfter(deadline: .now() + buttonColorChangeInSec ) {

            self.backgroundColor = self.uiConfig.inAppMessageButtonBackgroundColor
            self.isSelected = false

        }
    }
  
}
