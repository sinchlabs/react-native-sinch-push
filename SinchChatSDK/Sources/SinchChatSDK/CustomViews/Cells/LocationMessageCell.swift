import UIKit
import MapKit

class LocationMessageCell: MessageContentCell {
    
    static let cellId = "locationMessageCell"
    
    /// The image view display the media content.
    var mapView: MKMapView = {
        let mapView = MKMapView()
        return mapView
    }()
    
    var messageLabel = MessageLabel()
    var dateLabel = MessageLabel()
    var locationButton = TitleImageButton()
    var message: Message?
    // MARK: - Methods
    
    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        if let attributes = layoutAttributes as? ChatFlowLayoutAttributes {
            messageLabel.textInsets = attributes.messageLabelTextInsets
            messageLabel.messageLabelFont = attributes.messageLabelFont
            dateLabel.messageLabelFont = attributes.dateLabelFont
            mapView.frame = attributes.mapFrame
            dateLabel.textInsets = attributes.dateLabelTextInsets
            messageLabel.frame =  attributes.messageLabelFrame
            if let buttonFrame = attributes.buttonsFrame.first {
                locationButton.frame = buttonFrame
            }
            dateLabel.frame =  attributes.dateLabelFrame
        }
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        mapView.removeAnnotations(mapView.annotations)
        dateLabel.text = nil
        messageLabel.text = nil
        avatarView.imageView.image = nil
    }
    
    // MARK: - Methods
    
    override func setupSubviews() {
        super.setupSubviews()
        
        messageContainerView.addSubview(mapView)
        messageContainerView.addSubview(messageLabel)
        messageContainerView.addSubview(locationButton)
        messageContainerView.addSubview(dateLabel)
        locationButton.addTarget(self, action: #selector(openMaps), for: .touchUpInside)
    }
    
    override func configure(with message: Message, at indexPath: IndexPath, and messagesCollectionView: MessageCollectionView) {
        self.message = message
        super.configure(with: message, at: indexPath, and: messagesCollectionView)
        
        setupContainerView(messagesCollectionView, message)
        setupMapView(message: message)
        setupMessageLabel(messageLabel, message, messagesCollectionView)

        if let message = message.body as? MessageLocation {
                             
            locationButton.setTitle(message.label, for: .normal)
        }
        
        dateLabel.configure {
            
            if let dateInSeconds = message.body.sendDate {
                
                dateLabel.text =  Date(timeIntervalSince1970: TimeInterval(dateInSeconds)).getFormattedTime()
            }
        }
        
        if let font = messageLabel.messageLabelFont {
            messageLabel.font = font
        }
        if let dateFont = dateLabel.messageLabelFont {
            dateLabel.font = dateFont
        }
    }
    
    private func setupContainerView(_ messagesCollectionView: MessageCollectionView, _ message: Message) {
        delegate = messagesCollectionView.touchDelegate
        
        if message.isFromCurrentUser() {
            messageContainerView.backgroundColor = messagesCollectionView.uiConfig.outgoingMessageBackgroundColor
            statusView.isHidden = false
            statusView.setupStatusView(message.status, in: messagesCollectionView)
            messageLabel.textColor = messagesCollectionView.uiConfig.outgoingMessageTextColor
        } else {
            statusView.isHidden = true
            messageContainerView.backgroundColor = messagesCollectionView.uiConfig.incomingMessageBackgroundColor
            messageLabel.textColor = messagesCollectionView.uiConfig.incomingMessageTextColor
            avatarView.updateWithModel(message, uiConfig: messagesCollectionView.uiConfig)
        }
        dateLabel.textColor = messagesCollectionView.uiConfig.dateMessageLabelTextColor
        
        locationButton.titleLabel?.font = messagesCollectionView.uiConfig.buttonTitleFont
        locationButton.setTitleColor( messagesCollectionView.uiConfig.buttonTitleColor, for: .normal)
        locationButton.setImage(messagesCollectionView.uiConfig.locationMessageImage, for:  .normal)
        locationButton.backgroundColor = messagesCollectionView.uiConfig.buttonBackgroundColor
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
    
    /// Handle tap gesture on contentView and its subviews.
    override func handleTapGesture(_ gesture: UIGestureRecognizer) {
        var touchLocation = gesture.location(in: self.contentView)

        if messageContainerView.frame.contains(touchLocation) {

            messageLabel.handleGesture(convert(touchLocation, to: messageLabel))
        } else {
            delegate?.didTapOutsideOfContent(in: self)
        }
    }
    
    @objc func openMaps() {
        guard let message = message?.body as? MessageLocation,
              let title = message.title.replacingOccurrences(of: " ", with: "+").addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) else {
            return
        }
        
        let locationChoice = ChoiceLocation(text: title, label: message.label, latitude: message.latitude, longitude: message.longitude)
        
        delegate?.didTapOnChoice(.locationMessage(locationChoice), in: self)
    }
}
