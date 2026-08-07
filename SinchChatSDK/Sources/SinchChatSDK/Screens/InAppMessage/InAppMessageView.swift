import Foundation
import UIKit
import MapKit

// swiftlint:disable type_body_length
// swiftlint:disable file_length

class InAppMessageView: SinchView, UIScrollViewDelegate {
    
    var scrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isScrollEnabled = true
        scrollView.bounces = false
        return scrollView
    }()
    lazy var horizontalScrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.isPagingEnabled = true
        scrollView.backgroundColor = .clear
        scrollView.decelerationRate = .fast
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        return scrollView
    }()
    var horizontalContentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }()
    lazy var cardsStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.distribution = .fill
        stackView.alignment = .fill
        stackView.axis = .horizontal
        stackView.spacing = 0
        
        return stackView
    }()
    var contentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }()
    
    var closeButton: UIButton = {
        let closeButton = UIButton(type: .custom)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        return closeButton
    }()
    var cancelButton: CancelButton = {
        let cancelButton = CancelButton()
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        return cancelButton
    }()
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
        imageView.isUserInteractionEnabled = true
        
        return imageView
    }()
    lazy var backgroundImageView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = uiConfig.inAppMessageImageBackgroundColor
        return view
    }()
    lazy var placeholderImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.backgroundColor = .clear
        imageView.image = uiConfig.inAppMessageImagePlaceholder
        
        imageView.clipsToBounds = true
        return imageView
    }()
    
    lazy var buttonsStackView: UIStackView = {
        let stackView = UIStackView()
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.distribution = .fillEqually
        stackView.alignment = .fill
        stackView.axis = .vertical
        stackView.spacing = 16
        
        return stackView
    }()
    
    lazy var mapView: MKMapView = {
        let mapView = MKMapView()
        mapView.translatesAutoresizingMaskIntoConstraints = false
        
        return mapView
    }()
    
    lazy var locationButton: TitleImageButton = {
        var locationButton = TitleImageButton()
        locationButton.translatesAutoresizingMaskIntoConstraints = false
        
        return locationButton
    }()
    
    var backgroundView: UIView = {
        let backgroundView = UIView()
        backgroundView.backgroundColor = .white
        backgroundView.layer.cornerRadius = 10
        backgroundView.isUserInteractionEnabled = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.clipsToBounds = true
        return backgroundView
    }()
    var lineView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }()
    
    var pageControl = UIPageControl()
    var pageWidth: CGFloat = 240.0
    
    var message: Message
    var buttons: [TitleButton] = []
    weak var delegate: InAppMessageViewControllerDelegate?
    var cards: [UIView] = []
    var cardConstrains: [NSLayoutConstraint] = []
    
    private var compactConstraints: [NSLayoutConstraint] = []
    private var regularConstraints: [NSLayoutConstraint] = []
    
    init(uiConfiguration: SinchSDKConfig.UIConfig,
         localizationConfiguration: SinchSDKConfig.LocalizationConfig,
         message: Message) {
        self.message = message
        
        super.init(uiConfiguration: uiConfiguration, localizationConfiguration: localizationConfiguration)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutIfNeeded()
        pageWidth = backgroundView.frame.width
        
        if horizontalScrollView.contentSize.width != 0 {
            
            horizontalScrollView.setContentOffset(CGPoint(x: CGFloat(pageControl.currentPage) * pageWidth, y: 0.0), animated: false)
        }
    }
    
    override func setupSubviews() {
        addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(backgroundView)
        
        backgroundColor = .clear
        contentView.backgroundColor = .black.withAlphaComponent(0.7)
        backgroundView.backgroundColor = uiConfig.inAppMessageBackgroundColor
        closeButton.setImage( uiConfig.inAppMessageinAppCloseImage, for: .normal)
        closeButton.isHidden = true
        textLabel.textColor = uiConfig.inAppMessageTextColor
        titleLabel.textColor = uiConfig.inAppMessageTextColor
        
        cancelButton.titleLabel?.font = uiConfig.inAppMessageButtonTitleFont
        cancelButton.setupBorderedStyle(textColor: uiConfig.inAppMessageCancelButtonBackgroundColor, borderColor:  uiConfig.inAppMessageCancelButtonBackgroundColor)
        cancelButton.setTitle(localizationConfiguration.buttonTitleClose, for: .normal)

        textLabel.isHidden = true
        titleLabel.isHidden = true

        switch message.body {
            
        case let message as MessageText:
        
            textLabel.text = message.text
            textLabel.isHidden = false
            backgroundView.addSubview(textLabel)
            
        case let message as MessageMedia:
            backgroundView.addSubview(backgroundImageView)
            backgroundView.addSubview(placeholderImageView)
            backgroundView.addSubview(imageView)
        
            let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(imageTapped(tapGestureRecognizer:)))
            imageView.addGestureRecognizer(tapGestureRecognizer)
            setImageFromURL(message.url)
            closeButton.isHidden = false

        case let message as MessageLocation:
        
            locationButton.titleLabel?.font = uiConfig.inAppMessageButtonTitleFont
            locationButton.setTitleColor(uiConfig.inAppMessageButtonTitleColor, for: .normal)
            locationButton.setImage(uiConfig.inAppMessageLocationMessageImage, for:  .normal)
            locationButton.backgroundColor = uiConfig.inAppMessageButtonBackgroundColor
            
            backgroundView.addSubview(mapView)
            
            textLabel.text = message.title
            textLabel.isHidden = false
            backgroundView.addSubview(textLabel)

            locationButton.setTitle(message.label, for: .normal)
            locationButton.titleLabel?.font = uiConfig.buttonTitleFont
            locationButton.setTitleColor( uiConfig.buttonTitleColor, for: .normal)
            locationButton.backgroundColor = uiConfig.buttonBackgroundColor
            backgroundView.addSubview(locationButton)
            locationButton.addTarget(self, action: #selector(openMaps), for: .touchUpInside)
            setupMapView(message: self.message)
            
        case let message as MessageChoices:
        
            textLabel.text = message.text
            textLabel.isHidden = false
            backgroundView.addSubview(textLabel)

            self.buttons = setupButtons(choices: message.choices)
            backgroundView.addSubview(buttonsStackView)
            for button in buttons {
                buttonsStackView.addArrangedSubview(button)
            }

        case let message as MessageCard:
            backgroundView.addSubview(backgroundImageView)
            backgroundView.addSubview(placeholderImageView)
     
            titleLabel.textColor = uiConfig.inAppMessageTextColor
            titleLabel.isHidden = false
            titleLabel.text = message.title
            
            textLabel.text = message.description
            textLabel.isHidden = false

            setImageFromURL(message.url)
            
            backgroundView.addSubview(imageView)
            backgroundView.addSubview(titleLabel)
            backgroundView.addSubview(textLabel)
            self.buttons = setupButtons(choices: message.choices)
            backgroundView.addSubview(buttonsStackView)
            for button in buttons {
                buttonsStackView.addArrangedSubview(button)
            }
            closeButton.isHidden = false

        case let message as MessageCarousel:
            
            backgroundView.addSubview(horizontalScrollView)
            horizontalScrollView.addSubview(horizontalContentView)
            horizontalContentView.addSubview(cardsStackView)
            horizontalScrollView.delegate = self
            var maxChoices = 0
            for card in message.cards where maxChoices < card.choices.count {
              
                    maxChoices = card.choices.count
            }
            
            for index in 0..<message.cards.count {
                
                let cardView = InAppCardView(uiConfiguration: uiConfig,
                                             localizationConfiguration: localizationConfiguration,
                                             message: message.cards[index],
                                             index: index,
                                             maxChoices: maxChoices)
                
                cardView.translatesAutoresizingMaskIntoConstraints = false
                cardView.delegate = self
                cards.append(cardView)
                cardsStackView.addArrangedSubview(cardView)
                
            }
            backgroundView.addSubview(pageControl)
            
            setupPageControl()
            self.buttons = setupButtons(choices: message.choices)
            lineView.backgroundColor = uiConfig.inAppMessageCarouselSeparatorColor
            backgroundView.addSubview(lineView)
            backgroundView.addSubview(buttonsStackView)
            
            for button in buttons {
                buttonsStackView.addArrangedSubview(button)
            }
            closeButton.isHidden = false

        default:
            break
            
        }
        backgroundView.addSubview(cancelButton)
        backgroundView.addSubview(closeButton)
        
    }
    func setupMapView(message: Message) {
        
        if let body = message.body as? MessageLocation {
            let coordinateRegion = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: body.latitude, longitude: body.longitude),
                latitudinalMeters: 1000,
                longitudinalMeters: 1000)
            mapView.setRegion(coordinateRegion, animated: true)
            let annotations = MKPointAnnotation()
            annotations.coordinate = CLLocationCoordinate2D(latitude: body.latitude,
                                                            longitude: body.longitude)
            mapView.addAnnotation(annotations)
            
        }
    }
    
    func setupPageControl() {
        if let message = message.body as? MessageCarousel {
            
            pageControl.numberOfPages = message.cards.count
            pageControl.currentPage = 0
            pageControl.currentPageIndicatorTintColor = uiConfig.pageControlSelectedColor
            pageControl.pageIndicatorTintColor = uiConfig.pageControlUnselectedColor
            pageControl.isUserInteractionEnabled = false
            pageControl.hidesForSinglePage = true
            pageControl.translatesAutoresizingMaskIntoConstraints = false
        }
    }
    private func setupButtons(choices: [ChoiceMessageType]) -> [TitleButton] {
        var buttonsArray: [TitleButton] = []
        for index in 0..<choices.count {
            
            let button = TitleButton(with: uiConfig)
            button.titleLabel?.font = uiConfig.inAppMessageButtonTitleFont
            button.setTitleColor( uiConfig.inAppMessageButtonTitleColor, for: .normal)
            button.setTitleColor( uiConfig.inAppMessageTappedButtonTitleColor, for: .selected)
            
            button.backgroundColor = uiConfig.inAppMessageButtonBackgroundColor
            button.translatesAutoresizingMaskIntoConstraints = false
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
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            buttonsArray.append(button)
            
        }
        return buttonsArray
    }
    
    private func addSharedConstraints() {
        
        compactConstraints.append(contentsOf: [
            backgroundView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 25),
            backgroundView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -25),
            backgroundView.centerYAnchor.constraint(equalTo:  contentView.centerYAnchor),
            backgroundView.centerXAnchor.constraint(equalTo:  contentView.centerXAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -25),
            backgroundView.leadingAnchor.constraint(equalTo:  safeAreaLayoutGuide.leadingAnchor, constant: 25),
            backgroundView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)])
        
        regularConstraints.append(contentsOf: [
            backgroundView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 25),
            backgroundView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -25),
            backgroundView.centerYAnchor.constraint(equalTo:  contentView.centerYAnchor),
            backgroundView.centerXAnchor.constraint(equalTo:  contentView.centerXAnchor),
            backgroundView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            backgroundView.widthAnchor.constraint(equalToConstant: 460)
        ])
        
        let closeButtonTop = closeButton.topAnchor.constraint(equalTo:  backgroundView.topAnchor, constant: 13)
        let closeButtonTrailing = closeButton.trailingAnchor.constraint(equalTo:  backgroundView.trailingAnchor, constant: -13)
        let closeButtonHeight = closeButton.heightAnchor.constraint(equalToConstant: 40)
        let closeButtonWidth = closeButton.widthAnchor.constraint(equalToConstant: 40)
        layoutTrait(traitCollection: UIScreen.main.traitCollection)
        
        let constraint = contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.heightAnchor, constant: 0.0)
        constraint.priority = UILayoutPriority(250)
        
        let cancelButtonBottom = cancelButton.bottomAnchor.constraint(equalTo:  self.backgroundView.bottomAnchor, constant: -25)
        let cancelButtonTrailing = cancelButton.trailingAnchor.constraint(equalTo:  backgroundView.trailingAnchor, constant: -25)
        let cancelButtonLeading = cancelButton.leadingAnchor.constraint(equalTo:  backgroundView.leadingAnchor, constant: 25)
        let cancelButtonHeight = cancelButton.heightAnchor.constraint(equalToConstant: 36)
        
        NSLayoutConstraint.activate([
            
            closeButtonTop,
            closeButtonTrailing,
            closeButtonHeight,
            closeButtonWidth,
            
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            
            constraint,
            
            cancelButtonBottom,
            cancelButtonTrailing,
            cancelButtonLeading,
            cancelButtonHeight
        ])
    }
    
    override func setupConstraints() {
        
        addSharedConstraints()
        
        switch message.body {
            
        case is MessageText:
            
            let textLabelTop = textLabel.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 25)
            let textLabelTrailing = textLabel.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
            let textLabelLeading = textLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)
            
            let cancelButtonTop = cancelButton.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 16)
            
            NSLayoutConstraint.activate([
                
                textLabelTop,
                textLabelTrailing,
                textLabelLeading,
                cancelButtonTop
                
            ])
            
        case is MessageMedia:
            
            let backgroundImageViewTop = backgroundImageView.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 0)
            let backgroundImageViewBottom = backgroundImageView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -86)
            let backgroundImageViewTrailing = backgroundImageView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: 0)
            let backgroundImageViewLeading = backgroundImageView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 0)
            let backgroundImageViewHeight = backgroundImageView.heightAnchor.constraint(equalToConstant: 400)
            
            let imageViewTop = imageView.topAnchor.constraint(equalTo: backgroundImageView.topAnchor, constant: 0)
            let imageViewBottom = imageView.bottomAnchor.constraint(equalTo: backgroundImageView.bottomAnchor, constant: 0)
            let imageViewTrailing = imageView.trailingAnchor.constraint(equalTo: backgroundImageView.trailingAnchor, constant: 0)
            let imageViewLeading = imageView.leadingAnchor.constraint(equalTo: backgroundImageView.leadingAnchor, constant: 0)
            
            let placeholderImageCenterX = placeholderImageView.centerXAnchor.constraint(equalTo: backgroundView.centerXAnchor, constant: 0)
            let placeholderImageCenterY = placeholderImageView.centerYAnchor.constraint(equalTo: imageView.centerYAnchor, constant: 0)
            let placeholderImageViewWidth = placeholderImageView.heightAnchor.constraint(equalToConstant: 134)
            let placeholderImageViewHeight = placeholderImageView.heightAnchor.constraint(equalToConstant: 134)
            
            let cancelButtonTop = cancelButton.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 25)
            
            NSLayoutConstraint.activate([
                
                backgroundImageViewTop,
                backgroundImageViewBottom,
                backgroundImageViewTrailing,
                backgroundImageViewLeading,
                backgroundImageViewHeight,
                
                imageViewTop,
                imageViewBottom,
                imageViewTrailing,
                imageViewLeading,
                
                placeholderImageCenterX,
                placeholderImageCenterY,
                placeholderImageViewWidth,
                placeholderImageViewHeight,
                cancelButtonTop
            ])
            
        case is MessageLocation:
            
            let mapViewTop = mapView.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 0)
            let mapViewTrailing = mapView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: 0)
            let mapViewLeading = mapView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 0)
            let mapViewHeight = mapView.heightAnchor.constraint(equalToConstant: 200.0)
            
            let titleLabelTop = textLabel.topAnchor.constraint(equalTo: mapView.bottomAnchor, constant: 25)
            let titleLabelTrailing = textLabel.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
            let titleLabelLeading = textLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)
            
            let locationButtonTop = locationButton.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 16)
            let locationButtonTrailing = locationButton.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
            let locationButtonLeading = locationButton.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)
            let locationButtonHeight = locationButton.heightAnchor.constraint(equalToConstant: 36.0)
            
            let cancelButtonTop = cancelButton.topAnchor.constraint(equalTo: locationButton.bottomAnchor, constant: 16)
            
            NSLayoutConstraint.activate([
                
                mapViewTop,
                mapViewTrailing,
                mapViewLeading,
                mapViewHeight,
                
                titleLabelTop,
                titleLabelTrailing,
                titleLabelLeading,
                
                locationButtonTop,
                locationButtonTrailing,
                locationButtonLeading,
                locationButtonHeight,
                cancelButtonTop
            ])
            
        case is MessageChoices:
            let titleLabelTop = textLabel.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 25)
            let titleLabelTrailing = textLabel.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
            let titleLabelLeading = textLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)
            
            let stackTop = buttonsStackView.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 16)
            let stackTrailing = buttonsStackView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
            let stackLeading = buttonsStackView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)
            let cancelButtonTop = cancelButton.topAnchor.constraint(equalTo: buttonsStackView.bottomAnchor, constant: 16)
            
            NSLayoutConstraint.activate([
                
                titleLabelTop,
                titleLabelTrailing,
                titleLabelLeading,
                
                stackTop,
                stackLeading,
                stackTrailing,
                cancelButtonTop
            ])
            
        case is MessageCard:
            
            let backgroundImageViewTop = backgroundImageView.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 0)
            let backgroundImageViewTrailing = backgroundImageView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: 0)
            let backgroundImageViewLeading = backgroundImageView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 0)
            let backgroundImageViewHeight = backgroundImageView.heightAnchor.constraint(equalToConstant: 200)
            
            let imageViewTop = imageView.topAnchor.constraint(equalTo: backgroundImageView.topAnchor, constant: 0)
            let imageViewBottom = imageView.bottomAnchor.constraint(equalTo: backgroundImageView.bottomAnchor, constant: 0)
            let imageViewTrailing = imageView.trailingAnchor.constraint(equalTo: backgroundImageView.trailingAnchor, constant: 0)
            let imageViewLeading = imageView.leadingAnchor.constraint(equalTo: backgroundImageView.leadingAnchor, constant: 0)
            
            let placeholderImageCenterX = placeholderImageView.centerXAnchor.constraint(equalTo: backgroundImageView.centerXAnchor, constant: 0)
            let placeholderImageCenterY = placeholderImageView.centerYAnchor.constraint(equalTo: imageView.centerYAnchor, constant: 0)
            let placeholderImageViewWidth = placeholderImageView.widthAnchor.constraint(equalToConstant: 100)
            let placeholderImageViewHeight = placeholderImageView.heightAnchor.constraint(equalToConstant: 100)
            
            let titleLabelTop = titleLabel.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 25)
            let titleLabelTrailing = titleLabel.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
            let titleLabelLeading = titleLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)
            
            let textLabelTop = textLabel.topAnchor.constraint(equalTo:  titleLabel.bottomAnchor, constant: 16)
            let textLabelTrailing = textLabel.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
            let textLabelLeading = textLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)
            
            let stackTop = buttonsStackView.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 16)
            let stackTrailing = buttonsStackView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
            let stackLeading = buttonsStackView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)
            
            let cancelButtonTop = cancelButton.topAnchor.constraint(equalTo: buttonsStackView.bottomAnchor, constant: 16)
            
            NSLayoutConstraint.activate([
                
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
                cancelButtonTop
            ])
            case let message as MessageCarousel:
            let horizontalScrollViewTop = horizontalScrollView.topAnchor.constraint(equalTo:  backgroundView.topAnchor, constant: 0)
            let horizontalScrollViewTrailing = horizontalScrollView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: 0)
            let horizontalScrollViewLeading = horizontalScrollView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 0)
            
            let horizontalContentViewTop = horizontalContentView.topAnchor.constraint(equalTo:  horizontalScrollView.topAnchor, constant: 0)
            let horizontalContentViewTrailing = horizontalContentView.trailingAnchor.constraint(equalTo: horizontalScrollView.trailingAnchor, constant: 0)
            let horizontalContentViewLeading = horizontalContentView.leadingAnchor.constraint(equalTo: horizontalScrollView.leadingAnchor, constant: 0)
            let horizontalContentViewBottom = horizontalContentView.bottomAnchor.constraint(equalTo: horizontalScrollView.bottomAnchor, constant: 0)
            
            let constraint = horizontalContentView.heightAnchor.constraint(equalTo: horizontalScrollView.heightAnchor, constant: 0.0)
            //            constraint.priority = UILayoutPriority(250)
            
            let cardsStackViewTop = cardsStackView.topAnchor.constraint(equalTo:  horizontalContentView.topAnchor, constant: 0)
            let cardsStackViewTrailing = cardsStackView.trailingAnchor.constraint(equalTo: horizontalContentView.trailingAnchor, constant: 0)
            let cardsStackViewLeading = cardsStackView.leadingAnchor.constraint(equalTo: horizontalContentView.leadingAnchor, constant: 0)
            let cardsStackViewBottom = cardsStackView.bottomAnchor.constraint(equalTo: horizontalContentView.bottomAnchor, constant: 0)
            
            for (_, card) in cards.enumerated() {
                
                card.widthAnchor.constraint(equalTo: backgroundView.widthAnchor, constant: 0).isActive = true
                
            }
            
            let pageTop = pageControl.topAnchor.constraint(equalTo: horizontalScrollView.bottomAnchor, constant: 2)
            let pageTrailing = pageControl.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
            let pageLeading = pageControl.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)
            let pageHeight = pageControl.heightAnchor.constraint(equalToConstant: 8)
            
            let lineTop: NSLayoutConstraint
            
            if message.cards.count == 1 {
                
                lineTop = lineView.topAnchor.constraint(equalTo: cardsStackView.bottomAnchor, constant: 8)
                
            } else {
                lineTop = lineView.topAnchor.constraint(equalTo: pageControl.bottomAnchor, constant: 16)

            }
            
            let lineTrailing = lineView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: 0)
            let lineLeading = lineView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 0)
            let lineHeight = lineView.heightAnchor.constraint(equalToConstant: 1)
            
            let stackTop = buttonsStackView.topAnchor.constraint(equalTo: lineView.bottomAnchor, constant: 16)
            let stackTrailing = buttonsStackView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -25)
            let stackLeading = buttonsStackView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 25)
            
            let cancelButtonTop: NSLayoutConstraint
            
            if message.choices.isEmpty {
                
                cancelButtonTop = cancelButton.topAnchor.constraint(equalTo: lineView.bottomAnchor, constant: 16)
                
            } else {
                cancelButtonTop = cancelButton.topAnchor.constraint(equalTo: buttonsStackView.bottomAnchor, constant: 16)

            }
            
            NSLayoutConstraint.activate([
                
                constraint,
                horizontalContentViewTop,
                horizontalContentViewTrailing,
                horizontalContentViewLeading,
                horizontalContentViewBottom,
                
                horizontalScrollViewTop,
                horizontalScrollViewTrailing,
                horizontalScrollViewLeading,
                
                cardsStackViewTop,
                cardsStackViewTrailing,
                cardsStackViewLeading,
                cardsStackViewBottom,
                
                cardsStackView.widthAnchor.constraint(equalTo:backgroundView.widthAnchor, multiplier: CGFloat(cards.count)),
                stackTop,
                stackLeading,
                stackTrailing,
                
                pageTop,
                pageTrailing,
                pageLeading,
                pageHeight,
                
                lineTop,
                lineTrailing,
                lineLeading,
                lineHeight,
                cancelButtonTop
            ])
            
        default:
            break
            
        }
        
    }
    func layoutTrait(traitCollection:UITraitCollection) {
        
        if traitCollection.horizontalSizeClass == .compact && traitCollection.verticalSizeClass == .regular {
            if !regularConstraints.isEmpty && regularConstraints[0].isActive {
                NSLayoutConstraint.deactivate(regularConstraints)
            }
            // activating compact constraints
            NSLayoutConstraint.activate(compactConstraints)
        } else {
            if !compactConstraints.isEmpty && compactConstraints[0].isActive {
                NSLayoutConstraint.deactivate(compactConstraints)
            }
            // activating regular constraints
            NSLayoutConstraint.activate(regularConstraints)
        }
    }
    
    @objc func choiceButtonTapped(_ sender: AnyObject) {
        if let button = sender as? TitleButton {
            button.changeButtonAppearanceInAppMessage()
            let tag = button.tag
            if let body = message.body as? MessageWithChoices {
                delegate?.didTapOnChoice(body.choices[tag])
                
            }
        }
    }
    
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        if scrollView == horizontalScrollView {
            
            targetContentOffset.pointee.x = ScrollViewHelper.getTargetContentOffset(scrollView: scrollView,
                                                                                    velocity: velocity,
                                                                                    pageWidth: pageWidth)
        }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView == horizontalScrollView {
            let pageNumber = ScrollViewHelper.getCurrentPage(scrollView: scrollView, pageWidth: pageWidth)
            pageControl.currentPage = Int(pageNumber)
        }
    }
    
    private func setImageFromURL(_ urlString: String) {
        
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(imageTapped(tapGestureRecognizer:)))
        imageView.addGestureRecognizer(tapGestureRecognizer)
        
        if let url = URL(string: urlString) {
            
            imageView.setImage(url:url) { [weak self] result in
                
                guard let self = self else { return }
                
                switch result {
                case .success(let imageResult):
                    if imageResult.image.isDark {
                        self.closeButton.setImage( self.uiConfig.inAppMessageLightCloseImage, for: .normal)
                        
                    } else {
                        self.closeButton.setImage( self.uiConfig.inAppMessageDarkCloseImage, for: .normal)
                        
                    }
                case .failure(_):
                    self.imageView.image = nil
                }
            }
        } else {
            self.imageView.image = nil
        }
    }
    @objc func imageTapped(tapGestureRecognizer: UITapGestureRecognizer) {
        guard let message = message.body as? MessageWithURL else {
            return
        }
        if let url = URL(string: message.url) {
            delegate?.didTapOnMediaUrl(url)
        }
        
    }
    @objc func openMaps() {
        guard let message = message.body as? MessageLocation,
              let title = message.title.replacingOccurrences(of: " ", with: "+").addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else {
            return
        }
        
        let choiceLocation = ChoiceLocation(text: title, label: message.label, latitude: message.latitude, longitude: message.longitude)
        
        delegate?.didTapOnChoice(.locationMessage(choiceLocation))
    }
}
extension InAppMessageView: CardProtocol {
    
    func didTapOnChoice(_ text: ChoiceMessageType) {
        delegate?.didTapOnChoice(text)
    }
    
    func didTapOnMedia(_ url: URL) {
        delegate?.didTapOnMediaUrl(url)
    }
}
