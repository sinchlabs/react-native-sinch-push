import UIKit
@MainActor
protocol MessageStatusDelegate: AnyObject {
    func retryTapped()
    
}
final class MessageStatusView: SinchView {
    
    var messageStatus: MessageStatus = .notSent
    weak var delegate: MessageStatusDelegate?
    
    lazy var stackView: UIStackView = {
        let stackView = UIStackView()
        stackView.distribution = .fillProportionally
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.alignment = .fill
        stackView.axis = .horizontal
        stackView.spacing = 4
        
        return stackView
    }()
    var  retryStatusEmptyView: UIView = {
        let containerView = UIView()
        containerView.backgroundColor = .clear
        containerView.clipsToBounds = true
        containerView.layer.masksToBounds = true
        containerView.translatesAutoresizingMaskIntoConstraints = false

        return containerView
    }()
    lazy var retryStatusImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        return imageView
    }()
    lazy var statusImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false

        return imageView
    }()
    var statusEmptyView: UIView = {
        let containerView = UIView()
        containerView.backgroundColor = .clear
        containerView.clipsToBounds = true
        containerView.layer.masksToBounds = true
        containerView.translatesAutoresizingMaskIntoConstraints = false

        return containerView
    }()
    lazy var statusLabel: UILabel =  {
        var label = UILabel()
        label.textColor = uiConfig.outgoingMessageTextColor
        label.textAlignment = .right
        label.font = UIFont.preferredFont(forTextStyle: .caption2)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    override func setupSubviews() {
        
        let labelTap = UITapGestureRecognizer(target: self, action: #selector(self.retryAction(_:)))
        statusLabel.isUserInteractionEnabled = true
        statusLabel.addGestureRecognizer(labelTap)
        let imageTap = UITapGestureRecognizer(target: self, action: #selector(self.retryAction(_:)))
        retryStatusImageView.isUserInteractionEnabled = true
        retryStatusImageView.addGestureRecognizer(imageTap)
        statusEmptyView.addSubview(statusImageView)
        retryStatusEmptyView.addSubview(retryStatusImageView)

        stackView.addArrangedSubview(retryStatusEmptyView)
        stackView.addArrangedSubview(statusLabel)
        stackView.addArrangedSubview(statusEmptyView)
        
        addSubview(stackView)
        
    }
    @objc func retryAction(_ sender: AnyObject) {
        delegate?.retryTapped()
    }
    override func setupConstraints() {
        
        let stackViewLeft = stackView.leadingAnchor.constraint(equalTo: leadingAnchor)
        let stackViewRight = stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        let stackViewTop = stackView.topAnchor.constraint(equalTo: topAnchor)
        let stackViewBottom = stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        
        let statusEmptyViewWidth = statusEmptyView.widthAnchor.constraint(equalToConstant: 16.0)
        
        let statusImageHeight = statusImageView.heightAnchor.constraint(equalToConstant: 10.0)
        let statusImageWidth = statusImageView.widthAnchor.constraint(equalToConstant: 16.0)
        let statusImageCenterX = statusImageView.centerXAnchor.constraint(equalTo: statusEmptyView.centerXAnchor)
        let statusImageCenterY = statusImageView.centerYAnchor.constraint(equalTo: statusEmptyView.centerYAnchor)

        let retryStatusEmptyViewWidth = retryStatusEmptyView.widthAnchor.constraint(equalToConstant: 10.0)

        let retryStatusImageHeight = retryStatusImageView.heightAnchor.constraint(equalToConstant: 10.0)
        let retryStatusImageWidth = retryStatusImageView.widthAnchor.constraint(equalToConstant: 10.0)
        let retryStatusImageCenterX = retryStatusImageView.centerXAnchor.constraint(equalTo: retryStatusEmptyView.centerXAnchor)
        let retryStatusImageCenterY = retryStatusImageView.centerYAnchor.constraint(equalTo: retryStatusEmptyView.centerYAnchor)
        
        NSLayoutConstraint.activate([
            stackViewLeft,
            stackViewRight,
            statusEmptyViewWidth,
            statusImageCenterX,
            statusImageCenterY,
            stackViewTop,
            stackViewBottom,
            statusImageHeight,
            statusImageWidth,
            retryStatusEmptyViewWidth,
            retryStatusImageHeight,
            retryStatusImageWidth,
            retryStatusImageCenterX,
            retryStatusImageCenterY
        ])
    }
    
    func setupStatusView(_ status: MessageStatus, in messagesCollectionView: MessageCollectionView) {
        
        statusLabel.text = status.localizedDescription(localizedConfig: messagesCollectionView.localizationConfig)
        statusImageView.image = status.localizedImage(uiConfig: messagesCollectionView.uiConfig)
        retryStatusImageView.image = messagesCollectionView.uiConfig.refreshStatusImage
        switch status {
            
        case .notSent:
            statusEmptyView.isHidden = true
            retryStatusEmptyView.isHidden = false
        case .sending:
            statusEmptyView.isHidden = true
            retryStatusEmptyView.isHidden = true
        case .delivered, .sent, .seen:
            statusEmptyView.isHidden = false
            retryStatusEmptyView.isHidden = true
        
        }
    }
}
