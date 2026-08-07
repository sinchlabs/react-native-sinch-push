import Foundation
import UIKit

open class ComposeTextView: UITextView {
    
    private var canBecomeFirstResponderStorage: Bool = true
    open override var canBecomeFirstResponder: Bool {
        get { canBecomeFirstResponderStorage }
        set(newValue) { canBecomeFirstResponderStorage = newValue }
    }
    
    open override var scrollIndicatorInsets: UIEdgeInsets {
        didSet {
            // When .zero a rendering issue can occur
            if scrollIndicatorInsets == .zero {
                scrollIndicatorInsets = UIEdgeInsets(top: .leastNonzeroMagnitude,
                                                     left: .leastNonzeroMagnitude,
                                                     bottom: .leastNonzeroMagnitude,
                                                     right: .leastNonzeroMagnitude)
            }
        }
    }
     
    // MARK: - Initializers
    
    public init(configuration: SinchSDKConfig.UIConfig) {
                
        self.init(frame: .zero)
        
        backgroundColor = configuration.inputTextViewBackgroundColor
        textColor = configuration.inputTextColor
        font = UIFont.preferredFont(forTextStyle: .body)
    }
    
    public override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setup()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }
    
    // MARK: - Setup
    
    /// Sets up the default properties
    open func setup() {
        
        backgroundColor = .clear
        isScrollEnabled = false
        textContainerInset = UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)

        scrollIndicatorInsets = UIEdgeInsets(top: .leastNonzeroMagnitude,
                                             left: .leastNonzeroMagnitude,
                                             bottom: .leastNonzeroMagnitude,
                                             right: .leastNonzeroMagnitude)
    }
    
    // MARK: - Image Paste Support
    
    open override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {

        if action == NSSelectorFromString("paste:") {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
