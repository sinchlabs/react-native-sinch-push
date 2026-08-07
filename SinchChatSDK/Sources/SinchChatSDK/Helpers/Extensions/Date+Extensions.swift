import Foundation

extension Date {
    
    func getFormattedTime() -> String {
        
        let dateFormat = DateFormatter()
        dateFormat.timeStyle = .short
        dateFormat.dateStyle = .none
        return dateFormat.string(from: self)
    }
    
    func getFormattedDate(localizationConfiguration: SinchSDKConfig.LocalizationConfig) -> String {
        
        if Calendar.current.isDateInToday(self) {
            return  localizationConfiguration.today
        } else if Calendar.current.isDateInYesterday(self) {
            return  localizationConfiguration.yesterday
            
        } else {
            
            return  DateFormatter.localizedString(from: self, dateStyle: .medium, timeStyle: .none)
        }
    }
    func getInboxFormattedDate(localizationConfiguration: SinchSDKConfig.LocalizationConfig) -> String {
        
        if Calendar.current.isDateInToday(self) {
            let dateFormat = DateFormatter()
            dateFormat.timeStyle = .short
            
            return dateFormat.string(from: self)
        } else if Calendar.current.isDateInYesterday(self) {
            return  localizationConfiguration.yesterday
            
        } else {
            // "short"   "none"    10/10/17
            return  DateFormatter.localizedString(from: self, dateStyle: .short, timeStyle: .none)
        }
    }
    static func - (lhs: Date, rhs: Date) -> TimeInterval {
        return lhs.timeIntervalSinceReferenceDate - rhs.timeIntervalSinceReferenceDate
        
    }
}
