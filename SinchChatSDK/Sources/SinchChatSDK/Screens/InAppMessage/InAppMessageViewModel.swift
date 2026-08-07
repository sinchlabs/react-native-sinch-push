import Foundation

protocol InAppMessageViewModel {
    
    var delegate: InAppMessageViewModelDelegate? { get }
    var message: Message { get set }
}
protocol InAppMessageViewModelDelegate: AnyObject {

}

final class DefaultInAppMessageViewModel: InAppMessageViewModel {

    weak var delegate: InAppMessageViewModelDelegate?
    var message: Message
    
    init(message: Message) {
        self.message = message
    }
}
