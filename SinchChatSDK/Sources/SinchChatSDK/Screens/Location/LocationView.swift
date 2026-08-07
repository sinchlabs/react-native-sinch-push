import UIKit
import MapKit

final class LocationView: SinchView {
    
    lazy var closeButton: UIButton = {
        let closeButton = UIButton()
        closeButton.setTitle(localizationConfiguration.locationShareCancel, for: .normal)
        closeButton.titleLabel?.font = uiConfig.buttonTitleFont
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.backgroundColor = .clear
        closeButton.titleLabel?.textAlignment = .left

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        return closeButton
    }()
    lazy var sendButton: UIButton = {
        let sendButton = UIButton()
        sendButton.titleLabel?.font = uiConfig.buttonTitleFont
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.backgroundColor = .clear
        sendButton.titleLabel?.textAlignment = .right
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle(localizationConfiguration.locationShare, for: .normal)
        return sendButton
    }()
    lazy var mapView: MKMapView = {
        let mapView = MKMapView()
        mapView.translatesAutoresizingMaskIntoConstraints = false
        
        return mapView
    }()
    var topOverlayView: TransparentView = {
        let backgroundView = TransparentView()
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        return backgroundView
    }()
    var bottomOverlayView: TransparentView = {
        let backgroundView = TransparentView()
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        return backgroundView
    }()
    var bottomView: UIView = {
        let bottomView = UIView()
        bottomView.backgroundColor = .black
        bottomView.translatesAutoresizingMaskIntoConstraints = false
        return bottomView
    }()
    var markerImageView: UIImageView = {
        let markerImageView = UIImageView()
        markerImageView.translatesAutoresizingMaskIntoConstraints = false
        return markerImageView
    }()
    
    override func setupSubviews() {
        backgroundColor = uiConfig.navigationBarColor
        mapView.tintColor = uiConfig.locationDotColor
        markerImageView.image = uiConfig.locationMarkerImage
        addSubview(mapView)
        mapView.addSubview(topOverlayView)
        mapView.addSubview(bottomOverlayView)
        addSubview(bottomView)

        bottomView.addSubview(closeButton)
        bottomView.addSubview(sendButton)
        mapView.addSubview(markerImageView)

    }
    
    override func setupConstraints() {
        let bottomViewHeight = bottomView.heightAnchor.constraint(equalToConstant: 70)
        let bottomViewTrailing = bottomView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0)
        let bottomViewLeading = bottomView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        let bottomViewBottom = bottomView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: 0)
        
        let closeButtonBottom = closeButton.centerYAnchor.constraint(equalTo:  bottomView.centerYAnchor)
        let closeButtonLeading = closeButton.leadingAnchor.constraint(equalTo:  leadingAnchor, constant: 15)
        let closeButtonHeight = closeButton.heightAnchor.constraint(equalToConstant: 40)
        
        let sendButtonBottom = sendButton.centerYAnchor.constraint(equalTo:  bottomView.centerYAnchor)
        let sendButtonTrailing = sendButton.trailingAnchor.constraint(equalTo:  trailingAnchor, constant: -15)
        let sendButtonHeight = sendButton.heightAnchor.constraint(equalToConstant: 40)
        
        let mapViewTop = mapView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 0)
        let mapViewTrailing = mapView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0)
        let mapViewLeading = mapView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        let mapViewBottom = mapView.bottomAnchor.constraint(equalTo:  bottomView.topAnchor, constant: 0)

        let topOverlayViewViewHeight = topOverlayView.heightAnchor.constraint(equalToConstant: 100)
        let topOverlayViewTrailing = topOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0)
        let topOverlayViewLeading = topOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        let topOverlayViewTop = topOverlayView.topAnchor.constraint(equalTo: mapView.topAnchor, constant: 0)

        let bottomOverlayViewHeight = bottomOverlayView.heightAnchor.constraint(equalToConstant: 67)
        let bottomOverlayViewTrailing = bottomOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0)
        let bottomOverlayViewLeading = bottomOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        let bottomOverlayViewBottom = bottomOverlayView.bottomAnchor.constraint(equalTo: mapView.bottomAnchor, constant: 0)
        
        let markerImageViewHeight = markerImageView.heightAnchor.constraint(equalToConstant: 20)
        let markerImageViewWidth = markerImageView.widthAnchor.constraint(equalToConstant: 16)
        let markerImageViewCenterY = markerImageView.centerYAnchor.constraint(equalTo: mapView.centerYAnchor, constant: -10)
        let markerImageViewCenterX = markerImageView.centerXAnchor.constraint(equalTo: mapView.centerXAnchor, constant: 0)
        
        NSLayoutConstraint.activate([
            
            bottomViewHeight,
            bottomViewTrailing,
            bottomViewLeading,
            bottomViewBottom,
            
            sendButtonBottom,
            sendButtonTrailing,
            sendButtonHeight,
            
            closeButtonBottom,
            closeButtonLeading,
            closeButtonHeight,
            
            mapViewTop,
            mapViewTrailing,
            mapViewLeading,
            mapViewBottom,
            
            topOverlayViewViewHeight,
            topOverlayViewTrailing,
            topOverlayViewLeading,
            topOverlayViewTop,
            
            bottomOverlayViewHeight,
            bottomOverlayViewTrailing,
            bottomOverlayViewLeading,
            bottomOverlayViewBottom,
            
            markerImageViewHeight,
            markerImageViewWidth,
            markerImageViewCenterY,
            markerImageViewCenterX
        ])
    }
}
