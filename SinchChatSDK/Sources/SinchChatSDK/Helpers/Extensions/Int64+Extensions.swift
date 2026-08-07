import Foundation

extension Int64 {

    func isSameDay(_ dateInSeconds: Int64) -> Bool {
    
        return Calendar.current.isDate(Date(timeIntervalSince1970: TimeInterval(self)),
                                       inSameDayAs: Date(timeIntervalSince1970: TimeInterval(dateInSeconds)))
    
    }
}
