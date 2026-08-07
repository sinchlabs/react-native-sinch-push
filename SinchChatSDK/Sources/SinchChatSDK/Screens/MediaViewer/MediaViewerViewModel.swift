import Foundation
import UIKit
protocol MediaViewerViewModel {

    var delegate: MediaViewerModelDelegate? { get }
    var url: URL { get }
}
protocol MediaViewerModelDelegate: AnyObject {
}

final class DefaultMediaViewerViewModel: MediaViewerViewModel {

    weak var delegate: MediaViewerModelDelegate?
    var url: URL
    
    init(url: URL) {
        self.url = url
    }
   
}
