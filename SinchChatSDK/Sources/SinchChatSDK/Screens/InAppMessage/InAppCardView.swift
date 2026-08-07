import UIKit
import Foundation

class InAppCardView: SinchView {
    
    lazy var titleLabel: MessageLabel = {
        var textLabel = MessageLabel()
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.backgroundColor = .clear
        textLabel.textColor = .black
        textLabel.numberOfLines = 0
        textLabel.font = uiConfig.inAppMessageTitleFont
      
        return textLabel
    }()
    
    lazy var textLabel: MessageLabel = {
        var textLabel = MessageLabel()
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.backgroundColor = .clear
        textLabel.font = uiConfig.inAppMessageTextFont
        textLabel.textColor = .black
        textLabel.numberOfLines = 0
        return textLabel
    }()
    
    /// The image view display the media content.
    lazy var imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.backgroundColor = .clear
        imageView.clipsToBounds = true
        return imageView
    }()
    lazy var backgroundImageView: UIView = {
        let view = UIView()
        view.backgroundColor = uiConfig.inAppMessageImageBackgroundColor
        view.translatesAutoresizingMaskIntoConstraints = false

        return view
    }()
    lazy var placeholderImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = .clear
        imageView.image = uiConfig.inAppMessageImagePlaceholder

        imageView.clipsToBounds = true
        return imageView
    }()
    
    lazy var buttonsStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.distribution = .fillEqually
        stackView.translatesAutoresizingMaskIntoConstraints = false

        stackView.alignment = .fill
        stackView.axis = .vertical
        stackView.spacing = 10
    
        return stackView
    }()
    
    lazy var backgroundView: UIView = {
        let backgroundView = UIView()
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.backgroundColor = uiConfig.inAppMessageBackgroundColor
        backgroundView.isUserInteractionEnabled = true
        backgroundView.clipsToBounds = true
        return backgroundView
    }()

    var message: MessageCard
    var buttons: [TitleButton] = []
    var cardIndex: Int
    weak var delegate: CardProtocol?
    var maxChoices: Int
    
    init(uiConfiguration: SinchSDKConfig.UIConfig,
         localizationConfiguration: SinchSDKConfig.LocalizationConfig,
         message: MessageCard, index: Int, maxChoices:Int) {
        
        self.message = message
        self.cardIndex = index
        self.maxChoices = maxChoices
        super.init(uiConfiguration: uiConfiguration, localizationConfiguration: localizationConfiguration)

    }

    override func setupSubviews() {

        titleLabel.textColor = uiConfig.inAppMessageTextColor
        titleLabel.text = message.title

        backgroundView.addSubview(titleLabel)
        
        textLabel.textColor = uiConfig.inAppMessageTextColor
        textLabel.text = message.description

        backgroundView.addSubview(textLabel)
        backgroundView.addSubview(backgroundImageView)

        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(imageTapped(tapGestureRecognizer:)))
        imageView.isUserInteractionEnabled = true
        imageView.addGestureRecognizer(tapGestureRecognizer)
        backgroundView.addSubview(placeholderImageView)

        backgroundView.addSubview(imageView)
        setImageFromURL(message.url)
        backgroundView.addSubview(buttonsStackView)

        buttons = setupButtons(choices: message.choices)
        addSubview(backgroundView)
    }
    
    override func setupConstraints() {
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        let backgroundTop = backgroundView.topAnchor.constraint(equalTo: topAnchor, constant: 0)
        let backgroundTrailing = backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0)
        let backgroundLeading = backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        let backgroundBottom = backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor)

        let backgroundImageViewTop = backgroundImageView.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 0)
        let backgroundImageViewTrailing = backgroundImageView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: 0)
        let backgroundImageViewLeading = backgroundImageView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 0)
        let backgroundImageViewHeight = backgroundImageView.heightAnchor.constraint(equalToConstant: 200)

        let imageViewTop = imageView.topAnchor.constraint(equalTo: backgroundImageView.topAnchor, constant: 0)
        let imageViewBottom = imageView.bottomAnchor.constraint(equalTo: backgroundImageView.bottomAnchor, constant: 0)
        let imageViewTrailing = imageView.trailingAnchor.constraint(equalTo: backgroundImageView.trailingAnchor, constant: 0)
        let imageViewLeading = imageView.leadingAnchor.constraint(equalTo: backgroundImageView.leadingAnchor, constant: 0)

        let placeholderImageCenterX = placeholderImageView.centerXAnchor.constraint(equalTo: backgroundImageView.centerXAnchor, constant: 0)
        let placeholderImageCenterY = placeholderImageView.centerYAnchor.constraint(equalTo: backgroundImageView.centerYAnchor, constant: 0)
        let placeholderImageViewWidth = placeholderImageView.widthAnchor.constraint(equalToConstant: 100)
        let placeholderImageViewHeight = placeholderImageView.heightAnchor.constraint(equalToConstant: 100)

        let titleLabelTop = titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 25)
        let titleLabelTrailing = titleLabel.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
        let titleLabelLeading = titleLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)

        let textLabelTop = textLabel.topAnchor.constraint(equalTo:  titleLabel.bottomAnchor, constant: 16)
        let textLabelTrailing = textLabel.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
        let textLabelLeading = textLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)

        buttonsStackView.translatesAutoresizingMaskIntoConstraints = false

        let stackTop = buttonsStackView.topAnchor.constraint(greaterThanOrEqualTo: textLabel.bottomAnchor, constant: 16)
        let stackTrailing = buttonsStackView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
        let stackLeading = buttonsStackView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)
        let stackBottom = buttonsStackView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -16)

        NSLayoutConstraint.activate([
            backgroundTop,
            backgroundTrailing,
            backgroundBottom,
            backgroundLeading,
            
            backgroundImageViewTop,
            backgroundImageViewTrailing,
            backgroundImageViewLeading,
            backgroundImageViewHeight,
            
            imageViewTop,
            imageViewTrailing,
            imageViewLeading,
            imageViewBottom,
            
            placeholderImageCenterX,
            placeholderImageCenterY,
            placeholderImageViewWidth,
            placeholderImageViewHeight,
            
            titleLabelTop,
            titleLabelTrailing,
            titleLabelLeading,
            
            textLabelTop,
            textLabelTrailing,
            textLabelLeading,

            stackTop,
            stackLeading,
            stackTrailing,
            stackBottom
        ])
        
    }

    @objc func imageTapped(tapGestureRecognizer: UITapGestureRecognizer) {
        if let url = URL(string: message.url) {
            delegate?.didTapOnMedia(url)
        }
    }
    private func setupButtons(choices: [ChoiceMessageType]) -> [TitleButton] {
        var buttonsArray: [TitleButton] = []
        for index in 0..<choices.count {
            
            let button = TitleButton(frame: .zero, with: uiConfig)

            button.titleLabel?.font = uiConfig.inAppMessageButtonTitleFont
            button.setTitleColor( uiConfig.inAppMessageButtonTitleColor, for: .normal)
            button.setTitleColor( uiConfig.inAppMessageTappedButtonTitleColor, for: .selected)
            button.backgroundColor = uiConfig.inAppMessageButtonBackgroundColor

            switch choices[index] {
            case .textMessage(let message):
                button.setTitle(message.text, for: .normal)
                
            case .urlMessage(let message):
                button.setTitle(message.text, for: .normal)
                
            case .callMessage(let message):
                button.setTitle(message.text, for: .normal)
                
            case .locationMessage(let message):
                button.setTitle(message.label, for: .normal)
                button.setImage(uiConfig.inAppMessageLocationMessageImage, for:  .normal)
                button.setInsets(forContentPadding: UIEdgeInsets(top: 0.0, left: 4.0, bottom: 0.0, right: 4.0),
                                 imageTitlePadding: 10)

            }
            button.tag = index
            button.addTarget(self, action: #selector(choiceButtonTapped(_ :)), for: .touchUpInside)
            buttonsArray.append(button)
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            buttonsStackView.addArrangedSubview(button)
        }
        let missingViewsCount = maxChoices - buttonsArray.count
            
        for _ in 0..<missingViewsCount {
            let view = UIView()
            view.backgroundColor = .clear
            view.heightAnchor.constraint(equalToConstant: 36).isActive = true
            buttonsStackView.addArrangedSubview(view)
        }
        
        return buttonsArray
    }
    private func setImageFromURL(_ urlString: String) {
        
        if let url = URL(string: urlString) {
            
            imageView.setImage(url:url) { [weak self] result in
                
                guard let self = self else { return }
                
                switch result {
                case .success(_):
                   break
                case .failure(_):
                    self.imageView.image = nil
                }
            }
        } else {
            self.imageView.image = nil
        }
    }
        
    @objc func choiceButtonTapped(_ sender: AnyObject) {
        if let button = sender as? TitleButton {
            button.changeButtonAppearanceInAppMessage()

            let tag = button.tag
            delegate?.didTapOnChoice(message.choices[tag])
          
        }
    }
}
