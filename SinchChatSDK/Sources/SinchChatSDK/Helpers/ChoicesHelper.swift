import UIKit
import Foundation

class ChoicesHelper {
    
    static func callNumber(phoneNumber:String) {
        let trimmedPhoneNumber = phoneNumber.replacingOccurrences(of: " ", with: "")
        if let phoneCallURL = URL(string: "tel://\(trimmedPhoneNumber)") {
            
            let application = UIApplication.shared
            if application.canOpenURL(phoneCallURL) {
                application.open(phoneCallURL, options: [:], completionHandler: nil)
            }
        }
    }
    
}
