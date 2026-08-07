protocol LocationViewModel {
    
    var delegate: LocationModelDelegate? { get }
}
protocol LocationModelDelegate: AnyObject {
}

final class DefaultLocationViewModel: LocationViewModel {

    weak var delegate: LocationModelDelegate?

    init() {
    }
}
