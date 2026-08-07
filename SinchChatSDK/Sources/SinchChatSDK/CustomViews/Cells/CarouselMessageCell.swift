import UIKit
import SwiftUI
final class CarouselMessageCell: MessageContentCell, UIScrollViewDelegate {
    
    static let cellId = "carouselMessageCell"
    
    var scrollView : UIScrollView = {
        
        var scrollView = UIScrollView()
        scrollView.isPagingEnabled = true
        scrollView.backgroundColor = .clear
        scrollView.decelerationRate = .fast
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false

        return scrollView
    }()
    var backgroundContainerView: UIView = {
        let containerView = UIView()
        containerView.backgroundColor = .white
        containerView.clipsToBounds = true
        containerView.layer.masksToBounds = true
        return containerView
    }()
    var cardContainerView: UIView = {
        let containerView = UIView()
        containerView.backgroundColor = .white
        containerView.clipsToBounds = true
        containerView.layer.masksToBounds = true
        return containerView
    }()
    var carouselChoiceContainerView: UIView = {
        let containerView = UIView()
        containerView.backgroundColor = .gray
        containerView.clipsToBounds = true
        containerView.layer.masksToBounds = true
        return containerView
    }()
    
    var pageControl = UIPageControl()
    
    var scrollContentView: UIView = UIView()
    
    var dateLabel = MessageLabel()
    
    var message: Message?
    var buttons: [TitleButton] = []
    var buttonsFrame: [CGRect] = []
    var cards: [CardView] = []

    private var contentHeightConstraint: NSLayoutConstraint!
    private var contentWidthConstraint: NSLayoutConstraint!
    private var stackContentWidthConstraint: NSLayoutConstraint!
    private var cellAttributes: ChatFlowLayoutAttributes!
    var pageWidth: CGFloat = 240.0
    
    // MARK: - Methods
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? ChatFlowLayoutAttributes {
            let page = ceil(ScrollViewHelper.getCurrentPage(scrollView: scrollView, pageWidth: pageWidth))

            cellAttributes = attributes
            pageWidth = attributes.carouselContentViewFrame.width
            backgroundContainerView.frame = CGRect(origin: .zero, size: attributes.messageContainerSize)
            cardContainerView.frame = attributes.carouselCardViewFrame
            carouselChoiceContainerView.frame = attributes.carouselChoiceButtonsViewFrame
            
            if let maxCardFrameHeight = cellAttributes.carouselCardFrames.map({ $0.frame.size.height }).max() {
                
                scrollView.frame = CGRect(x: 0,
                                          y: 0,
                                          width: attributes.carouselContentViewFrame.width,
                                          height: maxCardFrameHeight)
                scrollContentView.frame = CGRect(x: 0,
                                                 y: 0,
                                                 width: attributes.carouselContentViewFrame.width * CGFloat(attributes.carouselCardFrames.count),
                                                 height: maxCardFrameHeight)
                
            }
            
            scrollView.contentSize = scrollContentView.frame.size
            pageControl.frame = attributes.pageControlFrame

            for card in cards {
                
                card.updateViewWithAttributes(attributes)
                
            }
            
            dateLabel.messageLabelFont = attributes.dateLabelFont
            dateLabel.textInsets = attributes.dateLabelTextInsets
            dateLabel.frame =  attributes.dateLabelFrame
            
            if buttons.count == attributes.buttonsFrame.count {
                for index in 0..<attributes.buttonsFrame.count {
                    buttons[index].frame = attributes.buttonsFrame[index]
                }
            }
            buttonsFrame = attributes.buttonsFrame
            
            scrollView.setContentOffset(CGPoint(x: page * attributes.carouselContentViewFrame .width, y: 0.0), animated: false)
            
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        dateLabel.text = nil
        avatarView.imageView.image = nil
        for button in buttons {
            button.removeFromSuperview()
        }
        buttons.removeAll()
        for card in cards {
            card.removeFromSuperview()
        }
        cards.removeAll()
        pageControl.currentPage = 0
        scrollView.setContentOffset(CGPoint(x: 0.0, y: 0.0), animated: false)

    }
    
