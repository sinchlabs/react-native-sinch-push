import UIKit

open class SinchView: UIView {
    
    public var uiConfig = SinchSDKConfig.UIConfig.defaultValue
    public var localizationConfiguration = SinchSDKConfig.LocalizationConfig.defaultValue
    
    public init() {
               
        super.init(frame: .zero)
        commonInit()
    }
    
    public init(uiConfiguration: SinchSDKConfig.UIConfig, localizationConfiguration: SinchSDKConfig.LocalizationConfig) {
        self.uiConfig = uiConfiguration
        self.localizationConfiguration = localizationConfiguration
        super.init(frame: .zero)
        commonInit()
    }
    
    @available(*, unavailable, message: "Use init")
    public required init?(coder: NSCoder) {
        fatalError()
    }

    public func commonInit() {
        setupProperties()
        setupSubviews()
        setupConstraints()
    }

    open func setupSubviews() {}
    open func setupConstraints() {}
    open func setupProperties() {}
}
