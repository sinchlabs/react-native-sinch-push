import Foundation
import UIKit

internal class LocationActionHandler {
    private let localization: SinchSDKConfig.LocalizationConfig
    
    init(_ localization: SinchSDKConfig.LocalizationConfig) {
        self.localization = localization
    }
    
    func handleOpenLocationAction(_ viewController: UIViewController, title: String?, latitude: Double, longitude: Double) {

        let alert = UIAlertController(title: localization.locationOpenActionSheetTitle, message: "", preferredStyle: .actionSheet)
                
        let appleMapsAction = UIAlertAction(title: localization.locationOpenAppleMaps, style: .default) {_ in
            LocationActionHandler.openAppleMaps(title: title, latitude: latitude, longitude: longitude)
        }
        alert.addAction(appleMapsAction)
        
        let googleMapsAction = UIAlertAction(title: localization.locationOpenGoogleMaps, style: .default) {_ in
            LocationActionHandler.openGoogleMaps(latitude: latitude, longitude: longitude)
        }
        
        alert.addAction(googleMapsAction)
        
        alert.addAction(UIAlertAction(title: localization.menuCancel, style: .cancel, handler: { _ in
            debugPrint("User click cancel button")
        }))
        alert.popoverPresentationController?.sourceView = viewController.view
        
        viewController.present(alert, animated: true)
    }
    
    private static func openAppleMaps(title: String?, latitude: Double, longitude: Double) {
            
        let scheme = "http"
        let host = "maps.apple.com"
        let path = ""
        let queryItem1 = URLQueryItem(name: "q", value: (title ?? ""))
        let queryItem2 = URLQueryItem(name: "ll", value: "\(latitude),\(longitude)")

        var urlComponents = URLComponents()
        urlComponents.scheme = scheme
        urlComponents.host = host
        urlComponents.path = path
        urlComponents.queryItems = [queryItem1, queryItem2]

        if let url = urlComponents.url {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            print(url)
        }
    }
    
    private static func openGoogleMaps(latitude: Double, longitude: Double) {
        let directionsURL = "https://maps.google.com/?q=\(latitude),\(longitude)"
        guard let url = URL(string: directionsURL) else {
            return
        }
        
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
}
