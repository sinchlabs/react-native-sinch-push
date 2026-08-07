import UIKit

public protocol MessageBody: Codable, Sendable {
    var sendDate: Int64? { get }
    var isExpanded: Bool { get set }
    
    func getReadMore(maxCount: Int, textToAdd: String ) -> String 

}
public extension MessageBody {
    
    func getReadMore(maxCount: Int, textToAdd: String ) -> String {
        return ""
    }
}

public protocol MessageWithURL: Codable {
    var url: String { get }
}

public protocol MessageWithText: Codable {
   func getText() -> String
}
