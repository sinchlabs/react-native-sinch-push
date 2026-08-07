import UIKit
import Foundation

@MainActor
protocol CardProtocol: AnyObject {
    func didTapOnChoice(_ text: ChoiceMessageType)
    func didTapOnMedia(_ url: URL)

}
class CardView: SinchView {
    
    lazy var titleLabel: MessageLabel = {
        var textLabel = MessageLabel()
        textLabel.backgroundColor = .clear
        textLabel.textColor = .black
        textLabel.numberOfLines = 0
      
        return textLabel
    }()
    
    lazy var textLabel: MessageLabel = {
        var textLabel = MessageLabel()
        textLabel.backgroundColor = .clear
        textLabel.textColor = .black
        textLabel.numberOfLines = 0
        return textLabel
    }()
    
    /// The image view display the media content.
    lazy var imageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = .clear
        imageView.clipsToBounds = true
        return imageView
    }()
    lazy var backgroundImageView: UIView = {
        let view = UIView()
        view.backgroundColor = uiConfig.inAppMessageImageBackgroundColor
        return view
    }()
    lazy var placeholderImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.backgroundColor = .clear
        imageView.image = uiConfig.inAppMessageImagePlaceholder

        imageView.clipsToBounds = true
        return imageView
    }()
    
    lazy var buttonsStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.distribution = .fillEqually
        stackView.alignment = .fill
        stackView.axis = .vertical
        stackView.spacing = 10
    
        return stackView
    }()
    
    var backgroundView: UIView = {
        let backgroundView = UIView()
        backgroundView.backgroundColor = .white
        backgroundView.layer.cornerRadius = 10
        backgroundView.isUserInteractionEnabled = true
        backgroundView.clipsToBounds = true
        return backgroundView
    }()
    
    var message: MessageCard
    var buttons: [TitleButton] = []
    var attributes: ChatFlowLayoutAttributes
    var cardIndex: Int
    weak var delegate: CardProtocol?

    init(uiConfiguration: SinchSDKConfig.UIConfig,
         localizationConfiguration: SinchSDKConfig.LocalizationConfig,
         message: MessageCard, attributes: ChatFlowLayoutAttributes, index: Int) {
        self.message = message
        self.cardIndex = index
        self.attributes = attributes
        
        super.init(uiConfiguration: uiConfiguration, localizationConfiguration: localizationConfiguration)
        self.frame = attributes.carouselCardFrames[index].frame

    }
    
    override func setupSubviews() {
        
        titleLabel.textInsets = attributes.titleLabelTextInsets
        titleLabel.textColor = uiConfig.incomingMessageTextColor
        titleLabel.messageLabelFont = attributes.titleLabelFont
        titleLabel.font = attributes.titleLabelFont
        titleLabel.text = message.title
        titleLabel.frame = attributes.carouselCardFrames[cardIndex].titleFrame
        addSubview(titleLabel)
        
        textLabel.textInsets = attributes.messageLabelTextInsets
        textLabel.textColor = uiConfig.incomingMessageTextColor
        textLabel.messageLabelFont = attributes.messageLabelFont
        textLabel.font = attributes.messageLabelFont
        textLabel.text = message.getReadMore(maxCount: uiConfig.numberOfCharactersBeforeCollapseTextMessage,
                                             textToAdd: localizationConfiguration.collapsedTextMessageButtonTitle)
      
        textLabel.frame = attributes.carouselCardFrames[cardIndex].messageFrame
        var enabledDetectors: [Detector] = [.url]

        if !message.isExpanded {
            
            let patternText = localizationConfiguration.collapsedTextMessageButtonTitle
            
            let pattern = patternText + "$"
            let regex = try? NSRegularExpression(pattern: pattern, options: [])
            
            if let regex = regex {
                enabledDetectors.append(.custom(regex))
            }
        }
        textLabel.configure {
            textLabel.enabledDetectors = enabledDetectors
            for detector in enabledDetectors {
                
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key.foregroundColor: uiConfig.messageUrlLinkTextColor,
                    NSAttributedString.Key.underlineStyle: NSUnderlineStyle.single.rawValue,
                    NSAttributedString.Key.underlineColor: uiConfig.messageUrlLinkTextColor
                ]
                textLabel.setAttributes(attributes, detector: detector)
            }
            
            textLabel.text = message.getReadMore(maxCount: uiConfig.numberOfCharactersBeforeCollapseTextMessage,
                                                 textToAdd: localizationConfiguration.collapsedTextMessageButtonTitle)
        }
        addSubview(textLabel)

        imageView.frame = attributes.carouselCardFrames[cardIndex].mediaFrame
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(imageTapped(tapGestureRecognizer:)))
        imageView.isUserInteractionEnabled = true
        imageView.addGestureRecognizer(tapGestureRecognizer)
        
        addSubview(imageView)
        setImageFromURL(message.url)

       buttons = setupButtons(choices: message.choices)
        
    }
    func updateViewWithAttributes(_ attributes: ChatFlowLayoutAttributes) {
        self.frame = attributes.carouselCardFrames[cardIndex].frame
        imageView.frame = attributes.carouselCardFrames[cardIndex].mediaFrame
        titleLabel.frame = attributes.carouselCardFrames[cardIndex].titleFrame
        textLabel.frame = attributes.carouselCardFrames[cardIndex].messageFrame

        for (index, button) in buttons.enumerated() {
            button.frame = attributes.carouselCardFrames[cardIndex].buttonFrames[index]
        }
    }
    @objc func imageTapped(tapGestureRecognizer: UITapGestureRecognizer) {
        if let url = URL(string: message.url) {
            delegate?.didTapOnMedia(url)
        }
    }
    private func setupButtons(choices: [ChoiceMessageType]) -> [TitleButton] {
        var buttonsArray: [TitleButton] = []
        for index in 0..<choices.count {
            
            let button = TitleButton(frame: attributes.carouselCardFrames[cardIndex].buttonFrames[index], with: uiConfig)
            button.titleLabel?.font = uiConfig.inAppMessageButtonTitleFont
            button.setTitleColor( uiConfig.inAppMessageButtonTitleColor, for: .normal)
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
                button.setImage(uiConfig.locationMessageImage, for:  .normal)
                button.setInsets(forContentPadding: UIEdgeInsets(top: 0.0, left: 4.0, bottom: 0.0, right: 4.0),
                                 imageTitlePadding: 10)

            }
            button.tag = index
            button.addTarget(self, action: #selector(choiceButtonTapped(_ :)), for: .touchUpInside)
            buttonsArray.append(button)
            addSubview(button)
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
                    self.imageView.image = UIImage(named: "photoPlaceholderOutgoing",
                                                   in: Bundle.staticBundle, compatibleWith: nil)!
                }
            }
        } else {
            self.imageView.image = UIImage(named: "photoPlaceholderOutgoing",
                                           in: Bundle.staticBundle, compatibleWith: nil)!
        }
    }
        
    @objc func choiceButtonTapped(_ sender: AnyObject) {
        if let button = sender as? TitleButton {
            button.changeButtonAppearanceInChat()

            let tag = button.tag
            delegate?.didTapOnChoice(message.choices[tag])
          
        }
    }
}
