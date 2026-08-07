import MapKit
import CoreLocation
import Foundation

@MainActor
protocol LocationDelegate: AnyObject {
    func didShareLocation(latitude: Float, longitude: Float)
}

final class LocationViewController: SinchViewController<LocationViewModel, LocationView> {
    var locationManager: CLLocationManager?
    var currentLocation: CLLocationCoordinate2D?
    weak var delegate: LocationDelegate?
    var isUpdatingLocation = false

    override func viewDidLoad() {
        super.viewDidLoad()
        addObservers()

        if CLLocationManager.locationServicesEnabled() {
            checkForLocationStatus()

        } else {
            showLocationDisabledAlert()
        }
        
        locationManager?.delegate = self

        mainView.mapView.delegate = self
        mainView.mapView.mapType = .standard
        mainView.mapView.isZoomEnabled = true
        mainView.mapView.isScrollEnabled = true
        
        if let location = locationManager?.location {
            setRegionFromLocation(location.coordinate)
            currentLocation = location.coordinate
        }
        
        mainView.closeButton.addTarget(self, action: #selector(closeLocationAction), for: .touchUpInside)
        mainView.sendButton.addTarget(self, action: #selector(sendButtonAction), for: .touchUpInside)
         
    }
    
    func handleLocationAuthorizationStatus(_ authorizationStatus: CLAuthorizationStatus) {
        switch authorizationStatus {
            
        case .restricted, .denied:
            showLocationNotAllowedForAppAlert()
        case .notDetermined:
            locationManager?.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
        
            startLocationManager()
            
        @unknown default:
            break
        }
    }
    
    func startLocationManager() {
        if !isUpdatingLocation {
        mainView.mapView.showsUserLocation = true
        locationManager?.startUpdatingLocation()
        isUpdatingLocation = true
        }
    }
    func stopLocationManager() {
        locationManager?.stopUpdatingLocation()
        mainView.mapView.showsUserLocation = false
        isUpdatingLocation = false
    }
   
    deinit {
        removeObservers()

    }
    private func checkForLocationStatus() {
                
        guard let locationManager = locationManager else { return }

        if #available(iOS 14.0, *) {
            
            handleLocationAuthorizationStatus( locationManager.authorizationStatus)
        } else {
            handleLocationAuthorizationStatus( CLLocationManager.authorizationStatus())
            
        }
       
    }
    fileprivate  func addObservers() {
          NotificationCenter.default.addObserver(self,
                                                 selector: #selector(applicationDidBecomeActive),
                                                 name: UIApplication.didBecomeActiveNotification,
                                                 object: nil)
        }

    private  func removeObservers() {
            NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc fileprivate func applicationDidBecomeActive() {

        checkForLocationStatus()
        
    }
    
    private func showLocationNotAllowedForAppAlert() {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: self.mainView.localizationConfiguration.locationDeniedInAppAlertTitle, message: nil, preferredStyle: .alert)
            let notNowButton = UIAlertAction(title: self.mainView.localizationConfiguration.locationAlertButtonTitleNotNow, style: .default) { [weak self] _ in
                self?.closeLocationAction()
            }
            let settingsButton = UIAlertAction(title: self.mainView.localizationConfiguration.locationAlertButtonTitleSettings, style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    if UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                }
            }
            
            alert.addAction(notNowButton)
            alert.addAction(settingsButton)
            
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    private func showLocationDisabledAlert() {
        DispatchQueue.main.async {
            let alert = UIAlertController(title: self.mainView.localizationConfiguration.locationDisabledAlertTitle,
                                          message: self.mainView.localizationConfiguration.locationDisabledAlertMessage,
                                          preferredStyle: .alert)
            let okButton = UIAlertAction(title: self.mainView.localizationConfiguration.locationAlertButtonTitleOk, style: .default) { [weak self] _ in
                self?.closeLocationAction()
            }
            let settingsButton = UIAlertAction(title: self.mainView.localizationConfiguration.locationAlertButtonTitleSettings, style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    if UIApplication.shared.canOpenURL(url) {
                        UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    }
                }
            }

            alert.addAction(okButton)
            alert.addAction(settingsButton)

            self.present(alert, animated: true, completion: nil)
        }
    }
    
    @objc private func closeLocationAction() {
        stopLocationManager()
        self.dismiss(animated: true, completion: nil)
    }
    
    @objc func sendButtonAction() {
        
        if let currentLocation = currentLocation {
            stopLocationManager()
            delegate?.didShareLocation(latitude: Float(currentLocation.latitude), longitude: Float(currentLocation.longitude))
            dismiss(animated: true, completion: nil)
        }
    }
}
@MainActor
extension LocationViewController: CLLocationManagerDelegate, MKMapViewDelegate {
    fileprivate func handleChangeOfStatus(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            startLocationManager()
            
        case .notDetermined:
            currentLocation = nil
            locationManager?.requestWhenInUseAuthorization()
            
        case .denied, .restricted:
            mainView.mapView.showsUserLocation = false
            currentLocation = nil
            
        @unknown default:
            break
        }
    }
    
    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor [weak self] in
            self?.handleChangeOfStatus(status)
        }
    }

    @available(iOS 14, *)
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.handleChangeOfStatus(status)
        }
    }

    private func setRegionFromLocation(_ locationValue: CLLocationCoordinate2D) {
        let span = MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        let region = MKCoordinateRegion(center: locationValue, span: span)
        mainView.mapView.setRegion(region, animated: true)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let locationValue: CLLocationCoordinate2D = manager.location?.coordinate else { return }
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if self.currentLocation == nil {
                self.setRegionFromLocation(locationValue)
                self.currentLocation = locationValue
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Error \(error)")
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        if currentLocation != nil {
            currentLocation = mapView.centerCoordinate

        }
    }
}