    override func setupSubviews() {
        super.setupSubviews()
        messageContainerView.addSubview(backgroundContainerView)
        backgroundContainerView.addSubview(cardContainerView)
        cardContainerView.addSubview(scrollView)
        scrollView.addSubview(scrollContentView)
        cardContainerView.addSubview(pageControl)
        backgroundContainerView.addSubview(carouselChoiceContainerView)
        backgroundContainerView.addSubview(dateLabel)

        scrollView.delegate = self
        statusView.isHidden = true

    }
   
    override func configure(with message: Message, at indexPath: IndexPath, and messagesCollectionView: MessageCollectionView) {
        self.message = message
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        pageWidth = cellAttributes.carouselContentViewFrame.width

        setupContainerView(messagesCollectionView, message)
        setupCards(message: message, messagesCollectionView: messagesCollectionView)
        setupPageControl(message:message, uiConfig: messagesCollectionView.uiConfig)
        
        if let message = message.body as? MessageCarousel {
            setupButtons( choices: message.choices, messagesCollectionView: messagesCollectionView)
            if message.currentCard != 0 {
                scrollView.setContentOffset(CGPoint(x: message.currentCard * Int(pageWidth), y:0), animated: false)
            }
        }
        
        dateLabel.configure {
            
            if let dateInSeconds = message.body.sendDate {
                
                dateLabel.text =  Date(timeIntervalSince1970: TimeInterval(dateInSeconds)).getFormattedTime()
            }
        }
        
        if let dateFont = dateLabel.messageLabelFont {
            dateLabel.font = dateFont
        }
        
        switch message.owner {
            
        case .outgoing:
            backgroundContainerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner]

        case .incoming(_):
            backgroundContainerView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner, .layerMinXMinYCorner]
        case .system:
            backgroundContainerView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner, .layerMinXMinYCorner, .layerMinXMaxYCorner]

        }
        
        if let message = message.body as? MessageCarousel {
            carouselChoiceContainerView.layer.masksToBounds = true
            
            cardContainerView.layer.cornerRadius = 10.0
            cardContainerView.layer.masksToBounds = true
            
            if message.choices.isEmpty {
                cardContainerView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner, .layerMinXMinYCorner, .layerMinXMaxYCorner]
                carouselChoiceContainerView.layer.cornerRadius = 0

            } else {
                carouselChoiceContainerView.layer.cornerRadius = 10.0
                carouselChoiceContainerView.layer.masksToBounds = true
                
                cardContainerView.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMinXMinYCorner]
                carouselChoiceContainerView.layer.maskedCorners = [.layerMaxXMaxYCorner, .layerMinXMaxYCorner]

            }
        }
    }
    
    private func setupPageControl(message: Message, uiConfig: SinchSDKConfig.UIConfig) {
        if let message = message.body as? MessageCarousel {
            pageControl.numberOfPages = message.cards.count
            pageControl.currentPage = 0
            pageControl.currentPageIndicatorTintColor = uiConfig.pageControlSelectedColor
            pageControl.pageIndicatorTintColor = uiConfig.pageControlUnselectedColor
            pageControl.isUserInteractionEnabled = false
            pageControl.hidesForSinglePage = true

        }
    }
    private func setupCards(message: Message, messagesCollectionView: MessageCollectionView) {
        
        guard let carouselMessage = message.body as? MessageCarousel else { return }
        pageWidth = cellAttributes.carouselContentViewFrame.width

        if let maxCardFrameHeight = cellAttributes.carouselCardFrames.map({ $0.frame.size.height }).max() {
            
            scrollView.frame = CGRect(x: 0, y: 0, width: cellAttributes.carouselContentViewFrame.width, height: maxCardFrameHeight)
            scrollContentView.frame = CGRect(x: 0, y: 0, width: cellAttributes.carouselContentViewFrame.width * CGFloat(carouselMessage.cards.count), height: maxCardFrameHeight)
        
        }
        scrollView.contentSize = scrollContentView.frame.size
        
        for index in 0..<carouselMessage.cards.count {
            
            let cardView = CardView(uiConfiguration: messagesCollectionView.uiConfig,
                                    localizationConfiguration: messagesCollectionView.localizationConfig,
                                    message: carouselMessage.cards[index],
                                    attributes: cellAttributes,
                                    index: index)
            cardView.textLabel.selectedCard = 0
            cardView.textLabel.message = message
            cardView.textLabel.delegate = messagesCollectionView.touchDelegate
            cardView.delegate = self
            cards.append(cardView)
            scrollContentView.addSubview(cardView)
        }
    }
    private func setupButtons(choices: [ChoiceMessageType], messagesCollectionView: MessageCollectionView) {
        for index in 0..<choices.count {
            let button = TitleButton(frame: buttonsFrame[index], with: messagesCollectionView.uiConfig)
            button.titleLabel?.font = messagesCollectionView.uiConfig.buttonTitleFont
            button.setTitleColor( messagesCollectionView.uiConfig.buttonTitleColor, for: .normal)
            button.setTitleColor( messagesCollectionView.uiConfig.tappedButtonTitleColor, for: .selected)

            button.backgroundColor = messagesCollectionView.uiConfig.buttonBackgroundColor
            
            switch choices[index] {
            case .textMessage(let message):
                button.setTitle(message.text, for: .normal)
                
            case .urlMessage(let message):
                button.setTitle(message.text, for: .normal)
                
            case .callMessage(let message):
                button.setTitle(message.text, for: .normal)
                
            case .locationMessage(let message):
                button.setTitle(message.label, for: .normal)
                
            }
            button.tag = index
            button.addTarget(self, action: #selector(carouselChoiceButtonTapped(_ :)), for: .touchUpInside)
            
            buttons.append(button)
            carouselChoiceContainerView.addSubview(button)
            
        }
    }
    
    private func setupContainerView(_ messagesCollectionView: MessageCollectionView, _ message: Message) {
        delegate = messagesCollectionView.touchDelegate
        messageContainerView.backgroundColor = .clear
        backgroundContainerView.backgroundColor = messagesCollectionView.uiConfig.carouselMessageChoicesBackgroundColor

        if message.isFromCurrentUser() {
            cardContainerView.backgroundColor = messagesCollectionView.uiConfig.outgoingMessageBackgroundColor
            carouselChoiceContainerView.backgroundColor = messagesCollectionView.uiConfig.outgoingMessageBackgroundColor

        } else {
            cardContainerView.backgroundColor = messagesCollectionView.uiConfig.incomingMessageBackgroundColor
            carouselChoiceContainerView.backgroundColor = messagesCollectionView.uiConfig.incomingMessageBackgroundColor
            avatarView.updateWithModel(message, uiConfig: messagesCollectionView.uiConfig)
        }
         dateLabel.textColor = messagesCollectionView.uiConfig.dateMessageLabelTextColor
    }
    
    /// Handle tap gesture on contentView and its subviews.
    override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        let touchLocation = gesture.location(in: self.contentView)
        
        if !messageContainerView.frame.contains(touchLocation) {
            delegate?.didTapOutsideOfContent(in: self)

        } else if messageContainerView.frame.contains(touchLocation) {
            guard let carouselMessage = message?.body as? MessageCarousel else { return }
            let card = cards[pageControl.currentPage]
            card.textLabel.handleGesture(convert(touchLocation, to: card.textLabel))

            debugPrint("user tap text")
        } else {
            delegate?.didTapOutsideOfContent(in: self)
            
        }
    }
    
    @objc func carouselChoiceButtonTapped(_ sender: AnyObject) {
        if let button = sender as? TitleButton, let body = message?.body as? MessageCarousel {
            button.changeButtonAppearanceInChat()
            let tag = button.tag
            let choices = body.choices
            delegate?.didTapOnChoice(choices[tag], in: self)
            
        }
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        targetContentOffset.pointee.x = ScrollViewHelper.getTargetContentOffset(scrollView: scrollView,
                                                                                velocity: velocity,
                                                                                pageWidth: pageWidth)
        
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let pageNumber = Int(ScrollViewHelper.getCurrentPage(scrollView: scrollView, pageWidth: pageWidth))
        for card in cards {
            card.textLabel.selectedCard = pageNumber
        }
        pageControl.currentPage = pageNumber
    }
}
extension CarouselMessageCell: CardProtocol {
  
    func didTapOnMedia(_ url: URL) {
        delegate?.didTapMedia(with: url)
    }
    
    func didTapOnChoice(_ text: ChoiceMessageType) {
        delegate?.didTapOnChoice(text, in: self)
    }
}
