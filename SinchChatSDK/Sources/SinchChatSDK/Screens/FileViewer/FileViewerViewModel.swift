import Foundation
import UIKit

protocol FileViewerViewModel {
    
    var delegate: FileViewerModelDelegate? { get }
    var url: URL { get }
}
protocol FileViewerModelDelegate: AnyObject {
}

final class DefaultFileViewerViewModel: FileViewerViewModel {

    weak var delegate: FileViewerModelDelegate?
    var url: URL

    init(url: URL) {
        self.url = url
    }
}
