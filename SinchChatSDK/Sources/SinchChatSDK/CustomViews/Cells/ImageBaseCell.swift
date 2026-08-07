import UIKit

class ImageBaseCell: MessageContentCell {
        
    /// The image view display the media content.
    var imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = .clear
        imageView.clipsToBounds = true
        return imageView
    }()
    var placeholderLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.boldSystemFont(ofSize: 10)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        
        return label
    }()
    var placeholderImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
        return imageView
    }()
    var errorImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        
        return imageView
    }()
    
    var activityIndicator: UIActivityIndicatorView = {
        let activityIndicatorView: UIActivityIndicatorView
        
        if #available(iOS 13.0, *) {
            activityIndicatorView = UIActivityIndicatorView(style: .medium)
        } else {
            activityIndicatorView = UIActivityIndicatorView(style: .gray)
        }
        activityIndicatorView.hidesWhenStopped = true
        activityIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        
        return activityIndicatorView
    }()
    var dateLabel = MessageLabel()
    var error: Bool?
    
    // MARK: - Methods
    
    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        dateLabel.text = nil
        placeholderLabel.text = ""
        errorImageView.image = nil
        activityIndicator.stopAnimating()
        error = false
    }
        
    func showErrorViewForImageDownload(localizationConfig: SinchSDKConfig.LocalizationConfig) {
        placeholderLabel.text = localizationConfig.downloadFailed
        errorImageView.image = UIImage(named: "errorIcon",
                                       in: Bundle.staticBundle, compatibleWith: nil)!
        error = true
    }
    
    private func handleMediaUrl(_ url: String, localizationConfig: SinchSDKConfig.LocalizationConfig) {
        if let url = URL(string: url) {
            activityIndicator.startAnimating()
            placeholderLabel.text = localizationConfig.tryingToDownload
            errorImageView.image = nil
            
            imageView.setImage(url: url) { [weak self] result in
                guard let self = self else {
                    return
                }
                self.activityIndicator.stopAnimating()
                
                switch result {
                    
                case .success(_):
                    self.placeholderLabel.text = ""
                    self.placeholderImageView.image = nil
                    self.errorImageView.image = nil
                    self.error = false
                case .failure(_):
                    self.showErrorViewForImageDownload(localizationConfig: localizationConfig)
                }
            }
        } else {
            showErrorViewForImageDownload(localizationConfig: localizationConfig)
        }
    }
    func setupDateLabel(_ messagesCollectionView: MessageCollectionView) {
        dateLabel.textColor = .white
        dateLabel.layer.cornerRadius = 10.0
        dateLabel.layer.masksToBounds = true
        dateLabel.backgroundColor = messagesCollectionView.uiConfig.dateLabelMediaBackgroundColor
    }
    
    func setupImageView(message: Message, localizationConfig: SinchSDKConfig.LocalizationConfig) {
        
        if let body = message.body as? MessageMedia {
            handleMediaUrl(body.url, localizationConfig: localizationConfig)
            
        } else if let body = message.body as? MessageMediaText {
            handleMediaUrl(body.url, localizationConfig: localizationConfig)

        } else if let body = message.body as? MessageCard {
            handleMediaUrl(body.url, localizationConfig: localizationConfig)

        }

    }
    func setupPlaceholderView(_ messagesCollectionView: MessageCollectionView, _ message: Message) {
        
        placeholderLabel.textColor = messagesCollectionView.uiConfig.incomingMessageTextColor
        if message.isFromCurrentUser() {
            placeholderImageView.image = UIImage(named: "photoPlaceholderIncoming",
                                                 in: Bundle.staticBundle, compatibleWith: nil)!
            
        } else {
            placeholderImageView.image = UIImage(named: "photoPlaceholderOutgoing",
                                                 in: Bundle.staticBundle, compatibleWith: nil)!
        }
    }
}
