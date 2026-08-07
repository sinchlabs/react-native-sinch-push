import UIKit

class TypingView: SinchView {
    
    // MARK: - Properties
        
    public private(set) var isAnimating: Bool = false
    
    open override var backgroundColor: UIColor? {
        get {
            return contentView.backgroundColor
            }
        set {
            [contentView].forEach { $0.backgroundColor = newValue }
            }
    }
    
    private struct AnimationKeys {
        static let pulse = "typingBubble.pulse"
    }
    
    // MARK: - Subviews
    
    /// The indicator used to display the typing animation.
    public let typingIndicator = TypingIndicatorView()
    
    public let contentView = UIView()
        
    // MARK: - Animation Layers
    
    open var contentPulseAnimationLayer: CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1
        animation.toValue = 1.04
        animation.duration = 1
        animation.repeatCount = .infinity
        animation.autoreverses = true
        return animation
    }
    
    open var circlePulseAnimationLayer: CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1
        animation.toValue = 1.1
        animation.duration = 0.5
        animation.repeatCount = .infinity
        animation.autoreverses = true
        return animation
    }
    
    override func setupSubviews() {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        typingIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        contentView.addSubview(typingIndicator)
        backgroundColor = .clear
        contentView.layer.cornerRadius = 12
        contentView.layer.masksToBounds = true
        contentView.backgroundColor = .lightGray
    }
   
    override func setupConstraints() {
    
        let contentViewHeight = contentView.heightAnchor.constraint(equalToConstant: 24)
        let contentViewWidth = contentView.widthAnchor.constraint(equalToConstant: 60)
        let contentViewLeft = contentView.leftAnchor.constraint(equalTo: leftAnchor, constant: 65)
        
        let typingIndicatorLeading = typingIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8)
        let typingIndicatorTrailing = typingIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8)
        let typingIndicatorTop = typingIndicator.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8)
        let typingIndicatorBottom = typingIndicator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        
        NSLayoutConstraint.activate([contentViewHeight,
                                     contentViewWidth,
                                     contentViewLeft,
                                     typingIndicatorLeading,
                                     typingIndicatorTrailing,
                                     typingIndicatorTop,
                                     typingIndicatorBottom])

    }
    
    // MARK: - Animation API
    
    open func startAnimating() {
        defer { isAnimating = true }
        guard !isAnimating else { return }
        typingIndicator.startAnimating()
        
    }
    
    open func stopAnimating() {
        defer { isAnimating = false }
        guard isAnimating else { return }
        typingIndicator.stopAnimating()
    }
    
}
