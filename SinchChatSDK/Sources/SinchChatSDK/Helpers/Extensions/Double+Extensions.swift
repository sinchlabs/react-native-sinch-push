import Foundation
extension Double {

    func getTimeFromSeconds() -> String {
        let formatter = DateComponentsFormatter()
        if self < 3600 {
            formatter.allowedUnits = [.second, .minute ]
        } else {
            formatter.allowedUnits = [.second, .minute, .hour]
        }
        
        formatter.zeroFormattingBehavior = .pad
        
        if let output = formatter.string(from: TimeInterval(self)) {
            return output
        } else {
            return ""
        }
    }
}
